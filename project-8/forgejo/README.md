# project-8/forgejo: self-hosted Forgejo and Forgejo Runner

[Forgejo](https://forgejo.org) is a lightweight, self-hosted git server with GitHub-style Actions
CI. This stack runs Forgejo plus a Forgejo Runner on one Docker host, using about 200 MB of RAM
in total (GitLab CE needed about 4 GB). The runner sits on your network, so jobs can reach Vault
(`192.168.0.26`) and AWS directly.

```
┌──────────────────────── docker host ──────────────────────────┐
│  network forgejo-net                                          │
│   ├── forgejo         :3000 (web/API)  :2222 → 22 (git ssh)   │
│   │                   SQLite in the forgejo-data volume       │
│   ├── forgejo-runner  ── /var/run/docker.sock ──┐             │
│   └── job containers ◄── started per job ───────┘             │
│        (node:20-bookworm by default; reach LAN / Vault / AWS) │
└───────────────────────────────────────────────────────────────┘
```

## Start it

```bash
cd project-8/forgejo
cp .env.example .env
#   FORGEJO_HOST            this machine's LAN IP/hostname (not localhost)
#   FORGEJO_ADMIN_PASSWORD  your admin password
#   RUNNER_SECRET           openssl rand -hex 20
docker compose up -d
docker compose logs -f     # "created admin", "runner registered", then the runner's "declared"
```

Open `http://<FORGEJO_HOST>:3000` and log in as `FORGEJO_ADMIN_USER`. The runner should appear
under **Site administration → Actions → Runners**. There's no installer page and no token to copy.
The first boot sets both up:

| Step | Where it happens |
|---|---|
| Config (SQLite, URLs, installer locked, Actions on) | `FORGEJO__*` environment variables in `docker-compose.yml` |
| Admin account | `scripts/forgejo-init.sh`: `forgejo admin user create` (skipped if it exists) |
| Runner registration, Forgejo side | `scripts/forgejo-init.sh`: `forgejo-cli actions register --secret $RUNNER_SECRET` |
| Runner registration, runner side | `scripts/runner-init.sh`: `forgejo-runner create-runner-file --secret $RUNNER_SECRET` |
| Runner config (labels, network) | `scripts/runner-init.sh`: `config.yml`, rebuilt from `.env` on every start |

Both sides use the same `RUNNER_SECRET`, so no token has to be copied from the UI. That also
means the secret is effectively the runner's password, so keep `.env` private.

## Runner labels (`runs-on`)
`RUNNER_LABELS` maps a workflow's `runs-on:` value to the image the job runs in:

```
docker:docker://node:20-bookworm,bun-hydrate-deploy:docker://node:20-bookworm
```

With that, a job using `runs-on: bun-hydrate-deploy` (or `docker`) runs in `node:20-bookworm`.
The image needs `node` because JavaScript actions like `actions/checkout` run inside the job
container. Change the labels in `.env`, then run `docker compose up -d runner`.

## Getting code in
- **Push:** create a repo in the UI, then `git remote add forgejo http://<FORGEJO_HOST>:3000/<user>/<repo>.git`
  (or `ssh://git@<FORGEJO_HOST>:2222/<user>/<repo>.git`).
- **Mirror from GitHub:** go to **+ → New migration → GitHub**, paste the repo URL, and tick
  "This repository will be a mirror". Forgejo then pulls from GitHub on a schedule. Note that
  Actions don't run on pull mirrors, so push to Forgejo directly if you want pipelines to run.

Workflows go in `.forgejo/workflows/*.yml` (GitHub Actions syntax). Forgejo also reads
`.github/workflows/`. Repo secrets are set under **Repo → Settings → Actions → Secrets**.

## How it's wired
- **Forgejo keeps the image's own startup.** `command:` replaces only the image's CMD, and
  `forgejo-init.sh` starts Forgejo the same way (`s6-svscan`). It waits for `/api/healthz`,
  runs the idempotent setup, then stays in the foreground. `docker stop` still shuts it down
  cleanly.
- **The runner runs as root** so it can use the host's `docker.sock` and start job containers
  next to itself. The jobs themselves *don't* get the socket (`docker_host: "-"`), so a workflow
  can't take over the host's Docker. The runner container can, though, so only register this
  runner for code you trust.
- **Job containers join `forgejo-net`.** `actions/checkout` clones from `ROOT_URL`
  (`http://<FORGEJO_HOST>:3000`), which job containers reach through the host. That's why
  `FORGEJO_HOST` can't be `localhost`.

## Day-to-day
```bash
docker compose ps
docker compose logs -f runner
docker exec -u git forgejo forgejo admin user list
docker compose down            # stop (data stays in volumes)
docker compose down -v         # stop AND delete all repos, users and the runner registration
```

**Upgrading:** bump `FORGEJO_VERSION` / `RUNNER_VERSION`, then `docker compose pull` and
`docker compose up -d`. Stay on the LTS line (15) unless you want the newer features, and read
the release notes before jumping a major version.

**Backups:** everything (repos, SQLite DB, config) is in the `forgejo-data` volume:
`docker exec -u git forgejo forgejo dump -f /data/forgejo-dump.zip`.
