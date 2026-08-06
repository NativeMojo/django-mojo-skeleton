# VPC with a public tier for the application nodes and a private tier for the
# data services.
#
# WHY THE NODES ARE IN PUBLIC SUBNETS. Not because they are exposed — the
# security group admits only 80/443 plus SSH — but because a public subnet gives
# them free outbound to upstream APIs, package repos and Let's Encrypt. Private
# subnets would need a NAT gateway at ~$33/month plus per-GB processing, and buy
# nothing the security group is not already providing.
#
# The DATA tier is private, because it needs no outbound at all. That is where a
# private subnet is free and worth having.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.project}-${var.env}"
  azs  = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = local.name }
}

# Public /24 per AZ starting at x.x.0.0, private /24 per AZ starting at x.x.10.0.
# The gap is deliberate: it leaves room to add public subnets later without
# renumbering the private ones.

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-public-${local.azs[count.index]}" }
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private tier has no default route on purpose — nothing in it should be
# reaching the internet. The S3 gateway endpoint below is the one exception and
# it costs nothing.

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Gateway endpoint, not interface — gateway endpoints are free and interface
# endpoints are ~$7/month per AZ. Keeps fileman traffic off the internet path.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id, aws_route_table.private.id]

  tags = { Name = "${local.name}-s3" }
}

# ── security groups ──────────────────────────────────────────────────────────
#
# One group per tier, and the data tiers reference the node group BY ID rather
# than by CIDR. A CIDR rule keeps working when the instance at that address is
# replaced by something else; a group reference does not.
#
# Note on port 443: with an NLB in TCP passthrough the client source IP is
# preserved all the way to the instance, so this rule is evaluated against the
# real client — it must be open to the world, not to the load balancer.

resource "aws_security_group" "node" {
  name        = "${local.name}-node"
  description = "Application nodes"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # AWS restricts security group rule descriptions to a limited charset that
  # excludes em dashes and other punctuation used freely elsewhere in this repo.
  # Keep these plain ASCII or apply fails with a regex complaint.
  ingress {
    description = "HTTP - ACME http-01 challenges and the redirect to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-node" }
}

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "Database access from the application nodes"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "PostgreSQL from nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.node.id]
  }

  tags = { Name = "${local.name}-rds" }
}

resource "aws_security_group" "cache" {
  name        = "${local.name}-cache"
  description = "Cache access from the application nodes"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Valkey from nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.node.id]
  }

  tags = { Name = "${local.name}-cache" }
}
