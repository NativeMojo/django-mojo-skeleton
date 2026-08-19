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

# ── capacity ─────────────────────────────────────────────────────────────────

variable "size" {
  description = <<-EOT
    Capacity preset. Sets node count, instance types, reader count and cache
    size together, so an environment is described by one word rather than six
    numbers that can drift out of proportion to each other.

      micro   1 node,  0 readers, 1 cache node   — staging; not survivable
      small   2 nodes, 1 reader,  2 cache nodes  — production floor
      medium  4 nodes, 2 readers, 2 cache nodes  — same instance types as small
      large   6 nodes, 2 readers, 3 cache nodes  — larger types; needs a window

    small -> medium changes counts only, which is what makes it a live step.
    -> large changes instance types and does not apply cleanly in one go; see
    README, "Changing capacity".

    Any individual field below overrides its preset value, so "small but with
    bigger nodes" does not require a new preset. See local.capacity in main.tf.
  EOT
  type        = string
  default     = "small"

  validation {
    condition     = contains(["micro", "small", "medium", "large"], var.size)
    error_message = "size must be one of: micro, small, medium, large."
  }
}

# ── nodes ────────────────────────────────────────────────────────────────────
#
# These default to null, meaning "take it from the size preset". Set one to
# override just that field.

variable "node_count" {
  description = "Number of application nodes. All identical; any can be the gatekeeper."
  type        = number
  default     = null
}

variable "node_type" {
  description = "EC2 instance type for application nodes."
  type        = string
  default     = null
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
  description = "Instance class for Aurora members. Null takes the size preset."
  type        = string
  default     = null
}

variable "db_reader_count" {
  description = <<-EOT
    Readers in addition to the writer. Null takes the size preset.

    Zero means there is no standby: an instance failure becomes a restore rather
    than a sub-minute automatic promotion. Only acceptable in staging.

    Adding a reader later is additive and causes no interruption — Aurora builds
    it from the shared cluster volume and it joins when ready.
  EOT
  type        = number
  default     = null
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
  description = <<-EOT
    ElastiCache node type. Null takes the size preset.

    Resizing later is an in-place ModifyReplicationGroup, not a rebuild, but it
    is the ONE capacity change that interrupts: ElastiCache scales by failing
    over to a resized node, so expect a few seconds of connection resets. It
    waits for the maintenance window unless applied immediately.
  EOT
  type        = string
  default     = null
}

variable "cache_replicas" {
  description = <<-EOT
    Replicas beyond the primary. Null takes the size preset.

    1+ enables automatic failover and Multi-AZ; 0 means losing the primary is
    manual intervention, acceptable only where the cache holds nothing you mind
    rebuilding.
  EOT
  type        = number
  default     = null
}

variable "cache_snapshot_retention_days" {
  description = "Daily snapshot retention. Cheap; 0 means nothing to restore from."
  type        = number
  default     = 5
}

# ── observability ────────────────────────────────────────────────────────────

variable "enable_alarms" {
  description = <<-EOT
    Create this root's SNS topic and its ten CloudWatch alarms.

    ON A MANAGED INSTALLATION THE ADMIN PORTAL OWNS ALARMS. Setup -> AWS -> SNS
    and CloudWatch creates the topic django-mojo-<slug>-operations and alarms
    named django-mojo/<slug>/... against the same instances, the same Aurora
    cluster and the same cache this root describes. The two naming schemes never
    collide, so a duplicated alarm plane is easy to run for months without
    noticing: two topics, two sets of alarms, two notifications per event.

    Both shipped tfvars set this false, because the portal is the default owner.
    Set it true only for an INFRASTRUCTURE_MODE = "external" installation where
    the portal is refusing to create anything.

    Turning it OFF on an environment that applied with it ON DESTROYS those
    alarms and that topic. Re-enabling creates a NEW topic with a NEW ARN, so
    AWS_CLOUDWATCH_ALARM_TOPIC_ARNS has to be re-pasted into var/django.conf and
    any alarm_email subscription has to be re-confirmed by a human clicking the
    link in the confirmation mail. Neither happens by itself, and an unconfirmed
    subscription looks exactly like a quiet night.

    CloudTrail, GuardDuty and log-group retention are NOT covered by this flag —
    nothing in the portal creates those, so they stay this root's to own.
  EOT
  type        = bool
  default     = true
}

variable "alarm_endpoint" {
  description = <<-EOT
    HTTPS URL that CloudWatch alarms are delivered to via SNS — the django-mojo
    ingest at https://<api-host>/api/aws/cloudwatch/sns/alarm. It confirms the
    SNS subscription itself on first delivery.

    Requires enable_alarms — with alarms off there is no topic to subscribe to
    and this is ignored.

    Empty creates the topic with no subscriber, which is a topic that fires into
    nothing. Set it, and add the topic ARN to AWS_CLOUDWATCH_ALARM_TOPIC_ARNS.
  EOT
  type        = string
  default     = ""
}

variable "alarm_email" {
  description = "Optional email subscription on the same topic, as a backstop for when the API itself is the thing that is down. Requires enable_alarms."
  type        = string
  default     = ""
}

variable "enable_cloudtrail" {
  description = <<-EOT
    Multi-region CloudTrail. Without it there is no record of who changed what.

    ACCOUNT-WIDE, not region-scoped. When several environments share an account,
    exactly one of them should set this — production. A second trail records the
    same events into a second bucket and bills you twice for it, and staging is
    already covered by production's trail.
  EOT
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

variable "swap_gb" {
  description = <<-EOT
    Swapfile size in GB on each node. A backstop against the OOM killer reaping
    uvicorn on a small instance, not somewhere the working set should live —
    user-data also sets vm.swappiness=10.
  EOT
  type        = number
  default     = 1
}
