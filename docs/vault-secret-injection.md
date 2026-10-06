# Injecting Vault secrets into the container - what this project does, and the alternative

You asked specifically "I will have secrets from vault, how do I inject them into the
container, build it according to best practices." This is the answer, plus the
reasoning for the choice actually implemented in `docker/php/docker-entrypoint.sh`.

## What NOT to do (all three defeat the point of using Vault at all)

- **`ENV SECRET=...` or `ARG SECRET=...` in the Dockerfile.** Both are baked into the
  image's layer metadata permanently - anyone with `docker history` or a copy of the
  image (a registry leak, a `docker save` of a "just for debugging" image) has the
  secret forever, even after it's rotated in Vault.
- **`COPY .env .env` into the image.** Same problem: the file is now a layer. A
  multi-stage build doesn't help either - if any stage `COPY`s it, it's in that
  stage's layer, full stop.
- **Passing secrets as `docker run -e SECRET=...` / compose `environment:` from a
  value already sitting in a CI variable or a checked-in `.env`.** This doesn't touch
  Vault at deploy time at all, so rotating a secret in Vault does nothing until
  someone also updates the CI variable - the "rotate without a redeploy needing a code
  change" property from `docs/specs/14-env-secrets.md` (the sibling ecom1 project) is
  gone.

## What this project does: fetch-at-entrypoint

`docker/php/docker-entrypoint.sh` runs as the container's `ENTRYPOINT`, before
`php-fpm` starts:

1. If `VAULT_ADDR` isn't set, it skips straight to `exec php-fpm` (local dev with no
   Vault is a supported path, not an error).
2. Otherwise it authenticates - either an already-issued `VAULT_TOKEN` (what Jenkins
   hands the deploy step, itself obtained via the AppRole pattern in
   `scripts/deploy.sh`'s sibling infra, see below) or `VAULT_ROLE_ID`+`VAULT_SECRET_ID`
   passed in at `docker run`/`docker compose up` time - never baked into the image.
3. It reads one KV v2 path (`VAULT_SECRET_PATH`, e.g.
   `secret/medusa-twenty/prod/php-app`) and `export`s every key in it as an
   environment variable of the current shell.
4. It `unset`s `VAULT_TOKEN` (and any role/secret id) so the credential used to fetch
   the secrets doesn't itself linger in the environment the app inherits.
5. It `exec`s `php-fpm` - `exec`, not a plain call, so `php-fpm` becomes PID 1 and
   inherits that shell's environment directly, no subprocess boundary in between.

`php-fpm`'s pool config (`docker/php/www.conf`) sets `clear_env = no`, so those
exported vars survive into the FPM workers and reach the app via `getenv()`/`$_ENV`
(the latter needs `variables_order` to include `E` - set explicitly in
`docker/php/php.ini` because most distro defaults exclude it).

**Why this is safe here specifically:** this container's only process is the app -
nothing else shares its environment, and `clear_env=no` only matters within a single
container's PID namespace. It would NOT be safe to reuse this www.conf on a
multi-tenant host running several unrelated apps' FPM pools from one process tree.

**What this buys you:**
- Nothing secret ever touches a Dockerfile, an image layer, or the repo.
- `docker inspect` on the running container shows none of it - unlike `docker run -e`,
  these vars are set *inside* the container's own process, not passed in as launch
  parameters that Docker itself logs/stores in the container's config.
- Rotating the secret in Vault + redeploying (which is just "start a new container")
  picks up the new value with zero code change, same guarantee `14-env-secrets.md`
  requires.

**The tradeoff, on purpose stated plainly:** the `vault` CLI and `jq` are baked into
the runtime image (see the Dockerfile's `.vault-deps` layer), and the AppRole
`secret_id` (or token) is present in the container's process environment for the
handful of seconds between container start and the `unset`. Both are acceptable for a
single-tenant app container; the alternative below removes them if you want zero Vault
tooling in the app image at all.

## The alternative: Vault Agent sidecar (when to reach for it instead)

Run a second container in the same pod/task - a `hashicorp/vault` image configured as
a Vault Agent with `auto_auth` (AppRole, or better, no static credential at all via
the AWS IAM/EC2 auth method) and a `template` block that renders the KV secret to a
file on a volume shared with the app container (an `emptyDir`/`tmpfs` on Kubernetes, a
Fargate ECS task's ephemeral storage, or a `tmpfs:` compose volume locally). The app
container waits for that file (or gets started by the Agent once it's written) and
just reads it - no Vault CLI, no Vault credentials, nothing Vault-aware at all inside
the app image.

Reach for this over the entrypoint approach when:
- You're on Kubernetes and can use the Vault Agent Injector, which automates the
  sidecar + shared volume wiring via a pod annotation - the least code of any option.
- You want the app image to have zero knowledge of Vault (useful if the same image
  gets deployed somewhere without Vault, or built/scanned by a team that shouldn't
  need Vault credentials to even build it).
- You want secrets to auto-refresh on a lease renewal without restarting the app
  container (the Agent rewrites the file in place; the app has to watch/reload it,
  which this project's PHP-FPM setup does not do - a restart-to-rotate model, which is
  what the entrypoint approach gives you, is simpler and fine for this project's scope).

This repo doesn't include the sidecar wiring - it's a straightforward compose/ECS-task
addition on top of the same `docker/php` image (drop the `.vault-deps` layer and the
Vault-fetching block from `docker-entrypoint.sh`, have it read the rendered file
instead) if a future part of this series wants it.

## For ECS specifically

ECS's native `secrets` block only pulls from AWS Secrets Manager or SSM Parameter
Store, not Vault directly. Two ways to bridge that, both consistent with everything
above:
1. Keep the entrypoint-fetch approach - it works identically in an ECS task as it does
   in compose, since it's just "a process that talks to Vault over HTTPS at startup."
   Give the task's execution role (or, better, use Vault's AWS auth method with the
   *task* role, so there's no static AppRole secret to hand ECS at all) permission to
   reach Vault's address.
2. Run the Vault Agent as a second container in the task definition (the sidecar
   pattern above), sharing an ECS "volume from" mount with the app container.

## Summary

| | Entrypoint-fetch (implemented here) | Vault Agent sidecar |
|---|---|---|
| Vault tooling in app image | Yes (vault CLI + jq) | No |
| Extra container | No | Yes |
| Secret refresh without restart | No | Yes (with app-side reload support) |
| Simplest to reason about for a single app container | Yes | - |
| Best fit | Single-tenant app container, this project's scope | Kubernetes, multi-app hosts, zero-Vault-knowledge image requirement |
