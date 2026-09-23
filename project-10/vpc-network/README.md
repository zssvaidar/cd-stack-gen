# vpc-network

The layer underneath `../security-groups`: you can't create a security group without a VPC,
and a security group's SSH/app/db rules only mean what you think they mean if the subnet
they're in actually routes the way you assume. This provisions a standard public/private VPC
and hands off VPC + subnet IDs to the rest of this stack.

## Layout

```
        10.0.0.0/16 (vpc)
        internet gateway
             |
   -------------------------
   |                       |
 public subnets          private subnets
 (map-public-ip-on-launch)  (no public IP)
 10.0.0.0/24, 10.0.1.0/24   10.0.10.0/24, 10.0.11.0/24
 az-a         az-c          az-a          az-c
   |                             |
 route: 0.0.0.0/0 -> igw     (no default route - isolated)
```

- **Public subnets**: bastion + app tier go here (matches `../security-groups`'s
  `*-bastion-sg` / `*-app-sg`). Instances get a public IP on launch and route straight out
  through the Internet Gateway.
- **Private subnets**: the db tier goes here (matches `*-db-sg`). No public IP, and — for
  now — no outbound internet route either: no NAT Gateway in this project, so the private
  route table has no `0.0.0.0/0` route at all. That's a deliberate cost/complexity tradeoff
  for a learning setup, not a security best practice being skipped; see the note below.
- Two AZs, because a "highly available" subnet layout in a single AZ isn't one.

**No NAT means fully isolated, not just "no inbound."** `../security-groups/provision-3tier.sh`
gives the db tier an egress rule for HTTPS (OS/package patching) — with no NAT Gateway, that
rule has nowhere to route to, so patching-over-the-internet from the db tier won't work until
one exists. Add a NAT Gateway (`aws ec2 create-nat-gateway` in a public subnet, plus a
`0.0.0.0/0` route on `$PRIVATE_RT_ID` pointing at it) when that's actually needed.

## Best practices

1. **Never build real workloads in the default VPC.** Its subnets are all public by default
   and its default security group allows all traffic between anything wearing it — exactly
   the two things `../security-groups` exists to avoid.
2. **Size the VPC CIDR generously up front.** `/16` gives 65k addresses across every subnet
   you'll ever carve out of it. You can add a secondary CIDR block later, but you can't shrink
   one, and re-IPing a live VPC is painful — plan the range once.
3. **Split public/private by actual exposure need, not by tier name.** Public = must be
   reachable from the internet (a bastion, a load balancer). Everything else — app servers
   behind that load balancer, databases, caches — belongs in a private subnet even if it "only"
   talks to other AWS resources.
4. **Spread every tier across at least two AZs.** A single-AZ subnet is a single point of
   failure no matter how carefully the security groups are written.
5. **The route table is what makes a subnet public or private — not `map-public-ip-on-launch`.**
   That flag only decides whether a new instance *gets* a public IP; without a `0.0.0.0/0 ->
   igw` route in its subnet's route table, that IP goes nowhere. Both pieces have to agree
   (`provision-subnets.sh` sets the flag, `provision-route-tables.sh` sets the route).
6. **Tag everything at creation** (every script here tags `Name` + `project`, same convention
   as `../security-groups`). An unlabeled VPC full of unlabeled subnets is unauditable within
   a month.
7. **For anything past a learning setup, turn on VPC Flow Logs** (`aws ec2
   create-flow-logs --resource-type VPC ... --log-destination-type cloud-watch-logs`) so
   traffic is auditable after the fact. Not wired up here to keep this focused, but it's the
   natural next thing to add on top of this VPC.
8. **When you do add a NAT Gateway later, plan for one per AZ.** A single NAT Gateway is a
   single point of failure for every private subnet's outbound access, and it bills hourly
   plus per-GB even sitting idle — don't provision one before something actually needs
   outbound access from a private subnet.

## Usage

```bash
export VPC_ID=  # unset - provision-all.sh creates it
./provision-all.sh myapp             # cidr defaults to 10.0.0.0/16
./provision-all.sh myapp 10.1.0.0/16 # or pick your own

./show-network.sh myapp              # read-only summary
```

`provision-all.sh` writes every resource ID to `state/myapp.env` (gitignored — it's live,
account-specific infrastructure state, not something to commit). Source it to get `$VPC_ID`,
`$PUBLIC_SUBNET_IDS`, `$PRIVATE_SUBNET_IDS`, etc. back into your shell:

```bash
set -a; source state/myapp.env; set +a
```

Individual steps (`provision-vpc.sh`, `provision-subnets.sh`, `provision-route-tables.sh`)
are also runnable on their own — each prints its own `KEY=value` lines on stdout so they
chain with `eval "$(...)"`, same pattern as `provision-all.sh` uses internally.

## Wiring into the rest of this stack

```bash
set -a; source state/myapp.env; set +a
read -ra PUBLIC <<< "$PUBLIC_SUBNET_IDS"

# security groups live in this VPC
../security-groups/provision-3tier.sh myapp   # needs VPC_ID + MAINTENANCE_CIDR exported

# project-9/ec2-deploy needs a subnet + security group to launch into
export SUBNET_ID="${PUBLIC[0]}"
export SECURITY_GROUP_ID=<app-sg from provision-3tier.sh output>
../../project-9/ec2-deploy/bootstrap/provision-ec2.sh
```

## Teardown

```bash
./teardown.sh myapp
```

Delete anything still living in the VPC first (instances, non-default security groups) — the
subnet/VPC deletion steps fail loudly with AWS's own error if something's still attached,
rather than silently leaving orphaned resources.
