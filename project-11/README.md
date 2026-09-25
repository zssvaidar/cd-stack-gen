# project-11 — unified run.sh: keys, network, ssm, instances, s3, ami, egress, egress-balancer

A single dispatcher instead of one script per concern: `run.sh <keys|network|ssm|instances|s3|
ami|instance-ami|egress|egress-balancer> [args] {create|delete}` sources the matching `manage_*.sh` fragment,
all of them sharing one Purpose-tagged state log at `state/$PURPOSE.env`. This is a leaner,
flatter alternative to `project-9/agent-keys` + `project-10/vpc-network` + `project-10/ssm-manage`
— same underlying AWS calls, one entry point and one state file instead of four separate ones.

```bash
cp wrapper/config/.env.example wrapper/config/.env   # fill in the creator credentials, once
export PURPOSE=testing

./run.sh network create                    # vpc + bastion/app/db/egress security groups + subnets
./run.sh keys web-host create              # -> 2026-09-21_web-host, imported to AWS + Vault
./run.sh ssm create                        # instance profile wrapping the existing jenkins-role
./run.sh instances web 3 create            # 3 instances into the app-tier subnet, using all of the above
./run.sh s3 app-data create                # -> testing-app-data-<account-id>, blocked/encrypted/versioned
./run.sh ami myapp production create       # bake a custom AMI (see below)
./run.sh instance-ami myapp production 2 create   # launch instances from it
TIER=egress ./run.sh ami gw egress-gateway create   # bake the NAT-instance AMI (see "egress" below)
./run.sh egress gw create                  # launch it into its own tier, relay the app tier through it
TIER=egress ./run.sh ami lb egress-balancer create  # or: NAT + nginx load balancer in one AMI (see below)
BACKEND_NAME='myapp-production-*' ./run.sh egress-balancer lb create
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

"Which technologies get installed" is just "what `ami-scripts/<env-type>.sh` does" — there's no
separate picker mechanism, the script body is the choice. `ami-scripts/nodejs.sh` is a real,
runnable example (nginx + Node.js, a systemd unit, a build-time smoke test through the reverse
proxy) worth copying as a starting point instead of writing one from scratch; see
`ami-scripts/README.md` for what it does and how to swap in your own stack.

Prerequisites: `packer` and `jq` on PATH (`create` checks for both up front and fails fast with
an install link if either is missing; `delete` needs neither). Packer generates its own
ephemeral ed25519 keypair for each build and discards it afterward — the builder's SSH access
never depends on, or extends, anything from `run.sh keys`.

**SSH to the builder is opened automatically.** Packer connects over plain SSH rather than
through SSM, and `manage_network.sh` creates all four tiers with zero ingress rules. So by
default (`BUILD_SG=temporary`) the builder doesn't use the tier's SG at all. Packer creates a
throwaway SG that allows tcp/22 only from the public IP of the machine running `packer build`
(`temporary_security_group_source_public_ip`), and deletes it together with the builder. There
is nothing to open by hand, and the shared tier SGs are never modified.

`BUILD_SG=tier` restores the old behaviour: the builder runs in the tier's own SG, which must
then already allow port 22. `create` warns if it finds no exact port-22 rule there:

```bash
BUILD_SG=tier ./run.sh ami myapp production create
../project-10/security-groups/scripts/add-rule.sh --sg <sg-id> --direction ingress \
    --protocol tcp --port 22 --cidr <your-ip>/32      # only needed with BUILD_SG=tier
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
connection just hangs. `create` checks the tier's route
table and warns (non-blocking) if it doesn't find a route to
an `igw-*` target. Build in a tier that's never relayed instead — `bastion` or `egress` are both
safe once an egress gateway exists (`RELAY_SUBNET_IDS` only ever defaults to the app subnet):

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

**Cloudflare Tunnel on app instances.** For an image that ships `cloudflared` switched off
(`ami-scripts/bun_cloudflared.sh`), pass the tunnel token on `create`, the same way as for
`egress`/`egress-balancer`:

```bash
./run.sh ami myapp bun_cloudflared create
read -rs CLOUDFLARE_TUNNEL_TOKEN && export CLOUDFLARE_TUNNEL_TOKEN
./run.sh instance-ami myapp bun_cloudflared 2 create
unset CLOUDFLARE_TUNNEL_TOKEN
```

