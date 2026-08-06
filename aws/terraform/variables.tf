# Everything a project needs to differ by. A new environment should be a new
# .tfvars file and nothing else — if you find yourself editing a module to stand
# one up, that difference belongs here instead.

variable "project" {
  description = "Short project slug — prefixes every resource name (e.g. \"wmx\")."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric with hyphens, 2-21 chars."
  }
}

variable "env" {
  description = "Environment name — part of every resource name (\"prod\", \"staging\")."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.env))
    error_message = "env must be lowercase alphanumeric with hyphens, 2-16 chars."
  }
}

variable "region" {
  description = "AWS region. Convention: production us-east-1, staging us-west-2."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the VPC. /16 leaves room for a /24 per subnet per AZ."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = <<-EOT
    How many AZs to spread across. 2 is the floor for anything that must survive
    an AZ event; 1 is only appropriate for a staging box you are willing to lose.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 4
    error_message = "az_count must be between 1 and 4."
  }
}

# ── nodes ────────────────────────────────────────────────────────────────────

variable "node_count" {
  description = "Number of application nodes. All identical; any can be the gatekeeper."
  type        = number
  default     = 1
}

variable "node_type" {
  description = "EC2 instance type for application nodes."
  type        = string
  default     = "t3.medium"
}

variable "node_ami" {
  description = <<-EOT
    AMI for application nodes. Empty means "latest Amazon Linux 2023", which is
    right for a first stand-up and wrong afterwards — bake an AMI from a
    configured node and pin it here so replacements are identical rather than
    merely similar.
  EOT
  type        = string
  default     = ""
}

variable "node_volume_gb" {
  description = "Root volume size in GB."
  type        = number
  default     = 30
}

variable "ssh_key_name" {
  description = "Name of the EC2 key pair. The same key goes on every node."
  type        = string
}

variable "admin_cidrs" {
  description = <<-EOT
    Source CIDRs allowed to reach SSH. ["0.0.0.0/0"] is survivable with
    key-only auth but means every scanner on the internet reaches sshd; narrow
    it in production and keep a break-glass path (EC2 Serial Console) so
    narrowing it cannot lock you out.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ── load balancer ────────────────────────────────────────────────────────────

variable "use_nlb" {
  description = <<-EOT
    Put a network load balancer in front of the nodes.

    false gives the single-node shape: one instance with an Elastic IP, DNS
    straight at it, certbot on the box. That is the right staging setup when
    staging exists to test software rather than infrastructure.

    true gives the production shape: NLB in TCP passthrough with :443 across
    every node and :80 pointed at ONE node so HTTP-01 challenges always land on
    the certbot host. See gatekeeper_index.
  EOT
  type        = bool
  default     = false
}

variable "gatekeeper_index" {
  description = <<-EOT
    Which node (0-based) receives port 80 and therefore runs certbot.

    This MUST name the same host as PRIMARY_BALANCER_HOST in var/django.conf.
    If the two drift, the node receiving ACME challenges will decide it is a
    replica and never publish the renewed lineage, and certificates stop
    renewing with nothing obviously broken until they expire.
  EOT
  type        = number
  default     = 0
}

# ── database ─────────────────────────────────────────────────────────────────

variable "db_engine_version" {
  description = "Aurora PostgreSQL engine version."
  type        = string
  default     = "17.7"
}

variable "db_class" {
  description = "Instance class for Aurora members."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_reader" {
  description = <<-EOT
    Add a reader in a second AZ. Without one there is no standby: an instance
    failure means a restore rather than a sub-minute automatic promotion.
    Production should always be true.
  EOT
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = <<-EOT
    Aurora automated backup retention. Backup storage up to the size of the
    cluster volume is free and the overage is ~$0.021/GB-month, so short
    retention buys almost nothing. 7 covers an incident you notice today; 35
    covers a bad migration found next month.
  EOT
  type        = number
  default     = 35
}

variable "db_deletion_protection" {
  description = "Refuse to delete the cluster via the API. Always true in production."
  type        = bool
  default     = true
}

# ── cache ────────────────────────────────────────────────────────────────────

variable "cache_engine_version" {
  description = "Valkey engine version."
  type        = string
  default     = "8.2"
}

variable "cache_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t4g.medium"
}

variable "cache_replicas" {
  description = <<-EOT
    Replicas beyond the primary. 1+ enables automatic failover and Multi-AZ;
    0 means losing the primary is manual intervention and is only acceptable
    where the cache holds nothing you mind rebuilding.
  EOT
  type        = number
  default     = 1
}

variable "cache_snapshot_retention_days" {
  description = "Daily snapshot retention. Cheap; 0 means nothing to restore from."
  type        = number
  default     = 5
}

# ── observability ────────────────────────────────────────────────────────────

variable "alarm_endpoint" {
  description = <<-EOT
    HTTPS URL that CloudWatch alarms are delivered to via SNS — the django-mojo
    ingest at https://<api-host>/api/aws/cloudwatch/sns/alarm. It confirms the
    SNS subscription itself on first delivery.

    Empty creates the topic with no subscriber, which is a topic that fires into
    nothing. Set it, and add the topic ARN to AWS_CLOUDWATCH_ALARM_TOPIC_ARNS.
  EOT
  type        = string
  default     = ""
}

variable "alarm_email" {
  description = "Optional email subscription on the same topic, as a backstop for when the API itself is the thing that is down."
  type        = string
  default     = ""
}

variable "enable_cloudtrail" {
  description = "Multi-region CloudTrail. Without it there is no record of who changed what."
  type        = bool
  default     = true
}

variable "enable_guardduty" {
  description = "Managed detection for credential misuse, mining, and known-bad destinations."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for CloudWatch log groups. Unset means retain (and bill) forever."
  type        = number
  default     = 90
}
