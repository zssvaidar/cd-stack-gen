# project-13 — Terraform, one VPC per environment

project-11/12 built everything with aws-cli scripts and a `PURPOSE`-tagged state file, one
network per `PURPOSE`. project-13 redoes the same ground in Terraform, the way it's usually
laid out in practice: **one VPC per environment (dev, prod)**, shared by every app deployed
into that environment, each layer in its own root module with its own state.

Built step by step:

1. The state bucket and the dev/prod VPCs.
2. Modules for baking an AMI from `ami-scripts/*.sh` and launching instances from it.
3. Images in `shared/ami-*` (egress-gateway, nodejs), NAT instances per env, and the
   Node.js app on plain EC2 instances per env.
4. Vault per env: a Docker image running Vault, S3 storage, KMS auto-unseal.
5. **(this)** [project-14](../project-14/)'s four apps (Laravel, Spring Boot, ASP.NET Core, Go) on
   plain EC2 behind Caddy, plus a monitoring host per env (Grafana, Mimir, Loki) that Grafana
   Alloy on every app instance ships metrics and logs to.

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
    vault/                    Vault server: S3 storage bucket, KMS unseal key, instance (uses instance/)
    */tests/*.tftest.hcl      offline tests (mock provider, no AWS creds)
  live/                       one folder per deployment, each its own state <env>/<layer>.tfstate
    shared/ami-egress-gateway/  NAT image, used by every env's nat layer
    shared/ami-nodejs/        Node.js app image, used by every env's app layer
    shared/ami-docker-vault/  Docker + Vault image, used by every env's vault layer
    shared/ami-laravel/       project-14 images (ami-scripts/<app>.sh), each used by
    shared/ami-spring/          that app's layer in every env
    shared/ami-csharp/
    shared/ami-go/
    shared/ami-grafana/       monitoring image (ami-scripts/grafana.sh), used by every env's monitoring layer
    dev/network/              dev VPC   - 10.10.0.0/16
    dev/nat/                  1 NAT instance, shared by both AZs
    dev/app/                  1 Node.js instance
    dev/vault/                Vault (1 instance) + its S3 bucket and KMS key
    dev/monitoring/           Grafana + Mimir + Loki (1 instance)
    dev/laravel/              1 instance each, Alloy pointed at dev/monitoring
    dev/spring/
    dev/csharp/
    dev/go/
    prod/network/             prod VPC  - 10.20.0.0/16
    prod/nat/                 2 NAT instances, one per AZ
    prod/app/                 2 Node.js instances, one per AZ
    prod/vault/               Vault (1 instance) + its S3 bucket and KMS key
    prod/monitoring/          Grafana + Mimir + Loki (1 instance)
    prod/laravel/             2 instances each, one per AZ, Alloy pointed at prod/monitoring
    prod/spring/
    prod/csharp/
    prod/go/
```

Layers depend on each other only through state outputs (`terraform_remote_state`), so apply
them in order:

```
dev network ─┬─► shared/ami-egress-gateway ─► <env> nat ─┐
             └─► shared/ami-nodejs ──────────────────────┴─► <env> app
<env> network ─► <env> nat ─► <env> app

dev network ─► shared/ami-grafana ───────► <env> monitoring ─┐
dev network ─► shared/ami-<app> ─────────────────────────────┴─► <env> <app>    (<app> = laravel, spring, csharp, go)
<env> network ─► <env> nat ──────────────────────────────────────┘
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

# project-14's apps + monitoring - images once (shared), then per env: monitoring, then the apps
for i in grafana laravel spring csharp go; do ./run.sh shared ami-$i apply; done
./run.sh dev monitoring apply
for a in laravel spring csharp go; do ./run.sh dev $a apply; done
./run.sh dev monitoring output     # private_ip, grafana_port_forward

./run.sh prod monitoring apply
for a in laravel spring csharp go; do ./run.sh prod $a apply; done
```

Tear down in reverse: `app`, `nat`, then `network`. `network` can't be destroyed while
instances are still in its subnets. `./run.sh shared ami-<image> destroy` deregisters that image.

`run.sh <env> <layer> <action>` runs `terraform init` with the right backend config on first
use, then the action in `live/<env>/<layer>`. Anything after the action is passed through
(`./run.sh prod network plan -out=prod.tfplan`). Override the bucket name with
`TF_STATE_BUCKET=...` and the region with `AWS_REGION=...` (default `ap-northeast-1`). Both
reach every root as `TF_VAR_region`/`TF_VAR_state_bucket`; a root that reads another layer's
outputs (`terraform_remote_state`) declares `variable "state_bucket"` to get the bucket name.

## project-14's apps and monitoring

The images come from project-14's AMI scripts (`ami-scripts/{laravel,spring,csharp,go,grafana}.sh`,
see the ami-scripts README). Each one builds its app on the Packer builder from this repo's git.
The scripts default to GitHub at `master`, and each `shared/ami-*` layer passes its `app_ref`
variable as `APP_REF`. To bake from another branch or a tag, use
`TF_VAR_app_ref=my-branch ./run.sh shared ami-go apply`. The ami module only rebuilds when the script,
`app_ref`, the base AMI or the Packer template change, so a new commit on the same branch doesn't
rebuild by itself. Use a new tag, or force it with
`./run.sh shared ami-go apply -replace=module.ami.terraform_data.build`. The builders are sized per
image: t3.medium for Spring, C# and Grafana, t3.small for Laravel and Go.

Each env gets its own monitoring host, so dev and prod data never mix. dev runs one instance per
app, and prod runs two per app, one per AZ. `<env>/monitoring` is one instance in an app subnet: Grafana on 3000, Mimir on 9009 and Loki on 3100,
all VPC-only, with a 30 GB root volume for retention. Each `<env>/<app>` layer reads its `private_ip`
and writes it into `/etc/alloy/endpoint.env` through user_data, which turns that instance's Alloy
on. Apply `<env>/monitoring` before that env's apps. If you replace it, its IP changes, and re-applying each app
layer replaces those instances too, since everything here is immutable. To reach Grafana, run the
`grafana_port_forward` output command locally, then open http://localhost:3000 and log in as
`admin`. The password is in `/etc/grafana/admin.env` on the monitoring instance (read it over an
SSM session). The apps listen on 80, Caddy, from the VPC only. There's no load balancer yet, so
each layer outputs the health check path a target group would use. Laravel has no RDS here, so it
runs on the instance's own SQLite file, which is lost when the instance is replaced.

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

## Vault (`modules/vault`, `live/<env>/vault`)

HashiCorp Vault in a Docker container on one EC2 instance, with its data in S3:

```
dev/vault
  ├─ S3 bucket   dev-vault-storage-…   Vault's storage backend (versioned, encrypted, private)
  ├─ KMS key     alias/dev-vault-unseal auto-unseal - no unseal keys to enter after a restart
  ├─ IAM         instance role: that bucket + that key only (plus SSM)
  └─ instance    docker-vault image, private app subnet, :8200 from inside the VPC only
```

**The image** (`ami-scripts/docker_vault.sh`, layer `shared/ami-docker-vault`) contains:
- Docker, and the `hashicorp/vault:2.1.2` image pinned by digest and pulled at build time, so
  instances never need Docker Hub.
- `vault.service`, which runs the container with host networking and `IPC_LOCK`.
- A renderer that runs before every start. It writes `vault.hcl` from `/etc/vault/vault.env`,
  which user-data fills with the bucket, key ID and region. On first boot it also generates a
  self-signed TLS certificate for the instance's private IP, so no private key is ever baked
  into the image.
- A `vault` command on the host that runs the CLI inside the container, already pointed at the
  server.

**Single instance by design.** Vault's S3 backend doesn't support HA. Everything lives in the
bucket, so the instance is disposable: replacing it (new image, `user_data` change, another AZ)
brings back the same Vault, unsealed by KMS.

### Run it
```bash
./run.sh shared ami-docker-vault apply   # ~5-10 min
./run.sh dev nat apply                   # first - KMS is reached through the NAT
./run.sh dev vault apply
./run.sh dev vault output                # vault_addr, instance_id, storage_bucket, kms_alias
```

### Initialize once
A new Vault starts uninitialized. On the instance, through SSM:
```bash
aws ssm start-session --target "$(./run.sh dev vault output -raw instance_id)"
sudo vault status                         # Initialized: false, Seal Type: awskms
sudo vault operator init                  # prints 5 recovery keys + the initial root token
```
**Store the recovery keys and root token somewhere safe, outside AWS** (a password manager).
With KMS auto-unseal the recovery keys don't unseal anything, but they're needed for some
operations, such as generating a new root token. Vault never shows them again. After that:
```bash
sudo VAULT_TOKEN=<root token> vault secrets enable -path=secret kv-v2
sudo VAULT_TOKEN=<root token> vault kv put secret/hello value=world
```
Restarts and instance replacements unseal on their own from then on (`vault status` shows
`Sealed: false`).

### Reaching it
`vault_addr` (`https://<private-ip>:8200`) only works from inside the VPC. From your machine,
use an SSM port forward, then trust the instance's self-signed certificate:
```bash
aws ssm start-session --target <instance_id> --document-name AWS-StartPortForwardingSession \
    --parameters portNumber=8200,localPortNumber=8200
# copy the CA once: on the instance, sudo cat /etc/vault/tls/vault.crt
export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=./vault.crt
vault status          # UI: https://127.0.0.1:8200/ui
```
The certificate is regenerated when the instance is replaced, so copy it again after that.

### Protecting the data
The bucket and the KMS key have `prevent_destroy`, so **`./run.sh <env> vault destroy` fails at
plan time** with `Instance cannot be destroyed`, before anything is deleted. A full destroy
followed by `apply` would otherwise reuse the old bucket with a brand-new KMS key, which can't
unseal the existing data.

Recreating just the server is safe; the data and the logins (userpass, tokens) stay in S3:

```bash
./run.sh dev vault apply   -replace='module.vault.module.instance.aws_instance.this[0]'
./run.sh dev vault destroy -target='module.vault.module.instance'   # remove the server only
```

The new instance gets a new IP and a new self-signed certificate, so restart the tunnel and copy
`vault.crt` again.

To wipe a Vault for good: remove both `prevent_destroy` blocks in `modules/vault/main.tf`, empty
the (versioned) bucket, then destroy.

- **The bucket:** also `force_destroy = false`, so even without `prevent_destroy` it can't be
  deleted while it holds data. Versioning keeps overwritten objects for 30 days.
- **The KMS key:** destroying it schedules deletion with a 30-day window. Once it's actually
  deleted, the data in S3 can never be unsealed again. `aws kms cancel-key-deletion` undoes a
  mistake within the window.
- **Backups:** the bucket is the backup unit. Copying its objects (or enabling S3 replication)
  backs up Vault, but only together with the KMS key.

## Cost

Rough on-demand prices in ap-northeast-1:

| | each | dev | prod |
|---|---|---|---|
| Network | free | - | - |
| NAT instance (t3.micro) + Elastic IP | ≈ $10 + $3.60/month | 1 | 2 |
| App instance (t3.micro) | ≈ $10/month | 1 | 2 |
| AMI snapshot (8 GiB) | ≈ $0.40/month | 3 images, shared | |
| Vault: t3.small + KMS key + S3 | ≈ $20 + $1 + cents/month | 1 | 1 |

That comes to about $45/month for dev, $68/month for prod (Vault included), and about $1.20
for the images,
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
for m in vpc ami instance nat vault; do (cd modules/$m && terraform init && terraform test); done
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
- **vault:** (plan-only, since prevent_destroy blocks the test teardown) exactly one instance;
  user-data passes the real bucket, key and region; the
  storage bucket can't be force-destroyed and blocks public access; the KMS key rotates and has
  a 30-day deletion window.
