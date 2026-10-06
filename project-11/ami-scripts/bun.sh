#!/bin/bash
# Copy this to ami-scripts/<env-type>.sh (or point PROVISION_SCRIPT at your own copy) - same
# shape as nodejs.sh, but for a Bun app with a build step that produces static client assets
# (dist/public/*) alongside the server, the way https://github.com/zssvaidar/bun-hydrate does.
# nginx sits on :80 as both the static file server (short-circuits requests for a built asset
# straight off disk) and the reverse proxy for everything else - SSR pages, API routes, /health -
# which is only Bun's job. Swap the app section for a real `bun run build` + copy-in step and the
# nginx location block stays the same.
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

if command -v dnf >/dev/null 2>&1; then
    retry_pkg dnf install -y nginx unzip
else
    retry_pkg yum install -y nginx unzip
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
# purpose, same reasoning as nodejs.sh's server.js (nothing here needs `npm install` and its own
# registry reachability to work at build time). Replace both files with your own deploy step
# (copy dist/index.js + dist/public/* in from wherever CI puts them, fetch from S3/git, ...) -
# nginx only cares that dist/public holds static files and that something listens on
# 127.0.0.1:3000, not how either got there.
# --------------------------------------------------

useradd --system --no-create-home --shell /sbin/nologin bunapp 2>/dev/null || true

mkdir -p /opt/app/public

# Stand-in for the client bundle a real build would emit into dist/public/ - served directly by
# nginx, never touching the Bun process.
cat > /opt/app/public/hydrate.js <<'EOF'
console.log("bun-hydrate placeholder client bundle - replace dist/public/* with a real build");
EOF

# Stand-in server: renders "/" on the fly (the part a static file server can't do), answers
# /health, and 404s everything else it owns. A real app swaps this for its own dist/index.js.
cat > /opt/app/index.ts <<'EOF'
const PORT = Number(process.env.PORT || 3000);
const HOST = process.env.HOST || "127.0.0.1";
const startedAt = Date.now();

Bun.serve({
  hostname: HOST,
  port: PORT,
  fetch(req) {
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

    return new Response(JSON.stringify({ status: 404, message: "Not found" }), { status: 404 });
  },
});

console.log(`Listening on ${HOST}:${PORT}`);
EOF

chown -R bunapp:bunapp /opt/app

cat > /etc/systemd/system/bun-app.service <<'EOF'
[Unit]
Description=Bun app (project-11 CD stack)
After=network.target

[Service]
Type=simple
User=bunapp
Group=bunapp
WorkingDirectory=/opt/app
ExecStart=/usr/local/bin/bun run index.ts
Restart=on-failure
RestartSec=2
Environment=PORT=3000
Environment=HOST=127.0.0.1
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl enable bun-app.service


# --------------------------------------------------
# nginx: serve dist/public straight off disk when a request matches a built file, otherwise fall
# through to Bun on 127.0.0.1:3000 for SSR pages, /health, and any other app route. This is the
# split that makes nginx worth having in front of an SSR app instead of just proxying everything -
# static assets never round-trip through the Bun process.
# --------------------------------------------------

cat > /etc/nginx/conf.d/app.conf <<'EOF'
upstream bun_app {
    server 127.0.0.1:3000;
}

server {
    listen 80 default_server;
    server_name _;

    root /opt/app/public;

    location / {
        try_files $uri @bun;
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    location @bun {
        proxy_pass http://bun_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

systemctl enable nginx.service


# --------------------------------------------------
# Smoke test now, not just "the config parsed" - start both for real and confirm nginx actually
# serves a static asset directly *and* proxies through to Bun for a route only the app owns,
# before this becomes a snapshotted image.
# --------------------------------------------------

systemctl start bun-app.service
systemctl start nginx.service

sleep 2

curl -fsS http://127.0.0.1/hydrate.js | grep -q 'placeholder client bundle' \
    && echo "bun.sh: smoke test passed - static asset served by nginx" \
    || { echo "bun.sh: smoke test failed - static asset not served by nginx" >&2; exit 1; }

curl -fsS http://127.0.0.1/health | grep -q '"status":"ok"' \
    && echo "bun.sh: smoke test passed - app reachable through nginx" \
    || { echo "bun.sh: smoke test failed - app not reachable through nginx" >&2; exit 1; }
