# project-11 — unified run.sh: keys, network, ssm, instances, s3, ami

A single dispatcher instead of one script per concern: `run.sh <keys|network|ssm|instances|s3|
ami|instance-ami> [args] {create|delete}` sources the matching `manage_*.sh` fragment, all of
them sharing one Purpose-tagged state log at `state/$PURPOSE.env`. This is a leaner, flatter
alternative to `project-9/agent-keys` + `project-10/vpc-network` + `project-10/ssm-manage` —
same underlying AWS calls, one entry point and one state file instead of four separate ones.

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

`ami create`:
1. Launches a temporary "builder" instance (same subnet/key/instance-profile wiring as
   `instances`) from a base AMI (latest Amazon Linux 2023 by default, override with
   `BASE_AMI_ID`), with `ami-scripts/<env-type>.sh` attached as user-data — **that script is
   what actually defines the image**; see `ami-scripts/README.md`.
2. Waits for it to actually finish provisioning — `cloud-init status --wait` run over SSM,
   polled for up to 5 minutes (`instance-running` only means the instance answered, not that
   user-data has finished).
3. Stops the builder (a consistent filesystem snapshot beats letting `create-image` reboot it
   mid-flight), creates the image, tags both the image and its snapshot, waits for the image to
   become `available`, then terminates the builder — the *image* is the deliverable, not the
   instance.

```bash
export ENV_TYPE=production   # picks ami-scripts/production.sh by default
./run.sh ami myapp production create
```

State is keyed by `<name>`/`<env-type>` together (`AMI_MYAPP_PRODUCTION_ID`, same collision-safe
prefixing as `instances`), so `myapp`/`staging` and `myapp`/`production` coexist in the same
log without clobbering each other.

`instance-ami create` looks up that exact `AMI_..._ID` and launches `<count>` instances from
it — same tier/key/profile wiring, same `ROLE` tag support, as `instances`, just sourcing the
AMI from this registry instead of the latest-AL2023 lookup:

```bash
./run.sh instance-ami myapp production 3 create
./run.sh instance-ami myapp production 1 delete   # <count> only matters for create
```

`ami delete` finds every AMI tagged with that exact `Purpose`/`Name`/`Environment`, deregisters
each one, and deletes its backing snapshot(s) — looked up *before* deregistering, since an
image's metadata (and the snapshot IDs in it) disappears the moment it's deregistered.

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
