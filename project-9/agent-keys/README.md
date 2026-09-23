# agent-keys

`create`/`destroy` orchestrator (same pattern as `project-10`'s scripts) for per-host SSH
keypairs used by `../ec2-deploy` — generated on demand instead of one static long-lived key
shared by every deploy. Each keypair is named `<date>_<name>` (a "date_name", e.g.
`2026-09-17_web-host`) and ends up in three places:

1. **local** — `credentials/<date_name>/keys` (private) and `keys.pub` (public). Gitignored;
   never commit these.
2. **AWS** — the public half imported as an EC2 key pair of the same name, tagged
   `Purpose=$PURPOSE`, so `aws ec2 run-instances --key-name <date_name>` (what
   `../ec2-deploy/bootstrap/provision-ec2.sh` does) launches a host that trusts it.
3. **Vault** — both halves under `secret/ec2-agents/<date_name>` (plus a `purpose` field), so
   Jenkins can fetch the private key at deploy time by `date_name` instead of holding a static
   SSH credential.

## Generate a new keypair (once per host/agent)

```bash
cp wrapper/config/.env.example wrapper/config/.env   # fill in the creator credentials, once
export PURPOSE=web                                    # tags the AWS key pair + vault entry

./generate-and-store.sh create web-host
# -> 2026-09-17_web-host
```

Prints the `date_name` to use as `KEY_NAME` for `provision-ec2.sh` and as `DATE_NAME` for
`../ec2-deploy/Jenkinsfile`.

## Retire a keypair

```bash
./generate-and-store.sh destroy 2026-09-17_web-host
```

Removes the local `credentials/<date_name>/` copy, the AWS key pair, and the Vault secret
(`vault kv metadata delete` — a real purge, not KV v2's default soft-delete).

## State

Unlike the one-shot state files in `../../project-10` (one VPC, one role — overwritten each
run), `state/$PURPOSE.env` is a **log**: a single `PURPOSE` can hold many keypairs over time,
so every `create` *appends* a block instead of replacing the file (and creates it if it
doesn't exist yet — plain `>>` does both). Each entry's exports are prefixed with a
name-safe version of its `date_name` (e.g. `AGENT_2026_09_17_WEB_HOST_KEY_DIR`) so sourcing
the accumulated file doesn't let one entry clobber another. `destroy` doesn't edit this log —
it's a history of everything ever created under this `PURPOSE`, not current-state tracking.

## Vault access

Apply `jenkins-ec2-agents-policy.hcl` to whatever token/AppRole the Jenkins agent uses (the same
one `project-8/vault-cmd/policies/jenkins-vault.hcl` is attached to) — it grants read-only access
to `secret/ec2-agents/*`, nothing else. `create`/`destroy` need write access and are meant to be
run by a human/admin, not by Jenkins.

## Fetch a key manually

```bash
./fetch-key.sh 2026-09-17_web-host ./agent_key
ssh -i ./agent_key ec2-user@<host>
```

This is exactly what the "Fetch SSH key from Vault" stage in `../ec2-deploy/Jenkinsfile` does —
it writes the key into the workspace, uses it for `ssh`/`docker save | ssh`, then deletes it in
`post { always { ... } }`.
