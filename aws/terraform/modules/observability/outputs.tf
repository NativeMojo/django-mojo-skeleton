output "alarm_topic_arn" {
  description = <<-EOT
    Put this in AWS_CLOUDWATCH_ALARM_TOPIC_ARNS in var/django.conf, or the mojo
    ingest rejects every delivery.

    EMPTY when enable_alarms is false, which is how both shipped tfvars come:
    this root then creates no topic, and the ARN to use is the admin portal's
    own operations topic, which the portal writes into the conf itself.
  EOT
  value       = try(aws_sns_topic.alarms[0].arn, "")
}

output "log_group_names" { value = [for g in aws_cloudwatch_log_group.app : g.name] }
output "cloudtrail_bucket" { value = try(aws_s3_bucket.cloudtrail[0].id, null) }
