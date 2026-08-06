output "db_cluster_id" { value = aws_rds_cluster.this.cluster_identifier }
output "db_writer_endpoint" { value = aws_rds_cluster.this.endpoint }
output "db_reader_endpoint" { value = aws_rds_cluster.this.reader_endpoint }
output "db_name" { value = aws_rds_cluster.this.database_name }

output "db_password" {
  description = "Generated at create time. Read once with `tofu output -raw db_password`, put it in var/django.conf, and rotate it out of state when convenient."
  value       = random_password.db.result
  sensitive   = true
}

output "cache_id" { value = aws_elasticache_replication_group.this.replication_group_id }
output "cache_primary_endpoint" { value = aws_elasticache_replication_group.this.primary_endpoint_address }
output "cache_reader_endpoint" { value = aws_elasticache_replication_group.this.reader_endpoint_address }
