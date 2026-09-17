# agent-keys

Per-host SSH keypairs for `../ec2-deploy`, generated on demand instead of one static long-lived
key shared by every deploy. Each keypair is named `<date>_<name>` (a "date_name", e.g.
`2026-09-17_web-host`) and ends up in three places:

1. **local** — `credentials/<date_name>/keys` (private) and `keys.pub` (public). Gitignored;
   never commit these.
2. **AWS** — the public half imported as an EC2 key pair of the same name, so `aws ec2
   run-instances --key-name <date_name>` (what `../ec2-deploy/bootstrap/provision-ec2.sh` does)
   launches a host that trusts it.
3. **Vault** — both halves under `secret/ec2-agents/<date_name>`, so Jenkins can fetch the
   private key at deploy time by `date_name` instead of holding a static SSH credential.

## Generate a new keypair (once per host/agent)

```bash
./generate-and-store.sh web-host
# -> 2026-09-17_web-host
```

Prints the `date_name` to use as `KEY_NAME` for `provision-ec2.sh` and as `DATE_NAME` for
`../ec2-deploy/Jenkinsfile`.

## Vault access

Apply `jenkins-ec2-agents-policy.hcl` to whatever token/AppRole the Jenkins agent uses (the same
one `project-8/vault-cmd/policies/jenkins-vault.hcl` is attached to) — it grants read-only access
to `secret/ec2-agents/*`, nothing else. Generating and storing new keys (`generate-and-store.sh`)
needs write access and is meant to be run by a human/admin, not by Jenkins.

## Fetch a key manually

```bash
./fetch-key.sh 2026-09-17_web-host ./agent_key
ssh -i ./agent_key ec2-user@<host>
```

This is exactly what the "Fetch SSH key from Vault" stage in `../ec2-deploy/Jenkinsfile` does —
it writes the key into the workspace, uses it for `ssh`/`docker save | ssh`, then deletes it in
`post { always { ... } }`.
