# AWS environments

OpenTofu/Terraform for a django-mojo project's AWS footprint. One state file per
environment; a new environment should be a new `.tfvars` and nothing else.

Written against OpenTofu 1.12 and the AWS provider 5.x. HCL is identical for
HashiCorp Terraform ≥1.5 — substitute `terraform` for `tofu` throughout.

## The topology

```
tenant DNS  ──A──▶  NLB Elastic IPs (static, one per AZ)
                     │
                     ├── :443 TCP ──▶ <project>-<env>-api-servers   every node
                     └── :80  TCP ──▶ <project>-<env>-certbot-targets  ONE node
                                                    │
  node (identical, N of them, public subnet)  ◀─────┘
    nginx :80/:443 ── vhost by Host header ──▶ unix:/opt/api/var/asgi.sock
                     each node terminates TLS with its own copy of the lineage

  private subnets: Aurora PostgreSQL (encrypted, writer + reader)
                   ElastiCache Valkey (encrypted, automatic failover)
```

Three decisions are load-bearing and worth understanding before changing
anything.

**NLB, not ALB.** An ALB has no static IP — only a DNS name. Tenants bringing
their own domain would have to CNAME to it, which an apex domain cannot do
unless their DNS provider supports ALIAS records, and most do not. An NLB
carries Elastic IPs, so tenant onboarding stays "add an A record". The cost is
no host/path routing and no WAF; neither is needed here, because the nodes are
identical and nginx already routes by `Host`.

**TCP passthrough, not TLS termination at the balancer.** Each node terminates
TLS itself with a Let's Encrypt lineage. That avoids ACM's 25-certificates-per
-balancer quota, which is a real ceiling for a platform where every tenant
brings a domain, and it avoids requiring each tenant to add a validation CNAME
that must survive forever or renewals silently stop. Passthrough also preserves
the client source IP to the instance and carries WebSocket and MCP streaming
traffic with no L7 proxy in the path to buffer or time it out.

**Port 80 points at exactly one node.** Let's Encrypt fetches the HTTP-01
challenge over port 80. Behind a balancer that fetch lands on whichever node is
picked, but certbot wrote the challenge file on only one — so with N nodes in
the port-80 pool, most validations fail, intermittently and per domain. Pointing
:80 at one node makes it the sole ACME endpoint for anything still using
HTTP-01.

> **This split is now a fallback, not the plan.** Fleet certificates are issued
> centrally by dnsman over ACME **DNS-01** — no inbound connectivity, so no
> gatekeeper — and installed on every node by `mojo.apps.edge`. The :80 target
> group stays because plain `certbot --nginx` on a single box still validates
> over HTTP-01, and because an environment mid-migration needs somewhere for
> challenges to land. Nothing reads `PRIMARY_BALANCER_HOST` any more; the S3
> certificate bucket and `certbot_sync.py` are gone. See
> `docs/django_developer/deployment/provisioning.md`.

## Standing up an environment

```bash
# once per AWS account — creates the state bucket and lock table
./bootstrap.sh --region us-east-1

# once per environment
tofu init \
  -backend-config=bucket=mojo-tfstate-<account-id> \
  -backend-config=key=<project>/<env>.tfstate \
  -backend-config=region=us-east-1 \
  -backend-config=dynamodb_table=mojo-tfstate-lock

cp envs/example.prod.tfvars envs/<project>.prod.tfvars
$EDITOR envs/<project>.prod.tfvars
```

> The backend `region` is where the **state bucket** lives; it is not where
> resources go. One state bucket in us-east-1 holds state for every environment
> regardless of which region each one builds into. `var.region` in the tfvars is
> what places the infrastructure.

```bash

tofu plan  -var-file=envs/<project>.prod.tfvars
tofu apply -var-file=envs/<project>.prod.tfvars
```

Then wire the application:

```bash
tofu output -raw django_conf_fragment   # paste into var/django.conf
tofu output -raw db_password            # the generated Aurora password
tofu output point_dns_at                # A records for every hostname
tofu output primary_balancer_host       # which node receives HTTP-01 challenges
```

Finally, verify against the reference topology:

```bash
python3 -m mojo.deploy.check_setup --profile <env> --config ./var/django.conf
```

The audit ships inside django-mojo and is deliberately independent of
Terraform. Terraform checks reality against *its own intent*; the audit checks
reality against the topology this README describes. They catch different things — a resource nobody
put in Terraform is invisible to `tofu plan` and obvious to the audit.

## Environments

Two examples ship here.

`example.staging.tfvars` — single node, no balancer, no reader, no failover,
7-day backups, CloudTrail and GuardDuty off. Staging exists to test the
software, so it does not pay for infrastructure it is not testing.

`example.prod.tfvars` — NLB across two AZs, two nodes, Aurora writer + reader,
cache with a replica, 35-day backups, CloudTrail and GuardDuty on.

### Accounts and regions

Current convention: **one account, two regions** — production in us-east-1,
staging in us-west-2. Every resource is named `<project>-<env>-*` and lives in
its own state file, so the two coexist without collision and staging can be
lifted into its own account later by re-applying against different credentials.

Per-environment cost visibility does not require separate accounts. The provider
sets `Project` and `Env` as default tags on everything, so activating **Env** as
a cost allocation tag in Billing gives a per-environment breakdown in Cost
Explorer. Do that once, in the account, before the bill gets interesting.

