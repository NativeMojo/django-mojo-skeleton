# Staging — cheapest thing that runs the software honestly.
#
# No load balancer: staging exists to test the application, not the topology, so
# one node with its own Elastic IP and certbot straight on the box. That does
# mean the multi-node certbot_sync path is never exercised here — worth adding a
# second node for an afternoon once, to prove a replica pulls the lineage and
# serves TLS with it, then destroying it.
#
# Convention: staging in us-west-2, production in us-east-1, separate accounts.

project = "example"
env     = "staging"
region  = "us-west-2"

az_count = 2 # the data subnet group needs two AZs even with one node

node_count   = 1
node_type    = "t4g.small"
node_ami     = "" # latest AL2023; pin once an AMI is baked
ssh_key_name = "example-staging"
admin_cidrs  = ["0.0.0.0/0"] # key-only auth; narrow it if you like

use_nlb = false

db_class                 = "db.t4g.medium"
db_reader                = false
db_backup_retention_days = 7
db_deletion_protection   = false # staging gets torn down on purpose

cache_type                    = "cache.t4g.micro"
cache_replicas                = 0 # no failover; nothing here is worth recovering
cache_snapshot_retention_days = 1

alarm_endpoint     = "" # set once the aws app is routed
enable_cloudtrail  = false
enable_guardduty   = false
log_retention_days = 14