This works the same way as the egress tunnel option: `lib_cloudflare_tunnel.sh`. The token is
stored as a SecureString at `/<purpose>/app/<name>-<env-type>/cloudflare-tunnel-token` (or reuse
one with `CLOUDFLARE_TUNNEL_PARAM`). The instance role gets an inline read policy for exactly
that parameter, and each instance receives only the parameter name via user-data. All instances
of the batch share the token, so each runs a connector for the same tunnel, and Cloudflare
load-balances across them. `delete` removes the batch's read policy and the default-path
parameter. Rotating the token means storing a new one and relaunching the batch, since
`instance-ami` has no `sync`. Passing a token for an image without `cloudflared` (e.g. plain
`bun.sh`) stores and grants it, but the user-data step then fails on the box. The app itself is
unaffected.

`ami delete` finds every AMI tagged with that exact `Purpose`/`Name`/`Environment`, deregisters
each one, and deletes its backing snapshot(s) — looked up *before* deregistering, since an
image's metadata (and the snapshot IDs in it) disappears the moment it's deregistered. This
side is unchanged from before Packer: Packer builds images, it doesn't manage teardown of what
it built, so cleanup stays plain `aws` CLI, same as the rest of this project.

## `run.sh egress <name> {create|sync|delete}`

A small public EC2 instance acting as a self-managed NAT instance — the cheap, DIY version of a
NAT Gateway. `manage_network.sh`'s app/db subnets have a route to the Internet Gateway already
(all four tiers share `PUBLIC_RT_ID`) but no public IP and no NAT, so nothing in them can
actually reach the internet. This fills that gap: private instances keep no public IP of their
own (e.g. an app instance running its own `cloudflared`, same as `bun-hydrate`) and route their
outbound traffic through this one relay instead.

`manage_network.sh` gives this its own `egress` tier/subnet/SG, separate from `bastion` — a NAT
instance and an SSH jump box are different concerns even though both need a public IP, and
mixing them into one subnet/SG means SSH-access rules and NAT-relay rules end up on the same
security group. `manage_egress_instance.sh` still creates its own **dedicated** SG per gateway
instance rather than using the tier-wide `EGRESS_SG` directly — see step 2 below.

```bash
export ENV_TYPE=egress-gateway
TIER=egress ./run.sh ami gw egress-gateway create   # bake the NAT-capable AMI - see ami-scripts/README.md
./run.sh egress gw create                            # launch it and rewire the app subnet at it
```

`create`:
1. Looks up the AMI built via `run.sh ami <ami-name> egress-gateway create` (`AMI_NAME`, default
   same as this instance's `<name>`, lets the AMI and the instance be named independently).
2. Creates a dedicated security group allowing all traffic in from the VPC's own CIDR (looked
   up from `$VPC_ID`, not hardcoded) — forwarded traffic hitting this instance's ENI is filtered
   by its security group exactly like traffic addressed to the instance itself, so this has to
   be broader than the empty per-tier SGs `manage_network.sh` creates. One dedicated SG per
   gateway instance instead of sharing the tier-wide `EGRESS_SG` keeps multiple gateways (e.g.
   different `<name>`s) from being forced onto identical rules.
3. Launches into `$TIER` (default `egress`) **with a public IP** — it has to have one, that's
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

**The `egress` tier doesn't retrofit onto a network you already ran `network create` on** —
`manage_network.sh` always builds a brand-new VPC, it isn't incremental, so `EGRESS_SUBNET_ID`
only exists in `$STATE_FILE` after a fresh `run.sh network create`. A gateway already running
under the old `TIER=bastion` default keeps working right where it is; there's nothing to
migrate unless you tear the whole network down and rebuild it.

### HTTPS on `egress`: inbound passthrough

A plain `egress` gateway has no web server — outbound HTTPS from the app tier already works
through it like any other traffic. What it can optionally do is accept **inbound** HTTPS on its
public IP and pass the raw TCP stream to one app instance, which terminates TLS itself (its
own cert, e.g. certbot on the app box or a Cloudflare origin cert). No certificate ever lives on
the gateway. Set either variable to turn it on:

