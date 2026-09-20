# ssm-manage

`create`/`destroy` orchestrator (same single-file, tag-driven pattern as the rest of
`project-10`) that sets an EC2 instance up to be managed through AWS Systems Manager Session
Manager instead of SSH: an IAM role + instance profile, and the three VPC interface endpoints
that let an instance reach SSM without a route to the internet at all.

## Why this instead of (or alongside) `../security-groups`'s bastion

- **No inbound rule needed, on anything.** Session Manager connections are initiated
  outbound, from the SSM Agent on the instance to the SSM service - not inbound to the
  instance. `*-bastion-sg`'s `22 from MAINTENANCE_CIDR` rule in `../security-groups` still has
  its place (plain `ssh`, scp, tools that expect a real shell over a socket), but nothing
  about managing an instance *requires* an open port anymore.
- **IAM controls access, not a shared key.** Who can `aws ssm start-session` is an IAM policy
  decision, tied to a real identity - not "whoever has a copy of the private key" the way
  `../../project-9/agent-keys` keys are.
- **Works from a fully isolated private subnet.** `../vpc-network`'s private subnets have no
  NAT Gateway and no route to the internet (see its README). SSH from outside is impossible
  there by design. The VPC interface endpoints this script creates are how you'd still reach
  an instance in that subnet - traffic to Session Manager never leaves the VPC.
- **Every session is logged.** Unlike a bare SSH connection, Session Manager sessions are
  recorded in CloudTrail by default (and optionally streamed in full to CloudWatch Logs / S3 -
  not configured here, but the natural next step).

## What it creates

| resource                                   | purpose                                              |
|---------------------------------------------|--------------------------------------------------------|
| IAM role `ssm-instance-role-$PURPOSE`       | trust policy for `ec2.amazonaws.com`, `AmazonSSMManagedInstanceCore` attached |
| instance profile `ssm-instance-profile-$PURPOSE` | wraps the role - this is what actually attaches to an instance |
| security group `ssm-endpoints-sg-$PURPOSE`  | allows 443 from the VPC's own CIDR into the endpoints  |
| 3 interface VPC endpoints                   | `ssm`, `ssmmessages`, `ec2messages` - the minimum set for Session Manager to work, private DNS enabled |

## Usage

Needs a VPC + subnet(s) already tagged `Purpose=<value>` — from your own VPC/subnet
provisioning, tagged the same way this script discovers everything else.

```bash
cp wrapper/config/.env.example wrapper/config/.env   # fill in the creator credentials, once
export PURPOSE=testing                                # must match the VPC/subnets' Purpose tag

./ssm-manage.sh create
./ssm-manage.sh destroy
```

State (VPC ID, role/profile names, security group ID, endpoint IDs) is written to
`state/$PURPOSE.env` (gitignored) purely for your own reference — `destroy` doesn't read it
back; like the rest of this pattern, it rediscovers everything by the `Purpose` tag, so it's
safe to run even if the state file was lost.

Once an instance has the instance profile and the SSM Agent (preinstalled on current Amazon
Linux / Ubuntu AMIs), connect with:

```bash
aws ssm start-session --target i-0123456789abcdef0
```

## Gotchas

- **Instance profile propagation.** IAM is eventually consistent; `create` sleeps 10s after
  creating the instance profile before printing the summary, since launching an instance
  against a profile that isn't visible yet fails intermittently.
- **IAM has no `--region`.** Roles and instance profiles are global; only the EC2/VPC calls in
  this script take `--region`.
- **`destroy` is idempotent by design**, same as `../vpc-network/teardown.sh`'s and
  `../security-groups`'s scripts: it looks resources up by the `Purpose` tag (or, for the IAM
  role/profile, by their deterministic name) rather than assuming a fixed set exists, so
  re-running it after a partial failure is safe.
