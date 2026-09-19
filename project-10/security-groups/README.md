# security-groups

Working with AWS EC2 security groups the way they're meant to be used: least privilege, tiers
that reference each other instead of hardcoded IPs, and rules that get attached/detached
deliberately instead of by editing a giant shared group everyone's afraid to touch.

## The basics that shape every decision below

- Security groups are **stateful**: allow inbound TCP 22 and the response traffic is allowed
  back out automatically, no matching egress rule needed.
- They're **allow-only** — there is no explicit "deny" rule. Everything not allowed is
  dropped. Inbound defaults to nothing allowed; outbound defaults to everything allowed
  (AWS adds a `0.0.0.0/0` all-traffic egress rule automatically on creation).
- An ENI can have **up to 5 security groups** attached (default quota), and the *union* of all
  their rules applies. A security group can have **up to 60 inbound + 60 outbound rules**
  (default quota, raisable). Split by concern instead of cramming one group full.
- A security group is **scoped to one VPC** — you can't attach a security group from VPC A to
  an instance in VPC B.
- Rule changes take effect **immediately for new connections**, but AWS doesn't tear down
  already-established connections just because a rule was revoked. Tightening a rule isn't
  instant enforcement against existing sessions.

## Best practices

1. **Least privilege, always.** Open the exact port and protocol needed, nothing wider. Don't
   open a range "just in case."
2. **Reference security groups instead of CIDRs for anything inside the VPC.** `--peer-sg`
   instead of `--cidr` (see `scripts/add-rule.sh`). It's self-documenting ("traffic from the
   app tier", not a bare IP) and never goes stale as instances are replaced — a CIDR-based rule
   silently rots the moment the IP behind it changes.
3. **One security group per role/tier, not one shared group for everything.** Bastion, app, and
   db each get their own group (see `provision-3tier.sh`). This is what makes rule #2 possible
   and makes an audit legible — a shared "allow-everything-between-our-own-stuff" group is
   where 0.0.0.0/0 accidentally creeps in.
4. **Never expose management ports (22, 3389, etc.) to `0.0.0.0/0`.** Restrict to a bastion
   security group, or to a known maintenance CIDR / a managed prefix list if it has to be an IP.
5. **Narrow egress for tiers that don't need open outbound**, especially anything holding data
   (a database, a secrets store). The default allow-all egress is a blast-radius problem if that
   instance is ever compromised — `scripts/revoke-default-egress.sh` + a couple of explicit
   `egress` rules covers it.
6. **Tag every group at creation** (`scripts/create-sg.sh` tags `Name` and `project` by
   default, plus whatever else you pass) and give it a real description. An untagged,
   undescribed `sg-08f...` six months old is unauditable.
7. **Revoke by rule ID, not by re-specifying the tuple.** `authorize`/`revoke` with the same
   protocol+port+source tuple is the textbook way to add/remove a rule, but revoke silently
   no-ops if the tuple doesn't match exactly — including whether the original had a
   description. `scripts/revoke-rule.sh` takes a `--rule-id` from `scripts/list-rules.sh`
   instead, which can't have that mismatch.
8. **`modify-instance-attribute --groups` replaces the whole list — it doesn't add to it.**
   Passing just the one new group ID silently strips every other group already on the
   instance. `scripts/attach-sg.sh` / `scripts/detach-sg.sh` read the current list first and
   merge/remove, so you can't accidentally drop a group this way.
9. **Audit regularly, not just at review time.** `scripts/audit-open-sgs.sh` is read-only and
   exits nonzero if it finds anything open to the internet on a sensitive port/protocol, or a
   group attached to nothing — wire it into CI or a cron job instead of relying on someone
   remembering to check the console.
10. **Keep a paper trail.** `scripts/dump-sg.sh` snapshots a group's full rule set to JSON so
    you can diff two points in time instead of reconstructing "what changed" from CloudTrail.

## Reference architecture: bastion → app → db

`provision-3tier.sh` builds this from scratch:

| security group | inbound                                              | outbound                          |
|----------------|-------------------------------------------------------|------------------------------------|
| `*-bastion-sg` | 22 from `MAINTENANCE_CIDR`                             | default (all)                      |
| `*-app-sg`     | 22 from `*-bastion-sg`; `APP_PORT` from `0.0.0.0/0`    | default (all)                      |
| `*-db-sg`      | `DB_PORT` from `*-app-sg` only                         | 443 only (default egress revoked)  |

Nothing here uses a bare IP for inter-tier traffic — the app tier's inbound rule names the
bastion's security group, and the db tier's inbound rule names the app tier's. Swap the app
tier's public `0.0.0.0/0` rule for `--peer-sg <alb-sg>` once there's a load balancer in front
of it, and the same pattern holds all the way up.

```bash
export VPC_ID=vpc-xxxxxxxx
export MAINTENANCE_CIDR=203.0.113.4/32   # your office/VPN IP, as a /32
./provision-3tier.sh myapp
```

## Attaching a security group to an instance

```bash
scripts/attach-sg.sh i-0123456789abcdef0 sg-0123456789abcdef0
```

This is the part that trips people up: `aws ec2 modify-instance-attribute --instance-id X
--groups sg-new` doesn't *add* `sg-new` — it **sets the instance's security groups to exactly
`[sg-new]`**, dropping whatever else was attached. `attach-sg.sh` reads the current list via
`describe-instances` first and passes the union. `detach-sg.sh` does the same in reverse, and
refuses to leave the instance with zero groups (which AWS wouldn't allow anyway).

Both scripts act on the instance's **primary** network interface. An instance with multiple
ENIs needs the specific interface targeted instead:

```bash
aws ec2 describe-network-interfaces --filters "Name=attachment.instance-id,Values=i-xxxx" \
    --query 'NetworkInterfaces[].NetworkInterfaceId'
aws ec2 modify-network-interface-attribute --network-interface-id eni-xxxx --groups sg-a sg-b
```

To wire this into `../ec2-deploy`: run `provision-3tier.sh` (or `create-sg.sh` +
`add-rule.sh` for a one-off group) before `../ec2-deploy/bootstrap/provision-ec2.sh`, then
either pass `--security-group-ids` at launch time or call `attach-sg.sh` against the instance
ID that script prints.

## Script reference

| script                        | what it does                                                        |
|--------------------------------|----------------------------------------------------------------------|
| `scripts/create-sg.sh`         | creates a tagged security group, prints its ID                       |
| `scripts/add-rule.sh`          | adds one ingress/egress rule (`--cidr` or `--peer-sg`)                |
| `scripts/revoke-rule.sh`       | removes a rule by ID (from `list-rules.sh`)                          |
| `scripts/revoke-default-egress.sh` | removes the auto-created allow-all outbound rule                |
| `scripts/list-rules.sh`        | lists every rule on a group, with IDs, as a table                    |
| `scripts/attach-sg.sh`         | attaches group(s) to a running instance without dropping the rest    |
| `scripts/detach-sg.sh`         | removes group(s) from a running instance, keeps the rest              |
| `scripts/dump-sg.sh`           | snapshots a group's full definition to timestamped JSON              |
| `scripts/audit-open-sgs.sh`    | read-only scan for internet-exposed and unused groups; CI-friendly   |
| `provision-3tier.sh`           | builds the bastion → app → db reference architecture above           |

All scripts default `AWS_REGION` to `ap-northeast-1`, same as the rest of this stack — override
by exporting it.
