#!/bin/bash
# Install and configure CloudWatch agent for Mojo Orchestra
#
# Usage: sudo bash install_cloudwatch.sh
#
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Configuring CloudWatch agent..."

# Agent should already be installed by ec2_install.sh
if ! command -v amazon-cloudwatch-agent-ctl &>/dev/null; then
    log "CloudWatch agent not installed. Installing..."
    dnf install -y amazon-cloudwatch-agent
fi

# Write config
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'EOF'
{
    "agent": {
        "metrics_collection_interval": 60,
        "run_as_user": "root"
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/secure",
                        "log_group_name": "orchestra/secure",
                        "log_stream_name": "{instance_id}"
                    },
                    {
                        "file_path": "/var/log/nginx/access.log",
                        "log_group_name": "orchestra/nginx-access",
                        "log_stream_name": "{instance_id}"
                    },
                    {
                        "file_path": "/var/log/nginx/error.log",
                        "log_group_name": "orchestra/nginx-error",
                        "log_stream_name": "{instance_id}"
                    },
                    {
                        "file_path": "/opt/api/var/logs/job_engine.log",
                        "log_group_name": "orchestra/job-engine",
                        "log_stream_name": "{instance_id}"
                    },
                    {
                        "file_path": "/opt/api/var/logs/job_scheduler.log",
                        "log_group_name": "orchestra/job-scheduler",
                        "log_stream_name": "{instance_id}"
                    }
                ]
            }
        }
    },
    "metrics": {
        "namespace": "Orchestra",
        "metrics_collected": {
            "cpu": {
                "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
                "metrics_collection_interval": 60
            },
            "mem": {
                "measurement": ["mem_used_percent"],
                "metrics_collection_interval": 60
            },
            "disk": {
                "measurement": ["used_percent"],
                "resources": ["/"],
                "metrics_collection_interval": 300
            }
        }
    }
}
EOF

# Start agent
amazon-cloudwatch-agent-ctl -a fetch-config \
    -m ec2 \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
    -s

systemctl enable amazon-cloudwatch-agent

log "CloudWatch agent configured and started."
