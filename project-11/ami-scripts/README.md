# ami-scripts

`run.sh ami <name> <env-type> create` hands `ami-scripts/<env-type>.sh` to Packer as a `shell`
provisioner, run against the builder instance before it's snapshotted — that's the one file
that actually defines what ends up baked into the image. `example.sh` is a minimal, working
starting point (installs `cloudflared` — the same install this stack already uses in
[`bun-hydrate`](https://github.com/zssvaidar/bun-hydrate)'s `cloud-init-cloudflared.sh`). Copy
it to `<env-type>.sh` and replace the body with whatever that environment actually needs.

`egress-gateway.sh` is another real one in here, used by `run.sh egress` (see the top-level
README) — it bakes IP forwarding and NAT into the image instead of installing an app, making
the resulting instance usable as a self-managed NAT instance rather than something you deploy
code onto.

`egress-balancer.sh` is the same NAT setup plus nginx as an HTTP load balancer on `:80`, used by
`run.sh egress-balancer` (see the top-level README). Build it as its own AMI
(`TIER=egress run.sh ami <name> egress-balancer create`) — the backend list isn't baked in;
nginx's config is rendered at runtime from `/etc/egress-balancer/backends` by
`/usr/local/sbin/egress-balancer-render.sh`, which the manager feeds through user-data at launch
and SSM on `sync`.

`nodejs.sh` is a real, runnable app stack: nginx as the front end on `:80`, a Node.js app behind
it on `127.0.0.1:3000` run as a dedicated `nodeapp` system user via a systemd unit, and a
build-time smoke test (`curl` through nginx, not just "the config parsed") before the instance
gets snapshotted. **There's no separate mechanism for "choosing a set of technologies" to
install** — the script body *is* the choice. `nodejs.sh` happens to install nginx + Node.js;
copy it to `<env-type>.sh` and swap the `dnf install` line and the app section for whatever
stack you actually want (Python + gunicorn, a Go binary, …) — same shape, different packages and
systemd unit(s). The app itself is the same dependency-free app as
`project-9/containers/node-app`, just run directly on the instance instead of in a container;
replace the `cat > /opt/app/server.js` block with your own deploy step (copy build output in,
fetch from S3/git, …) once you have a real one.

`bun.sh` is the same shape again, for a Bun app that has a build step producing static client
assets alongside its server — the way [`bun-hydrate`](https://github.com/zssvaidar/bun-hydrate)'s
`bun run build` emits `dist/public/*` next to `dist/index.js`. Bun itself is installed via the
official install script (not in Amazon Linux's repos) and symlinked onto `PATH`. The nginx config
here does more than `nodejs.sh`'s straight reverse proxy: `try_files` serves a request directly
off `/opt/app/public` when it matches a built asset, and only falls through to `proxy_pass` at
`127.0.0.1:3000` for everything the static server can't answer (SSR pages, `/health`, any other
app route) — static assets never round-trip through the Bun process. Swap the placeholder
`/opt/app/index.ts` and `/opt/app/public/hydrate.js` for a real `bun run build` output copied in
from CI/S3/git; the systemd unit and nginx `location` blocks stay as-is.

**Runs as root.** Packer connects over SSH as `ec2-user`, not root, but `packer/ami.pkr.hcl`'s
provisioner block wraps the script in `sudo` (`execute_command`) — the same effective privilege
the old user-data/cloud-init approach had, just made explicit instead of implicit. Write scripts
as if they run as root (no need to prefix individual commands with `sudo` yourself); don't rely
on `$HOME`/`~` resolving to `ec2-user`'s home if that matters for anything you install.

A script here should be **idempotent and self-contained**: it runs once, unattended, with no
one watching. If it fails partway, Packer's default behavior is to clean up — terminate the
builder instance — before `manage_ami.sh` even sees the failure, so there's nothing left to
inspect. To debug a failing script, re-run with `packer build -on-error=ask ...` (drops you to a
prompt instead of tearing the builder down) or `-debug` (steps through one action at a time) —
`manage_ami.sh` always shells out to plain `packer build "${packer_vars[@]}" "$PACKER_DIR"`, so
pass these by invoking `packer` directly against `packer/` with the same `-var`s if you need
them, rather than editing `manage_ami.sh` for a one-off debug session.

**Retry any `dnf`/`yum`/`rpm` call.** `packer/ami.pkr.hcl` runs `cloud-init status --wait` before
this script, so cloud-init's own boot-time package work is done by the time it starts — but that
only covers cloud-init. Amazon Linux also runs other package-related jobs independent of
cloud-init's lifecycle (`dnf-makecache.timer`, SSM inventory collection, …), any of which can
briefly hold the exclusive rpm transaction lock at any point after boot, including *while* this
script is mid-install. `dnf`/`yum` don't wait for that lock to free — they fail immediately
(`can't create transaction lock ... Resource temporarily unavailable`). `example.sh`'s
`retry_pkg()` wraps a command and retries it a few times with a short sleep on failure; wrap any
`dnf install`/`yum install`/similar call in your own script with it rather than assuming the box
is quiet.

Override the convention entirely with `PROVISION_SCRIPT=/some/other/path.sh run.sh ami ...`
if you don't want to name files after the env-type.
