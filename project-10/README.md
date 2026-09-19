# project-10 — security groups & VPC networking

Continuation of the CD stack from
[awscli-vault-jenkins-cd-stack](https://github.com/zssvaidar/awscli-vault-jenkins-cd-stack).
Theme: AWS network access control end to end — the VPC/subnet layout underneath, and the
security groups on top of it. Creating both correctly, wiring tiers together with references
instead of IP lists, attaching/detaching security groups from running instances, and auditing
for the mistakes that actually matter in practice (open to the internet, or attached to
nothing).

## Layout

- **[`vpc-network/`](vpc-network/)** — a public/private VPC across two AZs: public subnets
  (bastion, app tier) routed through an Internet Gateway, private subnets (db tier) with no
  outbound route for now (no NAT Gateway yet — see its README for the tradeoff). Provision it
  first — everything else in this project lives inside it.
- **[`security-groups/`](security-groups/)** — least-privilege security groups on top of that
  VPC: SG-to-SG references across a bastion → app → db tier, attach/detach helpers, and an
  audit script.

```bash
cd vpc-network
export MAINTENANCE_CIDR=203.0.113.4/32   # your office/VPN IP, as a /32
./provision-all.sh myapp
set -a; source state/myapp.env; set +a

cd ../security-groups
./provision-3tier.sh myapp   # uses $VPC_ID from the sourced state
```