What you give up by sharing an account is the hard boundary: a staging
credential *can* reach production resources, and nothing but IAM policy stops
it. That is a real cost, not a theoretical one, and it is the reason to revisit
this once the account has more than one pair of hands in it.

> **One thing genuinely collides in a shared account: CloudTrail.** A
> multi-region trail is account-wide, not region-scoped, so two environments
> both setting `enable_cloudtrail = true` produce two trails recording the same
> events into two buckets and bill you twice. **Let production own it and leave
> `enable_cloudtrail = false` in staging** — staging's activity is captured by
> production's trail anyway, because the trail is account-wide.
>
> GuardDuty is per-region, so it does not collide across regions. It would if
> both environments were in the same region.

For reference, us-east-1 and us-west-2 are priced essentially identically for
EC2, RDS and ElastiCache, so the region choice here is about isolation rather
than cost.

Because staging has no balancer, the multi-node certificate path is never
exercised there. It is worth adding a second staging node for an afternoon once,
confirming that a fresh node installs an edge generation and serves TLS from it,
then destroying it. That is the one component that is both new and load-bearing,
and it otherwise gets its first real run in production.

## Changing capacity

`size` moves several dimensions together. **Not all of them are seamless, and the
difference is entirely about counts versus instance types.**

| change | what AWS does | interruption |
|---|---|---|
| `node_count` up | creates instances, attaches to the target group | **none** — additive |
| `db_reader_count` up | builds a reader from the shared cluster volume | **none** — additive |
| `cache_replicas` up | adds a replica to the group | **none** — additive |
| `cache_type` | in-place `ModifyReplicationGroup`, resize by failover | **seconds** of connection resets |
| `node_type` | `instance_type` needs the instance **stopped** | **that node is down** |
| `db_class` | modifies cluster members; the writer restarts | **writer unavailable** |
| `node_count` down | destroys the highest-indexed instances | drains, then gone |
| `az_count`, `vpc_cidr` | replaces the VPC | **rebuild** |

So:

**`small` → `medium` is a live change.** It moves counts only — 2 nodes to 4,
1 reader to 2 — plus the cache node type. Everything except the cache is purely
additive; the cache resize is a few seconds of failover that any client with
reconnect logic absorbs. Do the cache in the maintenance window (it waits there
by default, since `apply_immediately = false`) and the API tier during the day.

**`medium` → `large` is not.** It changes `node_type` and `db_class`, and a
blind `tofu apply` would stop every node at once and restart the writer. Roll it:

```bash
# nodes, one at a time — each is out of the target group while it restarts
tofu apply -var-file=envs/<env>.tfvars -target='module.nodes.aws_instance.node[1]'
tofu apply -var-file=envs/<env>.tfvars -target='module.nodes.aws_instance.node[2]'
# ... leaving the gatekeeper (index 0) for last
```

For Aurora, change the readers first, then fail over onto a resized reader, then
change the old writer. Terraform will not sequence that for you — do the
failover with `aws rds failover-db-cluster` between applies, or accept one
restart in a window.

**Adding nodes has a provisioning step Terraform does not cover.** A new
instance comes up from the AMI with no certificates. The edge convergence sweep
installs a generation within about ten minutes (sooner if something broadcasts
`install_generation`), but the node fails its HTTPS health check until it does
and will not take traffic. That is correct behaviour — just don't mistake it for
a broken deploy in the first minutes.

**Scale down carefully.** `node_count` down destroys the highest-indexed
instances. The `gatekeeper_survives_scale_down` check keeps the :80 target at
index 0 so a scale-down never destroys it. That matters much less than it used
to — DNS-01 issuance does not touch the node at all — but a box still doing its
own `certbot --nginx` would stop renewing while traffic kept flowing, which
looks like nothing at all for 90 days.

## What is deliberately not here

**Provisioning.** Terraform creates instances and sets their hostname; the
software on them comes from the AMI or from `aws/ec2_bootstrap.sh`. Terraform has
no good story for re-running provisioning logic, so it does not own any.

**Instance profiles.** No IAM role is attached to the nodes. The fileman S3
backend currently requires explicit credentials and cannot use an ambient
credential chain, so a role would not be usable — see the django-mojo board item
on ambient credentials + AssumeRole. Once that lands, add a role here and drop
`AWS_KEY`/`AWS_SECRET` from `django.conf`.

**Certificates.** Issuance and renewal live in dnsman, and node-side
installation in `mojo.apps.edge`. Adding a tenant domain is a certificate
request plus a vhost row, both in the admin portal — deliberately not a
`tofu apply`, so onboarding never touches infrastructure state.

**Autoscaling.** Nodes are individual instances, not an ASG. Certificates have
now left the boxes — every node installs what dnsman issued — so the original
objection is weaker than it was; what remains is that nothing yet registers or
drains an instance automatically. Revisit alongside the rollout controller.

## Gotchas found the hard way

- **Security group rule descriptions are charset-restricted.** Em dashes and
  other punctuation used freely in comments fail at apply with a regex error.
  Keep them plain ASCII.
- **`for_each` keys must be known at plan time.** Conditioning a `for_each` on
  something derived from a not-yet-created resource fails the plan; pass a plain
  input instead. `enable_lb_alarms` exists for exactly this reason.
- **`tofu validate` is not `tofu plan`.** Validate checks syntax and schema and
  passed cleanly on both of the above. Always plan before believing a change.
