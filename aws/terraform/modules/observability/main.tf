# WHO OWNS THE ALARMS: on a managed installation (INFRASTRUCTURE_MODE unset,
# which is the default) the admin portal does. Setup -> AWS -> SNS and
# CloudWatch creates its own topic and its own alarms against these same
# instances, this same Aurora cluster and this same cache. Everything below is
# behind var.enable_alarms for that reason, and both shipped tfvars set it
# false. Turn it on only for an INFRASTRUCTURE_MODE = "external" installation,
# where the portal refuses to create anything. See aws/terraform/README.md,
# "Who owns this environment".
#
# CloudTrail, GuardDuty and the log groups at the bottom of this file are NOT
# behind that flag — the portal creates none of them, it only audits them, so
# they stay this module's regardless of who owns the alarms.
#
# ─────────────────────────────────────────────────────────────────────────────
#
# The alarm path: CloudWatch -> SNS -> django-mojo.
#
# The SNS topic delivers to /api/aws/cloudwatch/sns/alarm, where mojo's aws app
# verifies the signature, checks the topic against AWS_CLOUDWATCH_ALARM_TOPIC_ARNS,
# and normalises the alarm into an incident event that auto-resolves when the
# alarm returns to OK. The endpoint confirms its own SNS subscription on first
# delivery, so no manual confirmation step is needed — but it must be reachable
# and the aws app must be in INSTALLED_APPS, or the subscription sits pending
# and every alarm fires into nothing.
#
# An optional email subscription is worth setting even when the API ingest works,
# because the case you most need an alarm for is the one where the API is what
# is down.

locals {
  name = "${var.project}-${var.env}"

  # Only meaningful on burstable instance families, where exhausting credits
  # produces a slow brownout rather than a clean failure.
  node_is_burstable = can(regex("^t[234][a-z]?\\.", var.node_type))
  db_is_burstable   = can(regex("^db\\.t[234][a-z]?\\.", var.db_class))
}

resource "aws_sns_topic" "alarms" {
  count = var.enable_alarms ? 1 : 0

  name = "${local.name}-alarms"
  tags = { Name = "${local.name}-alarms" }
}

resource "aws_sns_topic_subscription" "mojo" {
  count = var.enable_alarms && var.alarm_endpoint != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "https"
  endpoint  = var.alarm_endpoint

  # Raw delivery OFF: the mojo handler expects the full SNS envelope so it can
  # verify the signature and the topic ARN.
  raw_message_delivery = false
}

resource "aws_sns_topic_subscription" "email" {
  count = var.enable_alarms && var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ── node alarms ──────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "node_status" {
  count = var.enable_alarms ? length(var.node_instance_ids) : 0

  alarm_name          = "${local.name}-node-${count.index + 1}-status-check"
  alarm_description   = "EC2 or system status check failing — the instance is unreachable or impaired."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"

  dimensions    = { InstanceId = var.node_instance_ids[count.index] }
  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "node_cpu" {
  count = var.enable_alarms ? length(var.node_instance_ids) : 0

  alarm_name          = "${local.name}-node-${count.index + 1}-cpu"
  alarm_description   = "Sustained high CPU."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions    = { InstanceId = var.node_instance_ids[count.index] }
  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "node_credits" {
  count = var.enable_alarms && local.node_is_burstable ? length(var.node_instance_ids) : 0

  alarm_name          = "${local.name}-node-${count.index + 1}-cpu-credits"
  alarm_description   = "CPU credit balance draining. Below zero the instance is throttled, which presents as unexplained slowness rather than an error."
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 30
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"

  dimensions    = { InstanceId = var.node_instance_ids[count.index] }
  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

# ── load balancer ────────────────────────────────────────────────────────────

# This one is doing more work than it looks. An unhealthy host in certbot-targets
# means the ACME endpoint is down, which does not break traffic today but stops
# certificate renewal — a failure that otherwise surfaces 90 days later as an
# expired certificate.
#
# for_each is keyed off enable_lb_alarms rather than off lb_arn_suffix being
# empty: the ARN suffixes are only known after apply, and for_each needs its key
# set resolvable at plan time. enable_lb_alarms comes straight from use_nlb,
# which is a plain input, so the key set is always known and the unknown values
# stay where they are allowed to be — in the map's values.
resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  for_each = var.enable_alarms && var.enable_lb_alarms ? {
    api     = var.api_target_group_arn_suffix
    certbot = var.certbot_target_group_arn_suffix
  } : {}

  alarm_name          = "${local.name}-${each.key}-unhealthy-hosts"
  alarm_description   = "A target in the ${each.key} group is failing health checks."
  namespace           = "AWS/NetworkELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.lb_arn_suffix
    TargetGroup  = each.value
  }

  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

# ── database ─────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.name}-db-cpu"
  alarm_description   = "Aurora CPU sustained high."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions    = { DBClusterIdentifier = var.db_cluster_id }
  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "db_memory" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.name}-db-freeable-memory"
  alarm_description   = "Aurora freeable memory low — the next step is swapping and then connection failures."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 268435456 # 256 MiB
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"

  dimensions    = { DBClusterIdentifier = var.db_cluster_id }
  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "db_connections" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.name}-db-connections"
  alarm_description   = "Connection count climbing toward the instance limit."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.db_connection_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions    = { DBClusterIdentifier = var.db_cluster_id }
  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "db_credits" {
  count = var.enable_alarms && local.db_is_burstable ? 1 : 0

  alarm_name          = "${local.name}-db-cpu-credits"
  alarm_description   = "Aurora CPU credit balance draining — the database will throttle rather than fail."
  namespace           = "AWS/RDS"
  metric_name         = "CPUCreditBalance"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 30
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"

  dimensions    = { DBClusterIdentifier = var.db_cluster_id }
  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

# ── cache ────────────────────────────────────────────────────────────────────

# Evictions above zero at all means undersized — the cache is discarding live
# entries to make room. Not a "high water mark" alarm; any sustained eviction is
# the signal.
resource "aws_cloudwatch_metric_alarm" "cache_evictions" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.name}-cache-evictions"
  alarm_description   = "The cache is evicting entries — it is too small for the working set."
  namespace           = "AWS/ElastiCache"
  metric_name         = "Evictions"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions    = { ReplicationGroupId = var.cache_id }
  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "cache_cpu" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.name}-cache-cpu"
  alarm_description   = "Cache CPU sustained high."
  namespace           = "AWS/ElastiCache"
  metric_name         = "EngineCPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions    = { ReplicationGroupId = var.cache_id }
  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

