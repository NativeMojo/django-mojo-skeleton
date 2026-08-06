variable "project" { type = string }
variable "env" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "rds_sg_id" { type = string }
variable "cache_sg_id" { type = string }

variable "db_engine_version" { type = string }
variable "db_class" { type = string }
variable "reader" { type = bool }
variable "backup_retention_days" { type = number }
variable "deletion_protection" { type = bool }

variable "cache_engine_version" { type = string }
variable "cache_type" { type = string }
variable "replicas" { type = number }
variable "snapshot_retention_days" { type = number }
