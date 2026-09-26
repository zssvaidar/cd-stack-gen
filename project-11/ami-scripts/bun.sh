#!/bin/bash
# Copy this to ami-scripts/<env-type>.sh (or point PROVISION_SCRIPT at your own copy) - a Bun app
# with a build step that produces static client assets (dist/public/*) alongside the server, the
# way https://github.com/zssvaidar/bun-hydrate does. No nginx on the instance: Bun itself listens
# on 0.0.0.0:80 and serves both the built static files and the SSR/API routes. TLS, load
# balancing and the public entry point belong to the egress-balancer in front of it
# (`run.sh egress-balancer`, default BACKEND_PORT=80 matches), so a second nginx here would only
# add a hop. ami-scripts/bun_cloudflared.sh is the same app reached through a Cloudflare Tunnel
# instead. Swap the placeholder app for a real `bun run build` output; the unit stays as-is.
# Targets Amazon Linux 2023 (dnf), falls back to Amazon Linux 2 (yum).
set -e

# Amazon Linux's own background jobs (dnf-makecache.timer, SSM inventory collection) can grab
# the rpm transaction lock at any point after boot, independent of cloud-init - dnf/yum don't
# wait for that lock, they fail immediately ("can't create transaction lock ... Resource
# temporarily unavailable"). Retry any command that touches the package/rpm db instead of
# assuming the box is quiet - see ami-scripts/README.md for why `cloud-init status --wait`
# alone (run before this script) doesn't fully cover it.
retry_pkg() {
    local n=0 max=6
    until "$@"; do
        n=$((n + 1))
        [[ "$n" -ge "$max" ]] && return 1
        echo "package manager busy (rpm lock held) - retry $n/$max in 5s" >&2
        sleep 5
    done
}

# unzip: the Bun install script needs it
if command -v dnf >/dev/null 2>&1; then
    retry_pkg dnf install -y unzip
else
    retry_pkg yum install -y unzip
fi

# Bun isn't in Amazon Linux's repos - install via the official script rather than adding another
# external package repo. By default it installs to $HOME/.bun, which depends on whether
# `sudo <script>` (Packer's execute_command - see README.md) happens to set HOME=/root; that
# isn't guaranteed (needs `always_set_home` in sudoers), and when it doesn't, the install lands
# under the SSH user's home instead while the rest of this script keeps assuming /root - the
# systemd unit's ExecStart then points at a binary that was never actually placed there. Pin
# BUN_INSTALL so the binary lands at a known absolute path regardless of HOME.
curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash
command -v bun >/dev/null 2>&1 || { echo "bun.sh: bun install did not produce /usr/local/bin/bun" >&2; exit 1; }


# --------------------------------------------------
# App: minimal, dependency-free stand-in for a `bun run build` output - no npm dependencies on
# purpose (nothing here needs `bun install` and its own registry reachability at build time).
# Replace both with your own deploy step (copy dist/index.js + dist/public/* in from wherever CI
# puts them, fetch from S3/git, ...) - the unit only needs something that honours PORT/HOST.
# --------------------------------------------------

useradd --system --no-create-home --shell /sbin/nologin bunapp 2>/dev/null || true

# Same releases/<version> + current-symlink layout bun-hydrate/deploy.sh deploys into - the
# baked copy here is release "0-baked", just so the image boots with a working app (and the
# smoke test below has something to hit) before the first real deploy ever runs.
APP_ROOT=/opt/myapp
BAKED_RELEASE="$APP_ROOT/releases/0-baked"

mkdir -p "$BAKED_RELEASE/public"

# Stand-in for the client bundle a real build would emit into dist/public/.
cat > "$BAKED_RELEASE/public/hydrate.js" <<'EOF'
console.log("bun-hydrate placeholder client bundle - replace dist/public/* with a real build");
EOF

