# ami-scripts

`run.sh ami <name> <env-type> create` runs `ami-scripts/<env-type>.sh` as user-data on the
builder instance before snapshotting it — that's the one file that actually defines what ends
up baked into the image. `example.sh` is a minimal, working starting point (installs
`cloudflared` — the same install this stack already uses in
[`bun-hydrate`](https://github.com/zssvaidar/bun-hydrate)'s `cloud-init-cloudflared.sh`).
Copy it to `<env-type>.sh` and replace the body with whatever that environment actually needs.

A script here should be **idempotent and self-contained**: it runs once, unattended, with no
one watching — if it fails partway, `run.sh ami` reports the failure and leaves the builder
instance running for you to SSM/SSH in and inspect, rather than silently shipping a half-baked
image.

Override the convention entirely with `PROVISION_SCRIPT=/some/other/path.sh run.sh ami ...`
if you don't want to name files after the env-type.
