# Root module. One environment per state file — see versions.tf for the backend
# key convention.

# ── capacity presets ─────────────────────────────────────────────────────────
#
# `size` picks a row; any individual variable set in the tfvars overrides just
# that field. Keeping the dimensions together in one table is the point: four
# API nodes in front of a single writer with a t4g.small cache is a shape nobody
# chooses deliberately, but it is easy to arrive at one variable at a time.
#
# Every step UP this table is a no-interruption change except the cache node
# type — see README, "Changing capacity". Steps DOWN destroy things; read the
# plan.

locals {
  presets = {
    micro = {
      node_count      = 1
      node_type       = "t4g.small"
      db_class        = "db.t4g.medium"
      db_reader_count = 0
      cache_type      = "cache.t4g.micro"
      cache_replicas  = 0
    }
    small = {
      node_count      = 2
      node_type       = "t3.medium"
      db_class        = "db.t4g.medium"
      db_reader_count = 1
      cache_type      = "cache.t4g.small"
      cache_replicas  = 1
    }
    # small -> medium deliberately changes COUNTS ONLY, not instance types.
    #
    # That is what makes it a seamless step: adding nodes and adding readers are
    # both purely additive, while changing an EC2 instance_type requires a
    # stop/start and changing an Aurora instance_class restarts the writer.
    # Scaling stateless API nodes horizontally is the right axis anyway, and
    # readers are how you take read load off the writer — growing the writer is
    # a different problem with a different signal.
    #
    # The cache node type does grow here, because a cache cannot be scaled by
    # adding replicas; it is sized by working set. That single change is the one
    # interruption in this step, and it is a few seconds of failover.
    medium = {
      node_count      = 4
      node_type       = "t3.medium"
      db_class        = "db.t4g.medium"
      db_reader_count = 2
      cache_type      = "cache.t4g.medium"
      cache_replicas  = 1
    }

    # large DOES change instance types, and is therefore NOT a seamless step —
    # it needs the rolling procedure in the README. Kept as a preset because the
    # target shape is worth naming even when getting there takes a maintenance
    # window.
    large = {
      node_count      = 6
      node_type       = "m6i.large"
      db_class        = "db.r6g.xlarge"
      db_reader_count = 2
      cache_type      = "cache.r7g.large"
      cache_replicas  = 2
    }
  }

  preset = local.presets[var.size]

  # coalesce() would reject a legitimate 0 (no readers, no cache replicas), so
  # these test for null explicitly.
  capacity = {
    node_count      = var.node_count != null ? var.node_count : local.preset.node_count
    node_type       = var.node_type != null ? var.node_type : local.preset.node_type
    db_class        = var.db_class != null ? var.db_class : local.preset.db_class
    db_reader_count = var.db_reader_count != null ? var.db_reader_count : local.preset.db_reader_count
    cache_type      = var.cache_type != null ? var.cache_type : local.preset.cache_type
    cache_replicas  = var.cache_replicas != null ? var.cache_replicas : local.preset.cache_replicas
  }
}

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
  node_count        = local.capacity.node_count
  node_type         = local.capacity.node_type
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
  db_class              = local.capacity.db_class
  reader_count          = local.capacity.db_reader_count
  backup_retention_days = var.db_backup_retention_days
  deletion_protection   = var.db_deletion_protection

  cache_engine_version    = var.cache_engine_version
  cache_type              = local.capacity.cache_type
  replicas                = local.capacity.cache_replicas
  snapshot_retention_days = var.cache_snapshot_retention_days
}

module "observability" {
  source = "./modules/observability"

  project = var.project
  env     = var.env

  node_instance_ids = module.nodes.instance_ids
  node_type         = local.capacity.node_type

  db_cluster_id = module.data.db_cluster_id
  db_class      = local.capacity.db_class
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
    condition     = var.gatekeeper_index < local.capacity.node_count
    error_message = "gatekeeper_index (${var.gatekeeper_index}) must be less than node_count (${local.capacity.node_count})."
  }
}

# Scaling down node_count destroys the highest-indexed instances. If the
# gatekeeper is among them, port 80 loses its only target and certificate
# renewal stops — with traffic still served, so nothing looks wrong for 90 days.
# Keeping the gatekeeper at index 0 makes it the last node a scale-down touches.
check "gatekeeper_survives_scale_down" {
  assert {
    condition     = var.gatekeeper_index == 0
    error_message = "gatekeeper_index should be 0 so that scaling node_count down never destroys the ACME endpoint. Override deliberately if you have a reason."
  }
}
