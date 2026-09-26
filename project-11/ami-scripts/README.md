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
code onto. It can also optionally pass inbound tcp/443 through to one backend (nftables DNAT,
target read from `/etc/egress-gateway/https-forward` at runtime), without holding any cert itself.
Both `egress-gateway.sh` and `egress-balancer.sh` also install `cloudflared`, switched off. It
only starts once the manager writes an SSM parameter name to `/etc/cloudflare-tunnel/param`.
`cloudflare-tunnel.service` fetches the token from Parameter Store at each start, so no token is
ever baked into an image.

`egress-balancer.sh` is the same NAT setup plus nginx as an HTTP load balancer on `:80`, used by
`run.sh egress-balancer` (see the top-level README). Build it as its own AMI
(`TIER=egress run.sh ami <name> egress-balancer create`) — the backend list isn't baked in;
nginx's config is rendered at runtime from `/etc/egress-balancer/backends` by
`/usr/local/sbin/egress-balancer-render.sh`, which the manager feeds through user-data at launch
and SSM on `sync`. With HTTPS on, `/usr/local/sbin/egress-balancer-cert.sh` gets and renews a Let's
Encrypt certificate (certbot, installed into `/opt/certbot` via pip since AL2023 has no certbot
package) and the render script adds the :443 server once the cert exists.

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

`bun.sh` is for a Bun app that has a build step producing static client assets alongside its
server, the way [`bun-hydrate`](https://github.com/zssvaidar/bun-hydrate)'s `bun run build` emits
`dist/public/*` next to `dist/index.js`. **There is no nginx on the instance.** Bun listens on
`0.0.0.0:80` and serves both the built files in `public/` (straight off disk relative to
`WorkingDirectory`, confined to that directory so `/../etc/passwd` gets a 404) and the SSR/API
routes. TLS, load balancing and the public entry point are the egress-balancer's job
(`run.sh egress-balancer`). Its default `BACKEND_PORT=80` matches, so a second nginx here would
only add a hop. Bun is installed via the official install script (not in Amazon Linux's repos) to
`/usr/local/bin/bun`, and the systemd unit (`myapp.service`) runs it as the unprivileged `bunapp`
user with only `CAP_NET_BIND_SERVICE` to bind :80.

**Layout matches `bun-hydrate/deploy.sh`, not a static directory.** The app lives at
`/opt/app/releases/<version>/`, and `/opt/app/current` is a symlink to whichever release is
live — `myapp.service`'s `WorkingDirectory` is that symlink, never a release path directly, so a
`deploy.sh` run that re-points it and restarts the unit is a complete deploy. The baked image
ships one release, `0-baked` (placeholder `index.ts` + `public/hydrate.js` — swap both for a real
`bun run build` output at deploy time, not bake time), with `current` already pointed at it so the
smoke test below and the instance's first boot both have something to serve. The unit only needs
something that honours `PORT`/`HOST`; `PUBLIC_DIR` defaults to `public` relative to cwd, so it
still resolves correctly no matter which release `current` points at.

`bun_cloudflared.sh` is the same app reached through a **Cloudflare Tunnel** instead of the
balancer. Bun listens on `127.0.0.1:80` only, and `cloudflared` on the same instance forwards the
tunnel's public hostname to it. Nothing on the box accepts inbound traffic, so no inbound
security-group rule is needed. The app tier still needs outbound internet (the egress
gateway/balancer's NAT) for `cloudflared` to reach Cloudflare. `cloudflared` ships switched off.
`run.sh instance-ami <name> bun_cloudflared <count> create` with `CLOUDFLARE_TUNNEL_TOKEN` stores
the token in SSM and turns it on (see the top-level README). The token is never baked into the
image. Set the tunnel's public hostname service to `http://localhost:80` in the Cloudflare
dashboard. The app section is kept identical to `bun.sh` apart from `HOST`, so change both
together. The cloudflared section is the same block as in `egress-gateway.sh`.

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
