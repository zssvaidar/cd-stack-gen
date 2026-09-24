#!/bin/bash
# Copy this to ami-scripts/<env-type>.sh (or point PROVISION_SCRIPT at your own copy) and swap
# out the app section for your real one - this is a real, runnable stack (not a placeholder like
# example.sh): nginx as the front end, Node.js running the app behind it as a systemd service.
# "choosing a set of technologies" for an AMI just means writing what you want installed here -
# there's no separate mechanism to pick from, the script body *is* the choice. This one happens
# to pick nginx + nodejs; a Python/gunicorn or Go-binary stack would be a different script with
# the same shape.
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

# Amazon Linux 2023 ships a current Node.js directly in its own repos - no NodeSource repo to
# add, one less external dependency and one less thing that can fail mid-build. If you need a
# specific major version this doesn't give you, that's the one part of this script actually
# worth swapping for a NodeSource (or nvm) install instead.
if command -v dnf >/dev/null 2>&1; then
    retry_pkg dnf install -y nodejs nginx
else
    retry_pkg yum install -y nodejs nginx
fi


# --------------------------------------------------
# App: the same minimal, dependency-free app as project-9/containers/node-app, just run
# directly on the instance instead of in a container. No npm dependencies on purpose - nothing
# here needs `npm install` (and its own package-registry reachability) to work. Replace this
# whole section with your own deploy step (copy build output in from wherever your CI puts it,
# fetch from S3/git, whatever) - the systemd unit below only cares that something listens on
# :3000, not how it got there.
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
# nginx: reverse proxy on :80 -> the app on 127.0.0.1:3000. The app only binds to localhost
# (see server.listen above) - nginx is the only thing meant to reach it directly, everything
# else goes through :80 where the security group's rules actually apply.
# --------------------------------------------------

cat > /etc/nginx/conf.d/app.conf <<'EOF'
server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

systemctl enable nginx.service


# --------------------------------------------------
# Smoke test now, not just "the config parsed" - start both for real and confirm the app
# actually answers through nginx before this becomes a snapshotted image. Cheaper to find a
# broken app.conf or a typo in server.js here than after launching from the built AMI.
# --------------------------------------------------

systemctl start node-app.service
systemctl start nginx.service

sleep 2

curl -fsS http://127.0.0.1/health | grep -q '"status":"ok"' \
    && echo "nodejs.sh: smoke test passed - app reachable through nginx" \
    || { echo "nodejs.sh: smoke test failed - app not reachable through nginx" >&2; exit 1; }
