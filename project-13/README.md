# project-13 — Terraform, one VPC per environment

project-11/12 built everything with aws-cli scripts and a `PURPOSE`-tagged state file, one
network per `PURPOSE`. project-13 redoes the same ground in Terraform, the way it's usually
laid out in practice: **one VPC per environment (dev, prod)**, shared by every app deployed
into that environment, each layer in its own root module with its own state.

Built step by step:

1. The state bucket and the dev/prod VPCs.
2. Modules for baking an AMI from `ami-scripts/*.sh` and launching instances from it.
3. **(this)** Images in `shared/ami-*` (egress-gateway, nodejs), NAT instances per env, and the
   Node.js app on plain EC2 instances per env.

Next: a load balancer in front of the app, then the ECS/RDS/bun-hydrate layers.

```
project-13/
  run.sh                      wrapper creds + terraform, same shape as project-11/12's run.sh
  wrapper -> ../project-9/wrapper
  ami-scripts -> ../project-11/ami-scripts
  bootstrap/                  S3 state bucket (local state - see below)
  modules/
    vpc/                      the one VPC module both envs use
    ami/                      bake an AMI from an ami-scripts/*.sh (runs Packer)
      packer/ami.pkr.hcl
    instance/                 launch N instances from an AMI
    nat/                      NAT instances + the app tier's default routes (uses instance/)
    */tests/*.tftest.hcl      offline tests (mock provider, no AWS creds)
  live/                       one folder per deployment, each its own state <env>/<layer>.tfstate
    shared/ami-egress-gateway/  NAT image, used by every env's nat layer
    shared/ami-nodejs/        Node.js app image, used by every env's app layer
    dev/network/              dev VPC   - 10.10.0.0/16
    dev/nat/                  1 NAT instance, shared by both AZs
    dev/app/                  1 Node.js instance
    prod/network/             prod VPC  - 10.20.0.0/16
    prod/nat/                 2 NAT instances, one per AZ
    prod/app/                 2 Node.js instances, one per AZ
```

Layers depend on each other only through state outputs (`terraform_remote_state`), so apply
them in order:

```
dev network ─┬─► shared/ami-egress-gateway ─► <env> nat ─┐
             └─► shared/ami-nodejs ──────────────────────┴─► <env> app
<env> network ─► <env> nat ─► <env> app
```

## Prerequisites

