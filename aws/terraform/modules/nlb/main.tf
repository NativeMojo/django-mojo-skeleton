# Network load balancer in TCP passthrough, with the ACME listener pointed at a
# single node.
#
#   :443 TCP -> <project>-api-servers   every node   <- player traffic
#   :80  TCP -> certbot-targets         ONE node     <- HTTP-01 challenges
#
# THE POINT OF THE SPLIT. Let's Encrypt's HTTP-01 challenge is fetched over port
# 80. Behind a load balancer that fetch lands on whichever node the balancer
# picks, but certbot wrote the challenge file on only one of them — so with N
# nodes in the :80 pool, roughly (N-1)/N of validations fail, non-deterministically
# and per domain. Pointing :80 at exactly one node makes that node the sole ACME
# endpoint; certbot_sync.py then distributes the issued lineage to the rest.
#
# This is deliberately an explicit single-member target group rather than relying
# on the other nodes failing a port-80 health check. Two reasons: the intent is
# visible to whoever reads it next, and every target stays healthy in steady
# state so an unhealthy target becomes a real signal you can alarm on. It also
# sidesteps NLB's fail-open behaviour — when every target in a group is
# unhealthy the NLB routes to all of them anyway, which in the health-check
# version would silently fan challenges out to nodes that cannot answer them.
#
# TLS is NOT terminated here. Each node terminates with its own copy of the
# lineage, which is why certbot_sync.py must move the private key and not just
# the certificate. Passthrough also means the client source IP survives to the
# instance (so nginx logs and the incident ipset see real addresses), and that
# WebSocket and MCP streaming traffic is carried without an L7 proxy in the path
# to buffer or time it out.

locals {
  name = "${var.project}-${var.env}"
}

resource "aws_eip" "nlb" {
  count = length(var.public_subnet_ids)

  domain = "vpc"
  tags   = { Name = "${local.name}-nlb-${count.index}" }
}

resource "aws_lb" "this" {
  name               = "${local.name}-nlb"
  load_balancer_type = "network"
  internal           = false

  # Static addresses are the reason this is an NLB rather than an ALB. Tenants
  # bringing their own domain add an A record to these; an ALB offers only a
  # DNS name, which an apex domain cannot CNAME to unless the tenant's provider
  # supports ALIAS records. Most do not.
  dynamic "subnet_mapping" {
    for_each = var.public_subnet_ids

    content {
      subnet_id     = subnet_mapping.value
      allocation_id = aws_eip.nlb[subnet_mapping.key].id
    }
  }

  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = var.deletion_protection

  tags = { Name = "${local.name}-nlb" }
}

# ── :443, every node ─────────────────────────────────────────────────────────

resource "aws_lb_target_group" "api" {
  name        = "${local.name}-api-servers"
  port        = 443
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  # HTTPS rather than TCP: a TCP check only proves nginx accepted a connection,
  # which stays true when uvicorn behind it is dead. /api/version exercises the
  # whole path.
  health_check {
    protocol            = "HTTPS"
    path                = "/api/version"
    port                = "443"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = { Name = "${local.name}-api-servers" }
}

resource "aws_lb_target_group_attachment" "api" {
  count = length(var.node_instance_ids)

  target_group_arn = aws_lb_target_group.api.arn
  target_id        = var.node_instance_ids[count.index]
  port             = 443
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# ── :80, the gatekeeper only ─────────────────────────────────────────────────

resource "aws_lb_target_group" "certbot" {
  name        = "${local.name}-certbot-targets"
  port        = 80
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  # Port 80 serves the ACME webroot and a 301 to HTTPS, so a healthy response
  # here is a redirect. NLB's default matcher for HTTP checks accepts 200-399,
  # which covers it; stated explicitly so nobody "fixes" it to 200 later.
  health_check {
    protocol            = "HTTP"
    path                = "/api/version"
    port                = "80"
    matcher             = "200-399"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = { Name = "${local.name}-certbot-targets" }
}

resource "aws_lb_target_group_attachment" "certbot" {
  target_group_arn = aws_lb_target_group.certbot.arn
  target_id        = var.gatekeeper_instance_id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.certbot.arn
  }
}
