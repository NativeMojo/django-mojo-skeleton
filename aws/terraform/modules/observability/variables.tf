variable "project" { type = string }
variable "env" { type = string }

variable "node_instance_ids" { type = list(string) }
variable "node_type" { type = string }

variable "db_cluster_id" { type = string }
variable "db_class" { type = string }

variable "db_connection_threshold" {
  description = "Alarm above this many connections. Roughly 80% of the instance class's max_connections."
  type        = number
  default     = 300
}

variable "cache_id" { type = string }

variable "enable_lb_alarms" {
  description = <<-EOT
    Whether to create the target-health alarms. Must be a value known at plan
    time (it drives a for_each key set), so it is passed in rather than derived
    from the ARN suffixes below, which are only known after apply.
  EOT
  type        = bool
  default     = false
}

variable "lb_arn_suffix" {
  type    = string
  default = ""
}

variable "api_target_group_arn_suffix" {
  type    = string
  default = ""
}

variable "certbot_target_group_arn_suffix" {
  type    = string
  default = ""
}

variable "enable_alarms" {
  description = "Create the SNS topic and the CloudWatch alarms. Off means the admin portal owns them — see the root's enable_alarms. No default: the root always passes it."
  type        = bool
}

variable "alarm_endpoint" { type = string }
variable "alarm_email" { type = string }
variable "enable_cloudtrail" { type = bool }
variable "enable_guardduty" { type = bool }
variable "log_retention_days" { type = number }

variable "cloudtrail_retention_days" {
  type    = number
  default = 365
}
