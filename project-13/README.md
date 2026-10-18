# project-13 — Terraform, one VPC per environment

project-11/12 built everything with aws-cli scripts and a `PURPOSE`-tagged state file, one
network per `PURPOSE`. project-13 redoes the same ground in Terraform, the way it's usually
laid out in practice: **one VPC per environment (dev, prod)**, shared by every app deployed
into that environment, each layer in its own root module with its own state.

Built step by step. **Step 1 (this): the state bucket and the dev/prod VPCs.** App layers
(ECS cluster, RDS, bun-hydrate services) come next, each reading the network's outputs rather
than creating their own.

```
project-13/
  run.sh                      wrapper creds + terraform, same shape as project-11/12's run.sh
  wrapper -> ../project-9/wrapper
  bootstrap/                  S3 state bucket (local state - see below)
  modules/
    vpc/                      the one VPC module both envs use
      tests/vpc.tftest.hcl    offline tests (mock provider, no AWS creds)
  live/
    dev/network/              dev VPC   - 10.10.0.0/16, state key dev/network.tfstate
    prod/network/             prod VPC  - 10.20.0.0/16, state key prod/network.tfstate
```

## Prerequisites

- Terraform >= 1.10 (S3-native state locking - no DynamoDB table).
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
```

`run.sh <env> <layer> <action>` runs `terraform init` with the right backend config on first
use, then the action in `live/<env>/<layer>`. Anything after the action is passed through
(`./run.sh prod network plan -out=prod.tfplan`). Override the bucket name with
`TF_STATE_BUCKET=...` and the region with `AWS_REGION=...` (default `ap-northeast-1`).

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

## Cost

Free: VPC, subnets, route tables, the internet gateway and the S3 gateway endpoint cost
nothing. The paid parts (NAT instances, then the app layers) come in later steps.

## State bucket (`bootstrap/`)

`cd-stack-gen-tfstate-<account-id>`: versioned, encrypted, public access blocked, old state
versions expired after 90 days, `prevent_destroy` set. It uses **local** state itself
(`bootstrap/terraform.tfstate`, gitignored) since it can't live in the bucket it creates.
Losing that file is harmless - the bucket just isn't Terraform-managed until you
`terraform import` it again.

## Tests

```bash
cd modules/vpc
terraform init
terraform test
```

Runs entirely offline against a mock AWS provider: checks the subnet CIDR layout, that subnets
land in distinct AZs, the per-AZ app route tables, IGW routing, S3 endpoint attachment, and that a non-/16 CIDR
is rejected.
