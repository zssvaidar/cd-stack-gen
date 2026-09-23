# project-11 — unified run.sh: keys, network, ssm, instances, s3, ami, egress

A single dispatcher instead of one script per concern: `run.sh <keys|network|ssm|instances|s3|
ami|instance-ami|egress> [args] {create|delete}` sources the matching `manage_*.sh` fragment,
all of them sharing one Purpose-tagged state log at `state/$PURPOSE.env`. This is a leaner,
flatter alternative to `project-9/agent-keys` + `project-10/vpc-network` + `project-10/ssm-manage`
— same underlying AWS calls, one entry point and one state file instead of four separate ones.

```bash
cp wrapper/config/.env.example wrapper/config/.env   # fill in the creator credentials, once
export PURPOSE=testing

./run.sh network create                    # vpc + bastion/app/db security groups + subnets
./run.sh keys web-host create              # -> 2026-09-21_web-host, imported to AWS + Vault
./run.sh ssm create                        # instance profile wrapping the existing jenkins-role
./run.sh instances web 3 create            # 3 instances into the app-tier subnet, using all of the above
./run.sh s3 app-data create                # -> testing-app-data-<account-id>, blocked/encrypted/versioned
./run.sh ami myapp production create       # bake a custom AMI (see below)
./run.sh instance-ami myapp production 2 create   # launch instances from it
./run.sh ami gw egress-gateway create      # bake the NAT-instance AMI (see "egress" below)
./run.sh egress gw create                  # launch it, relay the app tier's outbound traffic through it
```

