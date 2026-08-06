output "alarm_topic_arn" {
  description = "Put this in AWS_CLOUDWATCH_ALARM_TOPIC_ARNS in var/django.conf, or the mojo ingest rejects every delivery."
  value       = aws_sns_topic.alarms.arn
}

output "log_group_names" { value = [for g in aws_cloudwatch_log_group.app : g.name] }
output "cloudtrail_bucket" { value = try(aws_s3_bucket.cloudtrail[0].id, null) }
