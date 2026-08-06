# Application nodes. Identical by construction — same AMI, same key, same
# security group. The only thing that distinguishes one from another is its
# hostname, which user-data assigns, and which the gatekeeper role is keyed to.
#
# Instances are created individually rather than through an autoscaling group.
# That is deliberate at this size: the fleet is a handful of long-lived nodes
# that hold a Let's Encrypt lineage and a certbot role, so "replace on a whim"
# is not actually the behaviour you want. Move to an ASG when nodes become
# genuinely disposable — that is, once certificates leave the boxes.

data "aws_ami" "al2023" {
  count = var.node_ami == "" ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
}

locals {
  name = "${var.project}-${var.env}"
  ami  = var.node_ami != "" ? var.node_ami : data.aws_ami.al2023[0].id

  # wmx1, wmx2, … — matches the existing convention, and PRIMARY_BALANCER_HOST
  # in django.conf is compared against exactly this.
  hostnames = [for i in range(var.node_count) : "${var.project}${i + 1}"]
}

resource "aws_instance" "node" {
  count = var.node_count

  ami                    = local.ami
  instance_type          = var.node_type
  key_name               = var.ssh_key_name
  subnet_id              = var.public_subnet_ids[count.index % length(var.public_subnet_ids)]
  vpc_security_group_ids = [var.node_sg_id]

  # IMDSv2 required. With no instance profile attached there are no credentials
  # in the metadata service to steal, but this also costs nothing and means
  # attaching a profile later does not quietly open an SSRF-to-credentials path.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = var.node_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Hostname only. Everything else about the box comes from the AMI or from
  # aws/ec2_bootstrap.sh — provisioning logic does not belong in Terraform,
  # which has no good way to re-run it.
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    hostnamectl set-hostname ${local.hostnames[count.index]}
    echo "${local.hostnames[count.index]}" > /etc/hostname
    sed -i "s/^127.0.0.1.*/127.0.0.1   localhost ${local.hostnames[count.index]}/" /etc/hosts
    if [ -f /etc/cloud/cloud.cfg ]; then
      sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg
    fi
  EOT

  # The AMI is pinned deliberately (see variables.tf); changing it should be a
  # considered replacement, not a side effect of `tofu apply` after Amazon
  # publishes a new image.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name       = local.hostnames[count.index]
    Hostname   = local.hostnames[count.index]
    Gatekeeper = count.index == var.gatekeeper_index ? "true" : "false"
  }
}

# An Elastic IP per node. In the NLB topology these are not strictly required —
# the NLB carries the public addresses — but a stable per-node address is worth
# having for SSH, and it means a node keeps its identity across a stop/start.
resource "aws_eip" "node" {
  count = var.node_count

  instance = aws_instance.node[count.index].id
  domain   = "vpc"

  tags = { Name = local.hostnames[count.index] }
}
