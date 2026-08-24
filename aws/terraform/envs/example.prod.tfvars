# Production — the topology described in aws/terraform/README.md.
#
# THIS FILE DESCRIBES AN INFRASTRUCTURE_MODE = "external" ENVIRONMENT, i.e. one
# where OpenTofu owns the estate and the admin portal refuses every mutating
# AWS endpoint. On a default (managed) installation the portal is the owner and
# this file is not applied at all. See README, "Who owns this environment".
#
# NLB in TCP passthrough, :443 across every node, :80 pointed at node 1 so ACME
# challenges always land on the certbot host. Aurora and Valkey are encrypted
# single-node data services by default; paid readers/replicas are explicit
# availability choices, not implied by "production".
#
# PRIMARY_BALANCER_HOST in var/django.conf must equal `tofu output
# primary_balancer_host`, which gatekeeper_index below selects.

project = "example"
env     = "prod"
region  = "us-east-1"

# 2 application nodes, 1 Aurora writer, 1 cache node. Move to "medium" for four
# application nodes and a larger cache node. Readers and cache replicas remain
# opt-in regardless of the size preset.
size = "small"

db_reader_count = 0
cache_replicas  = 0

az_count = 2

node_ami         = "" # pin a baked AMI before this is real
node_volume_gb   = 30
ssh_key_name     = "example-prod"
gatekeeper_index = 0 # node 1 -> "example1" -> certbot-targets

# Narrow this. Key-only auth makes an open port 22 survivable rather than
# correct, and EC2 Serial Console is the break-glass if you lock yourself out.
admin_cidrs = ["0.0.0.0/0"]

use_nlb = true

db_backup_retention_days = 35
db_deletion_protection   = true

cache_snapshot_retention_days = 5

# The django-mojo ingest. Needs mojo.apps.aws routed and the topic ARN in
# AWS_CLOUDWATCH_ALARM_TOPIC_ARNS, or every delivery is rejected.
# Off because the admin portal creates its own topic and its own alarms against
# these same resources — two alarm planes, two pages per event. Flip to true
# only if this environment has no portal doing that. Turning it back OFF later
# DESTROYS the topic, and re-enabling mints a new ARN.
enable_alarms = false

# Both require enable_alarms; kept here so the wiring is obvious if it is ever
# turned on.
alarm_endpoint = "https://api.example.com/api/aws/cloudwatch/sns/alarm"
alarm_email    = "ops@example.com" # backstop for when the API is what is down

enable_cloudtrail  = true
enable_guardduty   = true
log_retention_days = 90
