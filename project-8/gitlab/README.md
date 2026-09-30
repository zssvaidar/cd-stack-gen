# project-8/gitlab: self-hosted GitLab CE and GitLab Runner

This is a single Docker Compose stack that runs GitLab CE plus a GitLab Runner (the agent that
executes pipeline jobs) on one host. It's meant for running pipelines like `bun-hydrate`'s
`.gitlab/workflows/deploy.yml` on a machine inside your network, where the jobs can reach Vault
(`192.168.0.26`) directly.

```
┌──────────────────────── docker host ─────────────────────────┐
│  network gitlab-net                                          │
│   ├── gitlab         :8929 (web/API)  :2224 → 22 (git ssh)   │
│   ├── gitlab-runner  ── /var/run/docker.sock ──┐             │
│   └── job containers ◄── started per job ──────┘             │
│        (clone from http://gitlab:8929, reach LAN/Vault/AWS)  │
└──────────────────────────────────────────────────────────────┘
```

Host requirements: 4 GB RAM minimum (8 GB is more comfortable), 2+ CPUs, and Docker with the
Compose plugin.

## 1. Start GitLab

```bash
cd project-8/gitlab
cp .env.example .env          # set GITLAB_HOST to this machine's LAN IP/hostname
docker compose up -d
docker compose ps             # wait for gitlab to show (healthy), 3-5 min on first boot
```

Open `http://<GITLAB_HOST>:8929` and log in as `root`. If you left `GITLAB_ROOT_PASSWORD` empty,
read the generated password (it's deleted automatically 24 h after the first reconfigure):

```bash
docker exec gitlab grep 'Password:' /etc/gitlab/initial_root_password
```

## 2. Register the runner

1. In GitLab, go to **Admin → CI/CD → Runners → New instance runner**.
   Add a **tag**, for example `bun-hydrate-deploy` (the tag `bun-hydrate`'s pipeline asks for).
   Tick "Run untagged jobs" if you also want it to pick up jobs with no tag.
2. Copy the `glrt-...` token into `.env` as `RUNNER_TOKEN`.
3. Run the registration:
   ```bash
   docker compose --profile register run --rm runner-register
   ```
The runner in **Admin → CI/CD → Runners** should now show as online. Registration is stored in
the `runner-config` volume, so it survives restarts. Running the command again does nothing
once a runner is registered.

Tags and "run untagged" are set in the UI, not with `register` flags. With the current `glrt-`
token flow, GitLab owns those settings.

## 3. Use it
Create a project and push code with either of:
```bash
git remote add gitlab http://<GITLAB_HOST>:8929/<group>/<project>.git
git remote add gitlab ssh://git@<GITLAB_HOST>:2224/<group>/<project>.git
```
For `bun-hydrate`, also set **Settings → CI/CD → General pipelines → CI/CD configuration file** to
`.gitlab/workflows/deploy.yml`, and add the Vault variables described in its
`.gitlab/workflows/README.md`.

## How it's wired
- **`external_url` sets the published port.** Its port (8929) is also the port GitLab's nginx
  listens on inside the container, so it's published 1:1. That keeps clone URLs and redirects
  correct without a separate proxy.
- **The runner uses the docker executor through the host's Docker socket.** Each job runs as a
  sibling container on this host. Mounting `docker.sock` gives the runner full control of the
  host's Docker, so only run trusted projects on it.
- **Job containers join `gitlab-net`** and clone from `http://gitlab:8929` (the compose service
  name). This works even when `GITLAB_HOST=localhost`, which inside a container would point back
  at the container itself.
- **Jobs can reach your LAN.** Anything the host can reach, jobs can reach too (Vault at
  `192.168.0.26`, AWS APIs), through Docker's normal outbound NAT.
- **Trimmed for a small box.** The built-in Prometheus monitoring and the container registry are
  turned off, and puma/sidekiq are sized down.

## Day-to-day
```bash
docker compose logs -f gitlab                 # boot / reconfigure logs
docker exec -it gitlab gitlab-ctl status      # internal services
docker exec -it gitlab-runner gitlab-runner list
docker compose down                           # stop (data stays in volumes)
docker compose down -v                        # stop AND delete all GitLab data + runner registration
```

**Upgrading:** pin `GITLAB_VERSION` (for example `17.11.1-ce.0`) and step through GitLab's
required upgrade stops. Don't jump several majors at once. Keep `RUNNER_VERSION` on the same
`major.minor` as GitLab.

**Backups:**
`docker exec gitlab gitlab-backup create` writes to `/var/opt/gitlab/backups`, which is in the
`gitlab-data` volume. It doesn't include `/etc/gitlab/gitlab-secrets.json` (in the
`gitlab-config` volume), and a restore needs that file, so back it up separately.

## "GitLab agent" vs runner
This stack uses **GitLab Runner**, which runs CI/CD jobs, including the SSM deploys.
The **GitLab Agent for Kubernetes** (`agentk`) is a different thing: it connects a Kubernetes
cluster to GitLab for GitOps. It isn't needed for EC2/SSM deploys, so it isn't included here.
