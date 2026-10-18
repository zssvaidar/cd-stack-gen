#!/bin/bash
# nodejs.sh with Caddy instead of nginx in front - same app, same node-app.service, same port
# layout (Caddy on :80 -> node on 127.0.0.1:3000), so anything launched from either image looks
# the same from the outside. Built by project-13's live/shared/ami-nodejs.
#
# Caddy isn't in Amazon Linux's repos, so it's installed from the official release tarball,
# pinned and checksum-verified like docker.sh's plugins. Plain HTTP on :80 here: TLS belongs to
# whatever sits in front (a load balancer, Cloudflare). To have Caddy itself terminate TLS with
# automatic Let's Encrypt instead, replace `:80` in the Caddyfile with the public hostname - the
# instance then needs a public IP and :80/:443 open to the internet.
# Targets Amazon Linux 2023.
set -e

# Amazon Linux's own background jobs (dnf-makecache.timer, SSM inventory collection) can grab
# the rpm transaction lock at any point after boot, independent of cloud-init - dnf/yum don't
# wait for that lock, they fail immediately. Retry rather than assume the box is quiet - see
# ami-scripts/README.md.
retry_pkg() {
    local n=0 max=6
    until "$@"; do
        n=$((n + 1))
        [[ "$n" -ge "$max" ]] && return 1
        echo "package manager busy (rpm lock held) - retry $n/$max in 5s" >&2
        sleep 5
    done
}

# Amazon Linux 2023 ships a current Node.js directly in its own repos - see nodejs.sh.
retry_pkg dnf install -y nodejs


# --------------------------------------------------
# App: identical to nodejs.sh - replace this whole section with your own deploy step; the
# systemd unit below only cares that something listens on 127.0.0.1:3000.
# --------------------------------------------------

useradd --system --no-create-home --shell /sbin/nologin nodeapp 2>/dev/null || true

mkdir -p /opt/app
cat > /opt/app/server.js <<'EOF'
const http = require('http');

const PORT = process.env.PORT || 3000;
const SERVICE_NAME = 'node-app';

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', service: SERVICE_NAME }));
    return;
  }

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end(`Hello from ${SERVICE_NAME} (project-11 CD stack)\n`);
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`${SERVICE_NAME} listening on :${PORT}`);
});
EOF

chown -R nodeapp:nodeapp /opt/app

cat > /etc/systemd/system/node-app.service <<'EOF'
[Unit]
Description=Node.js app (project-11 CD stack)
After=network.target

[Service]
Type=simple
User=nodeapp
Group=nodeapp
ExecStart=/usr/bin/node /opt/app/server.js
Restart=on-failure
RestartSec=2
Environment=PORT=3000
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl enable node-app.service


# --------------------------------------------------
# Caddy: reverse proxy on :80 -> the app on 127.0.0.1:3000. The app only binds to localhost
# (see server.listen above) - Caddy is the only thing meant to reach it directly.
# Pinned with sha512 from the release's caddy_<version>_checksums.txt - bump all three together.
# --------------------------------------------------

CADDY_VERSION=2.10.2
declare -A CADDY_SHA512=(
    [amd64]=747df7ee74de188485157a383633a1a963fd9233b71fbb4a69ddcbcc589ce4e2cc82dacf5dbbe136cb51d17e14c59daeb5d9bc92487610b0f3b93680b2646546
    [arm64]=6ce061a690312ab38367df3c5d5f89a2e4a263e7300d300d87356211bb81e79b15933e6d6203e03fbf26f15cc0311f264805f336147dbdd24938d84b57a4421c
)

case "$(uname -m)" in
    x86_64) caddy_arch=amd64 ;;
    aarch64) caddy_arch=arm64 ;;
    *) echo "nodejs_caddy.sh: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

caddy_tgz=$(mktemp)
curl -fsSL --retry 5 -o "$caddy_tgz" \
    "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${caddy_arch}.tar.gz"
echo "${CADDY_SHA512[$caddy_arch]}  $caddy_tgz" | sha512sum -c --quiet - \
    || { echo "nodejs_caddy.sh: checksum mismatch for caddy $CADDY_VERSION" >&2; exit 1; }
tar -xzf "$caddy_tgz" -C /usr/local/bin caddy
chmod 0755 /usr/local/bin/caddy
rm -f "$caddy_tgz"

# runs unprivileged; its home is where Caddy keeps its data (certificates, if TLS is turned on)
useradd --system --home-dir /var/lib/caddy --create-home --shell /sbin/nologin caddy 2>/dev/null || true

mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<'EOF'
# `:80` = any hostname, plain HTTP - a bare port gets no automatic HTTPS.
:80 {
	reverse_proxy 127.0.0.1:3000
}
EOF

/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# the upstream caddy.service, with the binary at /usr/local/bin
cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable caddy.service


# --------------------------------------------------
# Smoke test now, not just "the config parsed" - start both for real and confirm the app
# actually answers through Caddy before this becomes a snapshotted image.
# --------------------------------------------------

systemctl start node-app.service
systemctl start caddy.service

sleep 2

curl -fsS http://127.0.0.1/health | grep -q '"status":"ok"' \
    && echo "nodejs_caddy.sh: smoke test passed - app reachable through caddy" \
    || { echo "nodejs_caddy.sh: smoke test failed - app not reachable through caddy" >&2; journalctl -u caddy -u node-app -n 30 --no-pager >&2; exit 1; }