```bash
HTTPS_BACKEND_NAME='myapp-production-*' ./run.sh egress gw create   # first running match
HTTPS_BACKEND_IP=10.0.1.23 ./run.sh egress gw sync                  # re-point after a relaunch
HTTPS_BACKEND_IP=none ./run.sh egress gw sync                       # turn it off again
```

- The image's NAT script (`ami-scripts/egress-gateway.sh`) reads `/etc/egress-gateway/https-forward`
  (`ip:port`) and adds an nftables `dnat` for tcp/443 **addressed to the gateway itself**
  (`fib daddr type local`). That matters: the relayed app tier's own outbound HTTPS arrives on
  the same interface with dport 443 and must not be hijacked. An empty file means no prerouting
  chain at all, the same as before. **Rebuild the AMI** (`TIER=egress ./run.sh ami gw egress-gateway create`)
  to get this: images baked before it ignore the file.
- The DNAT'd connection is masqueraded like everything else leaving the box, so the backend
  replies to the gateway. This works however the backend's subnet routes, but the backend sees the
  gateway's private IP rather than the client's (there's no `X-Forwarded-For` in a TLS stream).
  Use `egress-balancer` if you need the client IP or more than one backend.
- `create` writes the target via user-data. `sync` re-resolves it and pushes it over SSM, which needs
  `run.sh ssm create`'s instance profile. Both add tcp/443 from `HTTPS_INGRESS_CIDR` (default
  `0.0.0.0/0`) on the gateway's SG, and tcp/`HTTPS_BACKEND_PORT` (default 443) **from the gateway's
  SG** on `HTTPS_BACKEND_SG` (default `$APP_SG`). `delete` revokes rules that reference the
  gateway's SG before deleting it.

### Cloudflare Tunnel on `egress` / `egress-balancer`

Both AMIs ship `cloudflared`, switched off. Pass a tunnel token once and the manager stores it in
**SSM Parameter Store as a SecureString**. The instance then fetches it itself every time
cloudflared starts:

```bash
read -rs CLOUDFLARE_TUNNEL_TOKEN && export CLOUDFLARE_TUNNEL_TOKEN    # keeps it out of shell history

./run.sh egress-balancer lb create     # or sync on a running one; same for `egress gw`
# -> stored at /testing/egress-balancer/lb/cloudflare-tunnel-token, cloudflared started

unset CLOUDFLARE_TUNNEL_TOKEN
CLOUDFLARE_TUNNEL_TOKEN=<new> ./run.sh egress-balancer lb sync       # rotate: overwrite + restart
CLOUDFLARE_TUNNEL_PARAM=none  ./run.sh egress-balancer lb sync       # stop the tunnel
CLOUDFLARE_TUNNEL_PARAM=/shared/cf-token ./run.sh egress gw create   # reuse an already-stored token
```

- **Where the token lives.** It is written to `/<purpose>/<egress-gateway|egress-balancer>/<name>/cloudflare-tunnel-token`
  (override with `CLOUDFLARE_TUNNEL_PARAM`) via a 0600 temp file, so it never appears in `ps`.
  The token is kept out of the AMI, the user-data and the SSM command history: the instance only
  ever receives the parameter's *name*. The instance's
  `cloudflare-tunnel.service` reads the value with `aws ssm get-parameter --with-decryption` at
  every start, and hands it to cloudflared as `TUNNEL_TOKEN` in its environment, never on disk
  and never on a command line. `delete` removes the parameter if it's at the default path. A
  parameter you named yourself is left alone, since it may be shared.