# ── audit trail and detection ────────────────────────────────────────────────

resource "aws_guardduty_detector" "this" {
  count = var.enable_guardduty ? 1 : 0

  enable = true
  tags   = { Name = local.name }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket        = "${local.name}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = { Name = "${local.name}-cloudtrail" }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail[0].id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = var.cloudtrail_retention_days
    }
  }
}

data "aws_iam_policy_document" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  statement {
    sid     = "AWSCloudTrailAclCheck"
    actions = ["s3:GetBucketAcl"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    resources = [aws_s3_bucket.cloudtrail[0].arn]
  }

  statement {
    sid     = "AWSCloudTrailWrite"
    actions = ["s3:PutObject"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    resources = ["${aws_s3_bucket.cloudtrail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail[0].id
  policy = data.aws_iam_policy_document.cloudtrail[0].json
}

resource "aws_cloudtrail" "this" {
  count = var.enable_cloudtrail ? 1 : 0

  name                          = local.name
  s3_bucket_name                = aws_s3_bucket.cloudtrail[0].id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.cloudtrail]

  tags = { Name = local.name }
}

# ── application logs ─────────────────────────────────────────────────────────
#
# Created here so retention is set from the start. The CloudWatch agent on each
# node writes into them — see aws/install_cloudwatch.sh. Log groups created
# implicitly by the agent retain forever and bill forever.

resource "aws_cloudwatch_log_group" "app" {
  for_each = toset(["nginx-access", "nginx-error", "app"])

  name              = "/${var.project}/${var.env}/${each.key}"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name}-${each.key}" }
}

# ── state moves ──────────────────────────────────────────────────────────────
#
# These six resources gained a `count` when var.enable_alarms was introduced,
# which renames their state addresses from <addr> to <addr>[0]. Without these
# blocks an environment that already applied would see each one destroyed and
# recreated — a new topic ARN, and every alarm rebuilt — purely because the
# address changed. The other alarms already had a count or a for_each.

moved {
  from = aws_sns_topic.alarms
  to   = aws_sns_topic.alarms[0]
}

moved {
  from = aws_cloudwatch_metric_alarm.db_cpu
  to   = aws_cloudwatch_metric_alarm.db_cpu[0]
}

moved {
  from = aws_cloudwatch_metric_alarm.db_memory
  to   = aws_cloudwatch_metric_alarm.db_memory[0]
}

moved {
  from = aws_cloudwatch_metric_alarm.db_connections
  to   = aws_cloudwatch_metric_alarm.db_connections[0]
}

moved {
  from = aws_cloudwatch_metric_alarm.cache_evictions
  to   = aws_cloudwatch_metric_alarm.cache_evictions[0]
}

moved {
  from = aws_cloudwatch_metric_alarm.cache_cpu
  to   = aws_cloudwatch_metric_alarm.cache_cpu[0]
}