Every `create` appends to `state/testing.env` — `keys`/`network`/`ssm` write flat `export`
blocks (sourcing the file after several `network create` runs leaves the *last* one's values,
same idea as `project-9/agent-keys`'s log), `instances` prefixes each instance's exports with
its own name (`INSTANCE_WEB_1_ID`, `INSTANCE_WEB_2_ID`, …) since a batch is explicitly meant to
track several simultaneous instances rather than just the latest one.

## `run.sh instances <name> <count> {create|delete}`

The new piece. `create` reads everything it needs out of the already-accumulated state file —
nothing is passed by hand:

| from                    | state var(s)                                         | used for                        |
|---------------------------|--------------------------------------------------------|-----------------------------------|
| `run.sh network create`   | `APP_SUBNET_ID`/`APP_SG` (or the `bastion`/`db` pair, via `TIER`) | `--subnet-id`, `--security-group-ids` |
| `run.sh keys create`      | `DATE_NAME`                                             | `--key-name` (skipped if unset — SSM-only access) |
| `run.sh ssm create`       | `INSTANCE_PROFILE_NAME`                                 | `--iam-instance-profile` (skipped if unset) |

`TIER` (env var, default `app`) picks which of the three subnet/SG pairs `network create` made
to launch into. `AMI_ID` defaults to the latest Amazon Linux 2023 AMI for `$AWS_REGION`,
looked up via the public SSM parameter (`/aws/service/ami-amazon-linux-latest/...`) rather than
a hardcoded, region-specific ID — set it explicitly to launch something else.

Each instance in the batch is named `<name>-<i>` (1-indexed) and tagged `Purpose=$PURPOSE`,
`Name=<name>-<i>`, `Tier=$TIER`. `delete` terminates every instance matching that
`Purpose` + `Name=<name>-*` pattern — pass the same `<name>` (and any positive integer for
`<count>`, it's only read by `create`) to tear a batch back down:

```bash
./run.sh instances web 1 delete
```

Set `ROLE` and/or `ENVIRONMENT` (env vars, both unset/untagged by default) to add those as
extra tags — e.g. a deploy pipeline elsewhere that targets `aws ssm send-command --targets
"Key=tag:Role,Values=app-server" "Key=tag:Environment,Values=production"` needs instances
tagged with exactly those two to be picked up by that fleet-wide target:

```bash
ROLE=app-server ENVIRONMENT=production ./run.sh instances web 2 create
```

## `run.sh s3 <name> {create|delete}`

`create` makes `$BUCKET_NAME = ${PURPOSE}-${name}-${account_id}` — S3 bucket names are unique
across *all* of AWS, not just this account, so the account id suffix is what keeps `<name>`
alone (e.g. `app-data`) from colliding with someone else's bucket. Every bucket gets the same
three defaults applied, not left opt-in: public access fully blocked, SSE-S3 encryption, and
versioning enabled. Tagged `Purpose=$PURPOSE`, `Name=<name>`, appended to the state log the
same way `keys`/`network`/`ssm` are (flat `export BUCKET_NAME=...` — sourcing the log after
several `s3 create` runs leaves the *last* bucket's name).

```bash
./run.sh s3 app-data create
./run.sh s3 app-data delete
```

`delete` empties the bucket before removing it — including, deliberately, every object
*version* and delete marker versioning leaves behind, not just current objects. `aws s3 rm
--recursive` alone only adds delete markers on a versioned bucket; AWS still refuses to delete
a non-empty bucket afterward. Both purge loops run unconditionally and simply find nothing to
do if versioning was never turned on, so `delete` doesn't need to know or care.

## `run.sh ami <name> <env-type> {create|delete}` + `run.sh instance-ami <name> <env-type> <count> {create|delete}`

Two scripts, one job split in half: **`ami`** bakes a custom image, **`instance-ami`** launches
instances from one — same split as "build a golden image" vs. "launch it" anywhere else.

`ami create` builds the image with [Packer](https://developer.hashicorp.com/packer) instead of
hand-rolled EC2 API calls (launch, wait, snapshot, tag, terminate) — `packer/ami.pkr.hcl` owns
the actual build mechanics, `manage_ami.sh` just resolves inputs out of `$STATE_FILE`, drives
`packer init` → `packer validate` → `packer build`, and reads the resulting AMI ID/name back
out of Packer's manifest (`packer/packer-manifest.json`, gitignored) to append to state:

1. Resolves a base AMI (latest Amazon Linux 2023 by default, override with `BASE_AMI_ID`), the
   tier's subnet/security-group (same `TIER` variable as `instances`), and the instance profile
   from `run.sh ssm create` — same state-file wiring as everything else in this project.
2. Runs `packer build` against `packer/ami.pkr.hcl`, passing all of the above as `-var`s.
   Packer launches its own temporary builder instance, connects over **SSH** (not SSM — see
   below) as soon as sshd answers, waits for `cloud-init status --wait` to finish (cloud-init
   does its own `dnf`/`rpm` work at boot — starting the real provisioner before that's done
   races it for the rpm lock), then runs `ami-scripts/<env-type>.sh` as a shell provisioner
   under `sudo` — **that script is what actually defines the image**; see
   `ami-scripts/README.md` — then snapshots it into an AMI, tags the AMI/snapshot/builder, and
   tears the builder back down itself. None of that mechanics lives in bash anymore.
3. Parses `packer/packer-manifest.json` with `jq` for the built AMI's ID and name, then appends
   them to `$STATE_FILE`.

```bash
export ENV_TYPE=production   # picks ami-scripts/production.sh by default
./run.sh ami myapp production create
```

Prerequisites: `packer` and `jq` on PATH (`create` checks for both up front and fails fast with
an install link if either is missing; `delete` needs neither). Packer generates its own
ephemeral ed25519 keypair for each build and discards it afterward — the builder's SSH access
never depends on, or extends, anything from `run.sh keys`.

**The tier's security group needs an inbound rule for port 22**, since Packer connects over
plain SSH rather than through SSM — `manage_network.sh` creates all three tiers with zero
ingress rules, so this is the most likely first thing to trip up a cold start. `create` checks
for one and warns (doesn't block, since a broader rule or a different exact match could still
be fine) if it doesn't find an exact port-22 rule on the tier's SG:

```bash
../project-10/security-groups/scripts/add-rule.sh --sg <sg-id> --direction ingress \
    --protocol tcp --port 22 --cidr <your-ip>/32
```

An SSM-only alternative exists (Packer's `ssh_interface = "session_manager"`) that would avoid
opening port 22 at all, at the cost of needing the `session-manager-plugin` installed wherever
`packer build` runs plus broader IAM permissions on the builder's instance profile — documented
here as a known follow-up, not built, since it's harder to test without a real AWS account.

**The builder gets a public IP by default** (`ASSIGN_PUBLIC_IP=true`, passed through to
Packer's `associate_public_ip_address`). It has to: `manage_network.sh`'s subnets don't
auto-assign public IPs and this network has no NAT gateway, so without one the builder would
have a route to the Internet Gateway but nothing for it to NAT with — both the provisioning
script's own downloads (`curl`, `dnf install`, …) and Packer's SSH connection itself would just
hang. It's low-stakes since the builder is temporary and torn down right after imaging; set
`ASSIGN_PUBLIC_IP=false` only if you've set up a NAT gateway instead. The same reasoning applies
to `instances`/`instance-ami` if their app needs outbound internet access too — neither passes
the flag today.

**A public IP is also useless if the tier's subnet doesn't route straight to the IGW.**
`TIER` defaults to `app` — which is exactly the subnet `run.sh egress` relays through 0.0.0.0/0
to a NAT instance by default, once one's been created. AWS's 1:1 NAT for a public IP only works
if the subnet's own route table sends `0.0.0.0/0` to the Internet Gateway directly; if it's been
pointed at an egress gateway instead, the builder's public IP is unreachable and Packer's SSH
connection just hangs, identically to a missing port-22 rule. `create` checks the tier's route
table and warns (same non-blocking treatment as the port-22 check) if it doesn't find a route to
an `igw-*` target. Build in a tier that's never relayed instead — `bastion` is the safe default
once an egress gateway exists:

```bash
TIER=bastion ./run.sh ami myapp production create
```

State is keyed by `<name>`/`<env-type>` together (`AMI_MYAPP_PRODUCTION_ID`, same collision-safe
prefixing as `instances`), so `myapp`/`staging` and `myapp`/`production` coexist in the same
log without clobbering each other.

`instance-ami create` looks up that exact `AMI_..._ID` and launches `<count>` instances from
it — same tier/key/profile wiring, same `ROLE` tag support, as `instances`, just sourcing the
AMI from this registry instead of the latest-AL2023 lookup. It's unaffected by the Packer
rewrite — it only ever reads an `AMI_..._ID` out of state, agnostic to how that AMI got built:

```bash
./run.sh instance-ami myapp production 3 create
./run.sh instance-ami myapp production 1 delete   # <count> only matters for create
```

`ami delete` finds every AMI tagged with that exact `Purpose`/`Name`/`Environment`, deregisters
each one, and deletes its backing snapshot(s) — looked up *before* deregistering, since an
image's metadata (and the snapshot IDs in it) disappears the moment it's deregistered. This
side is unchanged from before Packer: Packer builds images, it doesn't manage teardown of what
it built, so cleanup stays plain `aws` CLI, same as the rest of this project.

## `run.sh egress <name> {create|delete}`

A small public EC2 instance acting as a self-managed NAT instance — the cheap, DIY version of a
NAT Gateway. `manage_network.sh`'s app/db subnets have a route to the Internet Gateway already
(all three tiers share `PUBLIC_RT_ID`) but no public IP and no NAT, so nothing in them can
actually reach the internet. This fills that gap: private instances keep no public IP of their
own (e.g. an app instance running its own `cloudflared`, same as `bun-hydrate`) and route their
outbound traffic through this one relay instead.

```bash
export ENV_TYPE=egress-gateway
./run.sh ami gw egress-gateway create      # bake the NAT-capable AMI - see ami-scripts/README.md
./run.sh egress gw create                  # launch it and rewire the app subnet at it
```

`create`:
1. Looks up the AMI built via `run.sh ami <ami-name> egress-gateway create` (`AMI_NAME`, default
   same as this instance's `<name>`, lets the AMI and the instance be named independently).
2. Creates a dedicated security group allowing all traffic in from the VPC's own CIDR (looked
   up from `$VPC_ID`, not hardcoded) — forwarded traffic hitting this instance's ENI is filtered
   by its security group exactly like traffic addressed to the instance itself, so this has to
   be broader than the empty per-tier SGs `manage_network.sh` creates.
3. Launches into `$TIER` (default `bastion`) **with a public IP** — it has to have one, that's
   the entire point — then disables source/dest check on it (`modify-instance-attribute
   --no-source-dest-check`), the one EC2-API-level setting that actually makes an instance route
   traffic instead of AWS silently dropping anything not addressed to it, no matter what the OS
   does.
4. Creates a new route table with `0.0.0.0/0 -> <this instance>`, then points `RELAY_SUBNET_IDS`
   (env var, default `$APP_SUBNET_ID` only) at it via `replace-route-table-association` — those
   subnets leave the shared `PUBLIC_RT_ID` and start routing their default traffic through the
   gateway instead of straight to the Internet Gateway (which never worked for them anyway,
   since they have no public IP for its 1:1 NAT to use).

The AMI itself (`ami-scripts/egress-gateway.sh`) bakes in IP forwarding and an nftables
MASQUERADE rule, persisted across reboots by a systemd unit that re-resolves the primary
network interface at every boot rather than hardcoding `eth0`/`ens5`. Its forward chain only
accepts traffic sourced from RFC1918 ranges — a public instance with an unrestricted forward
chain is an open relay for anyone on the internet who can route packets to it.

**DB tier is deliberately left off by default** — `RELAY_SUBNET_IDS` only includes
`$APP_SUBNET_ID` unless you override it (e.g. `RELAY_SUBNET_IDS="$APP_SUBNET_ID $DB_SUBNET_ID"`).
A tier that shouldn't need outbound internet access in the first place shouldn't get it just
because it's convenient.

`delete` finds the gateway instance(s) by `Purpose`/`Name`/`Role=egress-gateway` tags, then —
for each one — finds every route table with a route pointing *at* that instance-id (not by
trusting `RELAY_SUBNET_IDS` to still match what `create` was run with; the route tables
themselves are the source of truth for what's currently relayed through it), restores each of
those subnets to `$PUBLIC_RT_ID`, deletes the private route table, terminates the instance, and
finally deletes its security group:

```bash
./run.sh egress gw delete
```

## Fixed while porting this in

Two things from the original scripts that only mattered on a cold start / an edge case, not on
the happy path that already produced real infrastructure:

- `run.sh` used to require `state/$PURPOSE.env` to already exist, which made `network create`
  impossible to run for the very first time under a new `PURPOSE`. It now creates `state/` and
  an empty state file if missing.
- `manage_keys.sh` had two dead lines at the top (`DATE_NAME="$DATE_${NAME}"` — `$DATE_` parses
  as one unset variable, not `$DATE` + `_`; and a `KEY_DIR` built from `$SCRIPT_DIR` before
  `SCRIPT_DIR` was set) that `create()` immediately recomputed correctly and `delete()` never
  read at all. Removed rather than fixed in place, since nothing depended on them.

## Relationship to project-9 / project-10

Same ideas, different shape:

- `project-9/agent-keys` ≈ `manage_keys.sh` (per-`date_name` state entries, purpose tagging,
  Vault storage) — that version keeps its own dedicated `README.md`/`.gitignore`/policy file
  and documents the Vault ACL for Jenkins in detail.
- `project-10/vpc-network` + `project-10/security-groups` ≈ `manage_network.sh` — the
  project-10 version splits public/private subnets across 2 AZs with (optionally) a NAT
  Gateway and wires 3 separate security groups together via `--peer-sg` references;
  `manage_network.sh` here is flatter: one public subnet per tier, one shared route table, all
  three security groups created empty (you add rules yourself, e.g. with
  `../project-10/security-groups/scripts/add-rule.sh` if you want the same bastion → app → db
  wiring).
- `project-10/ssm-manage` ≈ `manage_ssm.sh` — project-10's version creates a dedicated
  `ssm-instance-role-$PURPOSE` IAM role from scratch; `manage_ssm.sh` instead reuses the
  existing `jenkins-role` from `project-8/aws-perm-generator` (override with `ROLE_NAME` if
  that's not what you want), so it only ever creates the instance profile.

Pick whichever fits — project-11 for a fast, single-file loop with one shared state log;
project-9/project-10 when you want each concern documented and tested on its own.
