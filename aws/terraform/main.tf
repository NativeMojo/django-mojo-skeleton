# Root module. One environment per state file — see versions.tf for the backend
# key convention.

module "network" {
  source = "./modules/network"

  project     = var.project
  env         = var.env
  region      = var.region
  vpc_cidr    = var.vpc_cidr
  az_count    = var.az_count
  admin_cidrs = var.admin_cidrs
}

module "nodes" {
  source = "./modules/nodes"

  project           = var.project
  env               = var.env
  node_count        = var.node_count
  node_type         = var.node_type
  node_ami          = var.node_ami
  node_volume_gb    = var.node_volume_gb
  ssh_key_name      = var.ssh_key_name
  gatekeeper_index  = var.gatekeeper_index
  public_subnet_ids = module.network.public_subnet_ids
  node_sg_id        = module.network.node_sg_id
}

# Absent when use_nlb is false, which is the single-node shape: DNS points at
# the node's own Elastic IP and certbot runs on the box with nothing in front of
# it. That is the right staging setup when staging exists to test software.
module "nlb" {
  source = "./modules/nlb"
  count  = var.use_nlb ? 1 : 0

  project                = var.project
  env                    = var.env
  vpc_id                 = module.network.vpc_id
  public_subnet_ids      = module.network.public_subnet_ids
  node_instance_ids      = module.nodes.instance_ids
  gatekeeper_instance_id = module.nodes.gatekeeper_instance_id
  deletion_protection    = var.env == "prod"
}

module "data" {
  source = "./modules/data"

  project            = var.project
  env                = var.env
  private_subnet_ids = module.network.private_subnet_ids
  rds_sg_id          = module.network.rds_sg_id
  cache_sg_id        = module.network.cache_sg_id

  db_engine_version     = var.db_engine_version
  db_class              = var.db_class
  reader                = var.db_reader
  backup_retention_days = var.db_backup_retention_days
  deletion_protection   = var.db_deletion_protection

  cache_engine_version    = var.cache_engine_version
  cache_type              = var.cache_type
  replicas                = var.cache_replicas
  snapshot_retention_days = var.cache_snapshot_retention_days
}

module "observability" {
  source = "./modules/observability"

  project = var.project
  env     = var.env

  node_instance_ids = module.nodes.instance_ids
  node_type         = var.node_type

  db_cluster_id = module.data.db_cluster_id
  db_class      = var.db_class
  cache_id      = module.data.cache_id

  enable_lb_alarms                = var.use_nlb
  lb_arn_suffix                   = var.use_nlb ? module.nlb[0].arn_suffix : ""
  api_target_group_arn_suffix     = var.use_nlb ? module.nlb[0].api_target_group_arn_suffix : ""
  certbot_target_group_arn_suffix = var.use_nlb ? module.nlb[0].certbot_target_group_arn_suffix : ""

  alarm_endpoint     = var.alarm_endpoint
  alarm_email        = var.alarm_email
  enable_cloudtrail  = var.enable_cloudtrail
  enable_guardduty   = var.enable_guardduty
  log_retention_days = var.log_retention_days
}

# Fails the plan rather than the deployment. gatekeeper_index selecting a node
# that does not exist would otherwise surface as an index-out-of-range deep in
# the nodes module, or worse, silently point :80 at the wrong host.
check "gatekeeper_in_range" {
  assert {
    condition     = var.gatekeeper_index < var.node_count
    error_message = "gatekeeper_index (${var.gatekeeper_index}) must be less than node_count (${var.node_count})."
  }
}