- **Read access is granted automatically.** On every `create`/`sync` that sets a tunnel, the
  manager attaches an inline policy to the role behind the instance profile (`jenkins-role` by
  default, looked up from the profile itself). The policy allows `ssm:GetParameter` on exactly
  that one parameter's ARN and nothing wider. It's named `cloudflare-tunnel-<purpose>-<egress-gateway|egress-balancer>-<name>`,
  so each gateway or balancer has its own. Re-running it is harmless (`put-role-policy`
  overwrites). It is re-pointed when `CLOUDFLARE_TUNNEL_PARAM` changes, and removed by
  `CLOUDFLARE_TUNNEL_PARAM=none`, by that instance's `delete`, and by `run.sh ssm delete`
  (which removes only this Purpose's `cloudflare-tunnel-*` policies, never the shared role).
  Without an instance profile, `create`/`sync` refuses before storing anything. The default
  `aws/ssm` key needs no KMS grant. A parameter you encrypted yourself with a customer-managed
  key also needs `kms:Decrypt` on that key, which isn't added for you. IAM changes can take a
  few seconds to apply, so the tunnel service retries every 10s until they do. Whoever runs
  `run.sh` needs `ssm:PutParameter`, `ssm:DescribeParameters`, `iam:GetInstanceProfile`,
  `iam:PutRolePolicy` and `iam:DeleteRolePolicy`.
- **Where traffic goes** is set on the tunnel's public hostname in the Cloudflare dashboard (a
  token-run tunnel takes its routing from there, not from the instance):
  - `egress-balancer`: `http://localhost:8080`. That's a loopback-only nginx listener just for
    the tunnel. It sets the real visitor IP from `CF-Connecting-IP` (trusted only there) and
    sends `X-Forwarded-Proto: https` to the app. Don't use `:80`: it 301s to https when
    `HTTPS_DOMAINS` is on, and the tunnel would loop.
  - `egress`: an app instance directly, e.g. `http://10.0.1.23:80`. The gateway reaches the app
    tier over the VPC like anything else. The app's SG must allow that port from the gateway's
    SG (not added automatically).
- **With a tunnel you don't need public ingress or Let's Encrypt.** Cloudflare terminates HTTPS
  at its edge, and cloudflared only makes outbound connections. You can leave `HTTPS_DOMAINS`
  unset and narrow `LB_INGRESS_CIDR`. The public IP stays, because the NAT (and cloudflared
  itself) needs it for outbound traffic.
- **Rebuild both AMIs** to get `cloudflared`. Images built before this don't have it.

## `run.sh egress-balancer <name> {create|sync|delete}`

The `egress` NAT instance with an nginx HTTP load balancer on the same box — one public
instance in the egress tier that both relays the app tier's outbound traffic *and* spreads
inbound HTTP across the app-tier instances. It's a separate AMI (`ami-scripts/egress-balancer.sh`,
env-type `egress-balancer`) and a separate manager (`manage_egress_balancer.sh`) rather than a
flag on `egress`: its own `Role=egress-balancer` tag, SG, route table and `EGRESS_BALANCER_<NAME>_*`
state keys, so a plain NAT gateway image and a balancer image are baked, launched, replaced and
torn down independently.

```bash
TIER=egress ./run.sh ami lb egress-balancer create           # bake it (Packer opens SSH itself)
./run.sh instance-ami myapp production 3 create              # the app instances to balance across
BACKEND_NAME='myapp-production-*' ./run.sh egress-balancer lb create
curl http://<public-ip>/lb-health                            # "ok backends=3"
curl http://<public-ip>/                                     # round-robined across the 3

./run.sh instance-ami myapp production 2 create              # scaled out? re-point without relaunching:
BACKEND_NAME='myapp-production-*' ./run.sh egress-balancer lb sync
./run.sh egress-balancer lb delete
./run.sh ami lb egress-balancer delete                       # the AMI is its own lifecycle
```

**The image** is `egress-gateway.sh`'s NAT setup verbatim (IP forwarding, RFC1918-only
forward chain, boot-time systemd unit) plus nginx. The backend list can't be baked in — the app
instances don't exist at build time and their IPs change on every relaunch — so nginx's config
is *rendered* on the instance by `/usr/local/sbin/egress-balancer-render.sh` from two plain files:
`/etc/egress-balancer/backends` (one `host:port` per line) and `/etc/egress-balancer/method`
(`round_robin`/`least_conn`/`ip_hash`). The render script rejects anything that isn't strictly
`host:port`, `nginx -t`s the result, rolls back to the previous config on failure, then reloads.
With no backends it serves a clean `503` rather than failing to start; `/lb-health` is answered
by nginx itself either way. The Packer build smoke-tests all three states (empty → 503, a local
throwaway backend → proxied, back to empty) before snapshotting.

`create`:
1. Resolves backends: `BACKEND_IPS` (space-separated) if set, otherwise every *running* instance
   in `$VPC_ID` tagged `Purpose=$PURPOSE` with `Name` matching `BACKEND_NAME` (wildcards ok —
   `instance-ami` names its batch `<name>-<env-type>-<i>`). Neither set is fine: it launches
   answering 503 until a `sync`.
