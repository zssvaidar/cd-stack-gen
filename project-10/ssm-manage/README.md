# ssm-manage

`create`/`destroy` orchestrator (same single-file, tag-driven pattern as the rest of
`project-10`) that sets an EC2 instance up to be managed through AWS Systems Manager Session
Manager instead of SSH: an IAM role + instance profile with `AmazonSSMManagedInstanceCore`
attached. That's the whole thing — the SSM Agent on the instance calls out to the public SSM
API over internet access the instance already has, so there's nothing VPC-shaped to create.

## Why this instead of (or alongside) `../security-groups`'s bastion

- **No inbound rule needed, on anything.** Session Manager connections are initiated
  outbound, from the SSM Agent on the instance to the SSM service - not inbound to the
  instance. `*-bastion-sg`'s `22 from MAINTENANCE_CIDR` rule in `../security-groups` still has
  its place (plain `ssh`, scp, tools that expect a real shell over a socket), but nothing
  about managing an instance *requires* an open port anymore.
- **IAM controls access, not a shared key.** Who can `aws ssm start-session` is an IAM policy
  decision, tied to a real identity - not "whoever has a copy of the private key" the way
  `../../project-9/agent-keys` keys are.
- **Every session is logged.** Unlike a bare SSH connection, Session Manager sessions are
  recorded in CloudTrail by default (and optionally streamed in full to CloudWatch Logs / S3 -
  not configured here, but the natural next step).

## What it creates

| resource                                          | purpose                                          |
|-----------------------------------------------------|-----------------------------------------------------|
| IAM role `ssm-instance-role-$PURPOSE`               | trust policy for `ec2.amazonaws.com`, `AmazonSSMManagedInstanceCore` attached |
| instance profile `ssm-instance-profile-$PURPOSE`    | wraps the role - this is what actually attaches to an instance |

## Usage

```bash
cp wrapper/config/.env.example wrapper/config/.env   # fill in the creator credentials, once
export PURPOSE=testing

./ssm-manage.sh create
./ssm-manage.sh destroy
```

State (role/profile names) is written to `state/$PURPOSE.env` (gitignored) purely for your own
reference — `destroy` doesn't read it back; it rediscovers the role/profile by their
deterministic `$PURPOSE`-based name, so it's safe to run even if the state file was lost.

Once an instance has the instance profile and the SSM Agent (preinstalled on current Amazon
Linux / Ubuntu AMIs), connect with:

```bash
aws ssm start-session --target i-0123456789abcdef0
```

## If an instance ever doesn't have internet access

This assumes the instance can reach `ssm.<region>.amazonaws.com` etc. directly - true for
anything in a public subnet, or a private subnet with a NAT Gateway. If that stops being true
(e.g. a private subnet in `../vpc-network`, which has no NAT Gateway by design), the instance
needs three VPC interface endpoints instead - `ssm`, `ssmmessages`, `ec2messages` - plus a
security group allowing 443 into them from the VPC's CIDR. Not built here since it's not
needed for the current setup; ask for it if that changes.

## Gotchas

- **Instance profile propagation.** IAM is eventually consistent - if launching or associating
  an instance against a just-created profile fails right away, wait a few seconds and retry.
- **IAM has no `--region`.** Roles and instance profiles are global.
- **`destroy` is idempotent by design**, same as the rest of `project-10`: it checks whether
  the role/profile exist before touching them, so re-running it after a partial failure is
  safe.
