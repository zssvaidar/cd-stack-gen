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
 route: 0.0.0.0/0 -> igw     route: 0.0.0.0/0 -> nat gateway
                                              (nat lives in a public subnet)
```

- **Public subnets**: bastion + app tier go here (matches `../security-groups`'s
  `*-bastion-sg` / `*-app-sg`). Instances get a public IP on launch and route straight out
  through the Internet Gateway.
- **Private subnets**: the db tier goes here (matches `*-db-sg`). No public IP, no inbound
  route from the internet at all - outbound (for patching) goes through the NAT Gateway.
- Two AZs, because a "highly available" subnet layout in a single AZ isn't one.

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
6. **One NAT Gateway per AZ for real HA.** `provision-all.sh` here creates exactly one, in the
   first public subnet, to keep a learning setup cheap and simple — that's a single point of
   failure and a deliberate shortcut, not a production pattern. Scale it to one per AZ (each
   private subnet's route table pointing at the NAT Gateway in its *own* AZ) before this backs
   anything real.
7. **NAT Gateways cost money while idle** (hourly + per-GB). Run `teardown.sh` when you're
   done experimenting instead of leaving one running.
8. **Tag everything at creation** (every script here tags `Name` + `project`, same convention
   as `../security-groups`). An unlabeled VPC full of unlabeled subnets is unauditable within
   a month.
9. **For anything past a learning setup, turn on VPC Flow Logs** (`aws ec2
   create-flow-logs --resource-type VPC ... --log-destination-type cloud-watch-logs`) so
   traffic is auditable after the fact. Not wired up here to keep this focused, but it's the
   natural next thing to add on top of this VPC.

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

Individual steps (`provision-vpc.sh`, `provision-subnets.sh`, `provision-nat-gateway.sh`,
`provision-route-tables.sh`) are also runnable on their own — each prints its own `KEY=value`
lines on stdout so they chain with `eval "$(...)"`, same pattern as `provision-all.sh` uses
internally.

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