2. Creates a dedicated SG: all traffic from the VPC CIDR (NAT relay, same as `egress`) plus
   `tcp/80` from `LB_INGRESS_CIDR` (default `0.0.0.0/0`). Adds `tcp/$BACKEND_PORT` (default 80)
   **from that SG** onto `BACKEND_SG` (default `$APP_SG`) — `manage_network.sh`'s tier SGs are
   empty, so without this the backends would drop the balancer's connections.
3. Launches from `AMI_<AMI_NAME>_EGRESS_BALANCER_ID` with a public IP and user-data that writes
   the backend/method files and runs the render script at first boot; disables source/dest check.
4. Rewires `RELAY_SUBNET_IDS` (default `$APP_SUBNET_ID`) to a new route table pointing at it, exactly
   like `egress`. `RELAY_SUBNET_IDS=none` skips this for a pure load balancer (e.g. when a plain
   `egress` gateway already relays the app tier). Running both against the same subnet means the
   last `create` wins the association.

To change the backend port (e.g. a Bun app on 3000 instead of 80), pass it on `sync` together
with the backends. `sync` also opens that port on `BACKEND_SG` for the balancer, so no
security-group edits are needed by hand:

```bash
BACKEND_NAME='myapp-bun-*' BACKEND_PORT=3000 ./run.sh egress-balancer lb sync
```

Editing `/etc/egress-balancer/backends` on the box does nothing until
`/usr/local/sbin/egress-balancer-render.sh` runs. Restarting nginx alone keeps the old config.
The next `sync` with `BACKEND_NAME`/`BACKEND_IPS` overwrites a hand edit anyway.

`sync` pushes changes to the running balancer via `aws ssm send-command`, which needs the instance
profile from `run.sh ssm create`. It only changes what you pass: the backend list if
`BACKEND_NAME`/`BACKEND_IPS` is set, the method if `LB_METHOD` is set, the HTTPS settings if
`HTTPS_DOMAINS` is set, the tunnel if `CLOUDFLARE_TUNNEL_TOKEN`/`CLOUDFLARE_TUNNEL_PARAM` is set.
With nothing set it just re-runs the certificate step.

### HTTPS on `egress-balancer`: Let's Encrypt

Set `HTTPS_DOMAINS` on `create` and that's the whole setup. The balancer terminates TLS on
:443 with a Let's Encrypt certificate it gets and renews itself (certbot, HTTP-01 webroot, so
nginx keeps serving throughout). There's no second command:

```bash
BACKEND_NAME='myapp-production-*' HTTPS_DOMAINS=app.example.com HTTPS_EMAIL=ops@example.com \
    ./run.sh egress-balancer lb create          # prints the public IP to point DNS at
# point app.example.com's A record at that IP - within ~5 minutes :443 is up on its own
curl https://app.example.com/lb-health           # "ok backends=3 https=1"
```

- **The instance waits for DNS by itself.** HTTP-01 validation needs every domain to resolve to
  the balancer. `egress-balancer-cert.timer` checks every 5 minutes whether each domain resolves
  to the instance's own public IP (from IMDS). That check is local, so it costs no Let's Encrypt
  calls. As soon as DNS matches, it requests the certificate and switches :443 on. Until then it
  serves plain HTTP. An actual failed certbot attempt backs the timer off for an hour, because
  failed validations count against Let's Encrypt's rate limit. `sync` with no variables re-runs
  it immediately if you don't want to wait. Behind a proxy like Cloudflare, DNS resolves to the
  proxy instead, so set `HTTPS_DNS_CHECK=false`. It then requests right away, so DNS must
  already reach the box.
- **The address is the instance's own public IP** (`--associate-public-ip-address`, printed by
  `create` and recorded as `EGRESS_BALANCER_<NAME>_PUBLIC_IP`). It stays the same across
  reboots, but a stop/start or a `delete` + `create` gives it a new one. Update the A record when
  that happens. The instance keeps serving its existing certificate, and for a new
  instance the timer picks up the cert once DNS points at the new IP.
