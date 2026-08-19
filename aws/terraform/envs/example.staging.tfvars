# Staging — cheapest thing that runs the software honestly.
#
# THIS FILE DESCRIBES AN INFRASTRUCTURE_MODE = "external" ENVIRONMENT — OpenTofu
# owns the estate and the admin portal refuses every mutating AWS endpoint. On a
# default (managed) installation the portal is the owner and this file is not
# applied at all. See README, "Who owns this environment".
#
# No load balancer: staging exists to test the application, not the topology, so
# one node with its own Elastic IP and certbot straight on the box. That does
# mean the multi-node certbot_sync path is never exercised here — worth adding a
# second node for an afternoon once, to prove a replica pulls the lineage and
# serves TLS with it, then destroying it.
#
# Shares an account with production; separated by region and by the <project>-
# <env> naming on every resource. Per-environment cost comes from the Env
# default tag — activate it as a cost allocation tag in Billing.
#
# enable_cloudtrail stays false here: a multi-region trail is account-wide, so
# production's trail already records this environment. Two trails would just
# bill twice for the same events.

project = "example"
env     = "staging"
region  = "us-west-2"

size = "micro" # 1 node, no reader, 1 cache node

az_count = 2 # the data subnet groups need two AZs even with one node

node_ami     = "" # latest AL2023; pin once an AMI is baked
ssh_key_name = "example-staging"
admin_cidrs  = ["0.0.0.0/0"] # key-only auth; narrow it if you like

use_nlb = false

db_backup_retention_days = 7
db_deletion_protection   = false # staging gets torn down on purpose

cache_snapshot_retention_days = 1

# Off because the admin portal creates its own topic and alarms against these
# same resources. See envs/example.prod.tfvars for the consequences of flipping
# it on and back off again.
enable_alarms      = false
alarm_endpoint     = "" # set once the aws app is routed
enable_cloudtrail  = false
enable_guardduty   = false
log_retention_days = 14