- Terraform >= 1.10 (S3-native state locking - no DynamoDB table).
- [Packer](https://developer.hashicorp.com/packer/install) on PATH, for the `shared ami-*` layers only
  (`modules/ami` runs it).
- `wrapper/config/.env` filled in with the creator credentials, same as project-11/12
  (`cp wrapper/config/.env.example wrapper/config/.env` if you haven't already - it's the
  same shared file, via the symlink).

## Usage

```bash
./run.sh bootstrap init
./run.sh bootstrap apply           # creates cd-stack-gen-tfstate-<account-id>, once per account

./run.sh dev network plan
./run.sh dev network apply
./run.sh dev network output        # vpc_id, subnet ids, route table ids

./run.sh prod network plan
./run.sh prod network apply

# each image is its own layer - build, rebuild or destroy one without touching the other
./run.sh shared ami-egress-gateway apply   # needs dev network - the builder runs in its public subnet
./run.sh shared ami-nodejs apply
./run.sh shared ami-nodejs output          # ami_id, ami_name

./run.sh dev nat apply             # NAT instance + app subnets' 0.0.0.0/0 routes
./run.sh dev app apply             # Node.js instance(s) - after nat, see below

./run.sh prod nat apply
./run.sh prod app apply
```

Tear down in reverse: `app`, `nat`, then `network`. `network` can't be destroyed while
instances are still in its subnets. `./run.sh shared ami-<image> destroy` deregisters that image.

`run.sh <env> <layer> <action>` runs `terraform init` with the right backend config on first
use, then the action in `live/<env>/<layer>`. Anything after the action is passed through
(`./run.sh prod network plan -out=prod.tfplan`). Override the bucket name with
`TF_STATE_BUCKET=...` and the region with `AWS_REGION=...` (default `ap-northeast-1`). Both
reach every root as `TF_VAR_region`/`TF_VAR_state_bucket`; a root that reads another layer's
outputs (`terraform_remote_state`) declares `variable "state_bucket"` to get the bucket name.

## Why this layout

- **One VPC per environment, not per project.** Apps share their environment's network and
  are isolated from each other by security groups and IAM, not by VPC. Separate dev and prod
  VPCs mean a dev mistake can't reach prod's network at all. (For a harder boundary still,
  the next step up is a separate AWS *account* per environment - this layout moves there
  unchanged, just a different provider/credentials per `live/<env>`.)
- **Non-overlapping CIDRs** (dev `10.10.0.0/16`, prod `10.20.0.0/16`, and neither clashes
  with project-11's `10.0.0.0/16`) so peering/Transit Gateway/VPN stays possible later
  without renumbering.
- **Separate state per env and per layer.** `run.sh dev network destroy` touches only
  `dev/network.tfstate`; a later `dev/ecs` layer can't modify the VPC it sits in, it can only
  read its outputs.
- **One module, two thin roots.** dev and prod differ only in the few values set in
  `live/<env>/network/main.tf` - everything else is shared in `modules/vpc`.

## The VPC module

Three tiers, each spread across `az_count` AZs (default 2) from the start - the thing
project-12 had to patch in after the fact with its `rds-standby`/`alb-standby` subnets:

| Tier | Subnets (`10.x` = env's /16) | Route | For |
|---|---|---|---|
| public | `10.x.0.0/24`, `10.x.1.0/24` | `0.0.0.0/0` → Internet Gateway | ALBs, NAT instances, bastion |
| app | `10.x.10.0/24`, `10.x.11.0/24` | VPC-local only, until a NAT instance layer adds `0.0.0.0/0` | ECS tasks, EC2 |
| db | `10.x.20.0/24`, `10.x.21.0/24` | VPC-local only, no internet route | RDS |

Also:
- **No NAT in this layer.** Outbound internet for the app tier will come from self-managed NAT
  instances (like project-11's egress gateway), not managed NAT Gateways. Those get their own
  layer; it adds a `0.0.0.0/0` route to each app route table (one per AZ, exported as
  `app_route_table_ids`) pointing at its instance's network interface. Until then, app subnets
  reach only the VPC and S3.
- **S3 gateway endpoint** on the app/db route tables - free, and ECR image layers are pulled
  from S3, so Fargate image pulls skip the NAT instance.
- **Default security group locked down** - every rule stripped, so anything launched without
  an explicit SG gets no access rather than AWS's default allow-all-between-members.
- No tier security groups here (unlike project-11's `manage_network.sh`). SGs belong to the
  layer that owns the thing they protect - the ECS layer creates its task SG, the RDS layer
  its DB SG - so they're created and destroyed together with it.

## `modules/ami` - bake an image from `ami-scripts/*.sh`

Terraform has no resource that runs a script on a machine and snapshots it, so this module
drives **Packer** - the same build project-11's `run.sh ami` did, with the same
`ami-scripts/*.sh` (symlinked in), just triggered and tracked by Terraform:

```hcl
module "egress_gateway" {
  source           = "../../../modules/ami"
  name             = "egress-gateway"
  provision_script = "${path.root}/../../../ami-scripts/egress-gateway.sh"
  subnet_id        = <a public subnet>          # where the temporary builder runs
  region           = var.region
  # provision_env  = ["KEY=value"]              # exported to the script; not for secrets
  # base_ami_id    = "ami-..."                  # default: latest Amazon Linux 2023
}
# -> module.egress_gateway.ami_id
```

How it works (`modules/ami/main.tf`):

- A `terraform_data` resource runs `packer init/validate/build` against
  `modules/ami/packer/ami.pkr.hcl`. Packer launches a temporary builder in `subnet_id` with a
  public IP and a temporary SG (SSH only from your machine's IP) and a temporary key, waits
  for cloud-init, runs the script as root, snapshots, and cleans everything up - including on
  failure.
- The AMI is tagged `BuildId = <terraform_data id>`; `data.aws_ami` finds it by that tag, so
  `ami_id` is an ordinary output other layers can use.
- **When it rebuilds:** when the script's content, `provision_env`, `name`, the base AMI or
  the Packer template change. Plan shows `terraform_data.build must be replaced`. With the
  default base image, a new Amazon Linux 2023 release also triggers a rebuild; pin
  `base_ami_id` to stop that.
- **Old images are cleaned up:** a rebuild registers the new AMI first, then deregisters the
  old one and deletes its snapshots. `destroy` does the same. Instances already running from
  an old AMI keep running.
- Debugging a failing script: run Packer by hand with `-on-error=ask` against
  `modules/ami/packer` (see `project-11/ami-scripts/README.md`).

Each image has its own layer, `live/shared/ami-<image>/`, with one `module "ami"` block,
its own state (`shared/ami-<image>.tfstate`) and outputs `ami_id`/`ami_name`. That way
rebuilding one never plans or touches another. Images live in `shared`, not per env: built
once, the same image goes to dev and then prod.

To add an image, copy `live/shared/ami-nodejs/` to `live/shared/ami-<new>/`. Change
`backend.key` to `shared/ami-<new>.tfstate`, and change `name` and `provision_script` in the
module block. A layer that launches it reads `shared/ami-<new>.tfstate`'s `ami_id`.

## `modules/instance` - launch from an image

```hcl
module "nat" {
  source            = "../../../modules/instance"
  name              = "dev-nat"
  ami_id            = <module.ami.ami_id, or ami_id from shared/ami-<image>'s remote state>
  vpc_id            = <network output>
  subnet_ids        = <network public_subnet_ids>   # round-robin: instance i -> subnet_ids[i % n]
  instance_count    = 1
  source_dest_check = false                         # NAT/router
  elastic_ip        = true
  ingress_rules = [{ description = "from VPC", protocol = "-1", from_port = 0, to_port = 0,
                     cidr_blocks = ["10.10.0.0/16"] }]
}
# -> instance_ids, private_ips, public_ips, primary_network_interface_ids, security_group_id
```

Every instance gets IMDSv2 only, an encrypted gp3 root volume, and its own security group:
`ingress_rules` in, empty by default, and all traffic out. By default (`ssm_access = true`) it
also gets an IAM role with `AmazonSSMManagedInstanceCore`, so `aws ssm start-session` works
with no SSH key and no inbound rule. Optional settings: `elastic_ip`, `associate_public_ip`,
`source_dest_check`, `key_name`, `user_data`, `iam_policy_arns`, `root_volume_size`.

Instances are immutable: a new `ami_id` or `user_data` replaces them (new one first, then
the old one goes), rather than patching in place.

## NAT (`modules/nat`, `live/<env>/nat`)

The app subnets have no internet route of their own (see the VPC module). `modules/nat`
supplies one:

- `modules/instance` with the egress-gateway image in the **public** subnets, with
  source/dest check off, an Elastic IP each, and all traffic allowed in from the VPC CIDR.
  The image applies its NAT rules at boot (nftables masquerade, see
  `ami-scripts/egress-gateway.sh`), so it needs no user data.
- An `aws_route` `0.0.0.0/0` on each app route table pointing at a NAT instance's network
  interface. Route table *i* uses instance *i % count*. With one instance per AZ, each AZ
  goes out through its own instance; with one instance, both AZs share it.

| | instances | if an AZ goes down |
|---|---|---|
| dev | 1 | dev's app tier loses outbound internet until it's back |
| prod | 2 (one per AZ) | the other AZ keeps its own way out |

`./run.sh <env> nat output` shows `public_ips`: the app tier's egress IPs, to allowlist on
anything external. A new egress-gateway image replaces the instances: the new instance comes
up first, then the route and the Elastic IP move to it, so the IP stays the same.

## App (`live/<env>/app`)

The Node.js image (`ami-scripts/nodejs_caddy.sh`: Caddy on `:80` → Node on `127.0.0.1:3000`, with
`/health`), launched with `modules/instance` in the **private app subnets**, one per AZ (dev 1,
prod 2). Each instance has no public IP. Its security group allows only port 80, and only from
inside the VPC. Each also gets an SSM role.

**Apply `nat` first.** With no NAT the instances still boot and serve, but the SSM agent can't
reach AWS to register, so you can't connect to them.

There's no load balancer yet (next step). To reach the app now, use an SSM port forward
through your machine:

```bash
id=$(./run.sh dev app output -json instance_ids | jq -r '.[0]')
aws ssm start-session --target "$id" \
    --document-name AWS-StartPortForwardingSession \
    --parameters portNumber=80,localPortNumber=8080
# other terminal:
curl localhost:8080/health      # {"status":"ok","service":"node-app"}
```

This needs the [session-manager-plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
installed locally. `aws ssm start-session --target "$id"` alone gives a shell.

To deploy a new app version, change `ami-scripts/nodejs_caddy.sh` (or point it at your real app),
then run `./run.sh shared ami-nodejs apply` followed by `./run.sh <env> app apply`. The
instances are replaced from the new image: dev first, then prod, with the same image.

## Cost

Rough on-demand prices in ap-northeast-1:

| | each | dev | prod |
|---|---|---|---|
| Network | free | - | - |
| NAT instance (t3.micro) + Elastic IP | ≈ $10 + $3.60/month | 1 | 2 |
| App instance (t3.micro) | ≈ $10/month | 1 | 2 |
| AMI snapshot (8 GiB) | ≈ $0.40/month | 2 images, shared | |

That comes to about $24/month for dev, $47/month for prod, and under $1 for the images,
plus EBS root volumes at about $0.80 per instance. NAT instances also have no per-GB
processing fee, which a NAT Gateway would charge. `./run.sh <env> app destroy` and
`./run.sh <env> nat destroy` stop the charges and leave the network in place.

## State bucket (`bootstrap/`)

`cd-stack-gen-tfstate-<account-id>`: versioned, encrypted, public access blocked, old state
versions expired after 90 days, `prevent_destroy` set. It uses **local** state itself
(`bootstrap/terraform.tfstate`, gitignored) since it can't live in the bucket it creates.
Losing that file is harmless - the bucket just isn't Terraform-managed until you
`terraform import` it again.

## Tests

```bash
for m in vpc ami instance nat; do (cd modules/$m && terraform init && terraform test); done
```

All offline against a mock AWS provider, no credentials:

- **vpc:** subnet CIDR layout, subnets in distinct AZs, per-AZ app route tables, IGW
  routing, S3 endpoint attachment, a non-/16 CIDR rejected.
- **ami:** plan only, since an apply would run a real `packer build`. Covers the default AL2023
  base image, pinning `base_ami_id`, and the script's hash as a rebuild trigger. The Packer
  template itself is checked with
  `packer validate -var-file=<vars> modules/ami/packer`.
- **instance:** IMDSv2, encryption, SSM role, round-robin subnet placement, and the NAT-style
  settings (EIP per instance, source/dest check off, VPC-wide inbound rule, no role).
- **nat:** one shared instance routes both AZs; one per AZ routes each AZ to its own; more
  instances than AZs is rejected.