- **:443 only appears once a certificate exists.** Until then nginx serves HTTP only, rather than
  failing to start on missing cert files. After that, :80 answers `/lb-health` and the ACME
  challenge path and 301-redirects everything else to https (`HTTPS_REDIRECT=false` keeps
  proxying on :80 too).
- **Renewal** runs from the same timer, at most twice a day. `certbot renew` is a no-op until 30
  days before expiry, then nginx reloads with the new cert. When nothing changed, the timer
  exits without touching nginx. Changing `HTTPS_DOMAINS` or
  `HTTPS_STAGING` on a `sync` deletes the old certificate and issues a new one.
- `HTTPS_STAGING=true` uses Let's Encrypt's staging CA. Its certs aren't browser-trusted, but its
  rate limits are far higher, so use it for trial runs.
- `create`/`sync` with HTTPS on adds tcp/443 from `LB_INGRESS_CIDR` to the balancer's SG. Port
  80 stays open, since renewals validate over it. `HTTPS_DOMAINS=none` on `sync` turns HTTPS off
  (serves HTTP only again). The tcp/443 rule stays until `delete`.

`delete` restores routing and terminates the instance the same way `egress delete` does, then
revokes every SG rule elsewhere in the account that references the balancer's SG (found by what
references it now, not by trusting `BACKEND_SG`) before deleting the SG itself — AWS refuses to
delete an SG that another rule still points at.

| variable          | default                     | used for                                         |
|-------------------|-----------------------------|--------------------------------------------------|
| `AMI_NAME`        | `<name>`                    | which `ami ... egress-balancer` build to launch  |
| `BACKEND_NAME`    | —                           | `Name` tag pattern of instances to balance across |
| `BACKEND_IPS`     | —                           | explicit private IPs, overrides `BACKEND_NAME`   |
| `BACKEND_PORT`    | `80`                        | port nginx proxies to on each backend            |
| `BACKEND_SG`      | `$APP_SG`                   | SG that gets the "from balancer" ingress rule    |
| `LB_METHOD`       | `round_robin`               | `round_robin` / `least_conn` / `ip_hash`         |
| `LB_INGRESS_CIDR` | `0.0.0.0/0`                 | who may reach the listener on `:80`              |
| `RELAY_SUBNET_IDS`| `$APP_SUBNET_ID`            | subnets NAT'd through it; `none` to skip         |
| `HTTPS_DOMAINS`   | —                           | comma-separated; enables HTTPS, `none` disables  |
| `HTTPS_EMAIL`     | —                           | Let's Encrypt account email (expiry notices)     |
| `HTTPS_REDIRECT`  | `true`                      | 301 http → https once a cert exists              |
| `HTTPS_STAGING`   | `false`                     | Let's Encrypt staging CA, for testing            |
| `HTTPS_DNS_CHECK` | `true`                      | only request once DNS points here                |
| `CLOUDFLARE_TUNNEL_TOKEN` | —                   | store in SSM + run cloudflared (see above)       |
| `CLOUDFLARE_TUNNEL_PARAM` | `/<purpose>/egress-balancer/<name>/cloudflare-tunnel-token` | existing parameter, or `none` to stop |
| `TIER`            | `egress`                    | where the balancer itself is launched            |

Not built: nginx OSS active health checks (only passive: `max_fails=3 fail_timeout=10s` plus
`proxy_next_upstream` retrying another backend on connect errors/5xx), and any HA — it's one
instance, so it's a single point of failure for both ingress and egress, the same trade the
DIY NAT instance already makes versus a managed ALB + NAT Gateway.

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
  `manage_network.sh` here is flatter: one public subnet per tier (bastion/app/db/egress), one
  shared route table, all four security groups created empty (you add rules yourself, e.g. with
  `../project-10/security-groups/scripts/add-rule.sh` if you want the same bastion → app → db
  wiring).
- `project-10/ssm-manage` ≈ `manage_ssm.sh` — project-10's version creates a dedicated
  `ssm-instance-role-$PURPOSE` IAM role from scratch; `manage_ssm.sh` instead reuses the
  existing `jenkins-role` from `project-8/aws-perm-generator` (override with `ROLE_NAME` if
  that's not what you want), so it only ever creates the instance profile.

Pick whichever fits — project-11 for a fast, single-file loop with one shared state log;
project-9/project-10 when you want each concern documented and tested on its own.