# Stand-in server. Static files first: a request that maps to a regular file under PUBLIC_DIR is
# served straight off disk (resolved and checked to stay inside PUBLIC_DIR, so `/../etc/passwd`
# can't escape it), then "/" is rendered on the fly and /health answered - the parts a static
# server can't do. A real app swaps this for its own dist/index.js. PUBLIC_DIR defaults relative
# to cwd (the "current" symlink's target, whichever release that is), not a hardcoded path.
cat > "$BAKED_RELEASE/index.ts" <<'EOF'
import { stat } from "node:fs/promises";
import { resolve, sep } from "node:path";

const PORT = Number(process.env.PORT || 80);
const HOST = process.env.HOST || "0.0.0.0";
const PUBLIC_DIR = resolve(process.env.PUBLIC_DIR || "public");
const startedAt = Date.now();

async function staticFile(pathname: string): Promise<Response | null> {
  let decoded: string;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return new Response("Bad request", { status: 400 });
  }
  const path = resolve(PUBLIC_DIR, "." + decoded);
  if (!path.startsWith(PUBLIC_DIR + sep)) return null;
  try {
    if (!(await stat(path)).isFile()) return null;
  } catch {
    return null;
  }
  return new Response(Bun.file(path), {
    headers: { "cache-control": "public, max-age=31536000, immutable" },
  });
}

Bun.serve({
  hostname: HOST,
  port: PORT,
  async fetch(req) {
    const { pathname } = new URL(req.url);

    if (pathname === "/health") {
      return Response.json({
        status: "ok",
        uptime: Math.floor((Date.now() - startedAt) / 1000),
      });
    }

    if (pathname === "/") {
      return new Response(
        `<!doctype html><html><body><h1>bun app (project-11 CD stack)</h1><script src="/hydrate.js"></script></body></html>`,
        { headers: { "content-type": "text/html" } },
      );
    }

    const file = await staticFile(pathname);
    if (file) return file;

    return Response.json({ status: 404, message: "Not found" }, { status: 404 });
  },
});

console.log(`Listening on ${HOST}:${PORT}`);
EOF

chown -R bunapp:bunapp "$APP_ROOT"
ln -sfn "$BAKED_RELEASE" "$APP_ROOT/current"

# :80 without running as root - the capability is all the unprivileged bunapp user gets.
# WorkingDirectory is the "current" symlink, not a release path directly, so a deploy.sh
# run that re-points it and restarts this unit is all a real deploy takes - matching
# bun-hydrate/deploy.sh's SERVICE_NAME=myapp and its releases/<version>+current layout.
cat > /etc/systemd/system/myapp.service <<EOF
[Unit]
Description=Bun app (project-11 CD stack)
After=network.target

[Service]
Type=simple
User=bunapp
Group=bunapp
WorkingDirectory=$APP_ROOT/current
ExecStart=/usr/local/bin/bun run index.ts
Restart=on-failure
RestartSec=2
Environment=PORT=80
Environment=HOST=0.0.0.0
Environment=NODE_ENV=production
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl enable myapp.service


# --------------------------------------------------
# Smoke test now, not just "the unit parsed" - start it for real and confirm Bun serves a
# static asset, an app route, and refuses a path-traversal attempt, before this becomes a
# snapshotted image.
# --------------------------------------------------

systemctl start myapp.service
sleep 2

curl -fsS http://127.0.0.1/hydrate.js | grep -q 'placeholder client bundle' \
    && echo "bun.sh: smoke test passed - static asset served by bun" \
    || { echo "bun.sh: smoke test failed - static asset not served" >&2; exit 1; }

curl -fsS http://127.0.0.1/health | grep -q '"status":"ok"' \
    && echo "bun.sh: smoke test passed - app route answered" \
    || { echo "bun.sh: smoke test failed - /health not answered" >&2; exit 1; }

[[ "$(curl -s --path-as-is -o /dev/null -w '%{http_code}' 'http://127.0.0.1/../../etc/passwd')" == "404" ]] \
    && echo "bun.sh: smoke test passed - path traversal refused" \
    || { echo "bun.sh: smoke test failed - path traversal not refused" >&2; exit 1; }
