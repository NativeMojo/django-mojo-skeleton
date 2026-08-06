# Aurora PostgreSQL and an ElastiCache (Valkey) replication group, both in the
# private subnets.
#
# ENCRYPTION IS SET AT CREATION AND ONLY AT CREATION. Neither Aurora storage
# encryption nor ElastiCache at-rest encryption can be enabled in place. For
# Aurora the escape hatch exists but is a cutover — snapshot, then
# restore-db-cluster-from-snapshot with a KMS key, which does produce an
# encrypted cluster (note that copy-db-cluster-snapshot with a key does NOT:
# "Copying unencrypted cluster with encryption is not supported"). For
# ElastiCache there is no in-place path at all; you rebuild.
#
# So both are hardcoded on rather than exposed as variables. There is no
# environment where the right answer is "off", and making it a knob invites
# someone to stand up a cluster they cannot later fix without downtime.

locals {
  name = "${var.project}-${var.env}"
}

# ── aurora ───────────────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-db"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${local.name}-db" }
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_rds_cluster" "this" {
  cluster_identifier = "${local.name}-cluster"
  engine             = "aurora-postgresql"
  engine_version     = var.db_engine_version
  database_name      = replace(var.project, "-", "_")
  master_username    = "postgres"
  master_password    = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_sg_id]

  storage_encrypted = true

  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = "07:00-09:00"
  preferred_maintenance_window = "sun:09:30-sun:11:00"

  deletion_protection = var.deletion_protection

  # A final snapshot on destroy is the difference between "we tore down staging"
  # and "we tore down staging and it had the only copy of something".
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-final"

  # Slow queries and connection errors are invisible once an instance is
  # replaced unless they are shipped off the box.
  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = { Name = "${local.name}-cluster" }

  lifecycle {
    ignore_changes = [master_password]
  }
}

# One writer plus reader_count readers. Adding a reader is additive — Aurora
# builds it from the shared cluster volume and it starts taking traffic when
# ready, with no interruption to the writer.
#
# CHANGING instance_class is a different matter: Terraform would modify every
# member at once, which restarts the writer. Do that as a rolling change
# instead — see README, "Changing capacity".
resource "aws_rds_cluster_instance" "this" {
  count = 1 + var.reader_count

  identifier         = "${local.name}-cluster-instance-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.this.id
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version
  instance_class     = var.db_class

  db_subnet_group_name = aws_db_subnet_group.this.name

  performance_insights_enabled = true
  auto_minor_version_upgrade   = true

  # Members land in different AZs by default because the subnet group spans
  # them, which is what makes the reader a real standby rather than a second
  # copy sharing the first one's fate.
  tags = { Name = "${local.name}-cluster-instance-${count.index + 1}" }
}

# ── elasticache ──────────────────────────────────────────────────────────────

resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name}-cache"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${local.name}-cache" }
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${local.name}-cache"
  description          = "${local.name} cache"

  engine         = "valkey"
  engine_version = var.cache_engine_version
  node_type      = var.cache_type
  port           = 6379

  num_cache_clusters = var.replicas + 1

  # Both require replicas to mean anything, so they track the same condition.
  automatic_failover_enabled = var.replicas > 0
  multi_az_enabled           = var.replicas > 0

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [var.cache_sg_id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"

  # No AUTH token. With TLS required and a security group that admits only the
  # node tier, a token guards against exactly one thing — something already
  # inside the VPC that is not the application — and adds a secret to rotate.
  # Add one if this VPC ever hosts anything you do not control.

  snapshot_retention_limit = var.snapshot_retention_days
  snapshot_window          = "05:00-07:00"
  maintenance_window       = "sun:09:30-sun:11:00"

  apply_immediately = false

  tags = { Name = "${local.name}-cache" }
}
