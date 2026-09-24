#!/bin/bash
# Built via: TIER=egress ./run.sh ami <ami-name> egress-balancer create
# The egress-gateway.sh image plus nginx as an HTTP load balancer on :80, so one public instance
# in the egress tier does both jobs: NATs the app tier's outbound traffic *and* spreads inbound
# HTTP across the app-tier instances. manage_egress_balancer.sh launches instances from this AMI
# and owns everything that's only known at launch time - disabling source/dest check, pointing
# the relayed subnets at it, and which backend IPs nginx balances across (written by user-data at
# first boot, re-pushed over SSM by `run.sh egress-balancer <name> sync`) and, if HTTPS is
# enabled, which domain(s) to get a Let's Encrypt certificate for. This script only has to make
# the box *capable* of all of it; it has no idea yet which backends or domain it'll end up with.
# Also installs cloudflared, off until manage_egress_balancer.sh points it at a tunnel token
# stored in SSM (CLOUDFLARE_TUNNEL_TOKEN) - point the tunnel's public hostname at
# http://localhost:8080 and Cloudflare terminates HTTPS instead of HTTPS_DOMAINS/Let's Encrypt.
# Targets Amazon Linux 2023 - nftables is the default firewall backend there.
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

retry_pkg dnf install -y nftables nginx openssl python3-pip

# certbot isn't in Amazon Linux 2023's repos (no EPEL, no snapd) - install it into its own venv,
# which is certbot's documented pip install path, instead of pulling in a third-party repo
python3 -m venv /opt/certbot
/opt/certbot/bin/pip install --quiet --upgrade pip
/opt/certbot/bin/pip install --quiet certbot
ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot
/usr/local/bin/certbot --version


# --------------------------------------------------
# NAT half - egress-gateway.sh's NAT setup minus its optional tcp/443 passthrough (this box
# terminates HTTPS itself in nginx, so 443 must reach nginx, not be DNAT'd elsewhere). Packer
# uploads one provisioner script per build, so it's repeated here rather than shared. See that
# file for why the interface is resolved at boot and why the forward chain only accepts RFC1918
# sources. No input chain is defined, so nothing here filters traffic addressed to the box
# itself - nginx's :80/:443 are gated by the instance's security group, same as any other
# instance.
# --------------------------------------------------

cat > /etc/sysctl.d/99-egress-gateway.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF

sysctl --system >/dev/null

cat > /usr/local/sbin/egress-gateway-nat.sh <<'SCRIPT'
#!/bin/bash
set -e

IFACE=$(ip -4 route show default | awk '{print $5; exit}')
[[ -n "$IFACE" ]] || { echo "egress-gateway-nat: no default route interface found" >&2; exit 1; }

nft -f - <<NFT
flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oif "$IFACE" masquerade
    }
}

table ip filter {
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } oif "$IFACE" accept
    }
}
NFT

echo "egress-gateway-nat: applied ruleset (interface $IFACE)"
SCRIPT

chmod +x /usr/local/sbin/egress-gateway-nat.sh

cat > /etc/systemd/system/egress-gateway-nat.service <<'EOF'
[Unit]
Description=Apply egress gateway NAT rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/egress-gateway-nat.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl enable egress-gateway-nat.service
/usr/local/sbin/egress-gateway-nat.sh


# --------------------------------------------------
# Cloudflare Tunnel - installed, but off until the manager points it at a token. The token is
# never baked in: /etc/cloudflare-tunnel/param holds only an SSM Parameter Store *name*
# (written by user-data / `sync`), and cloudflare-tunnel-run.sh fetches the SecureString with
# the instance profile every time cloudflared starts, handing it over as TUNNEL_TOKEN in the
# process environment - never written to disk, never on a command line. Needs
# ssm:GetParameter on that parameter (and kms:Decrypt for a customer-managed key).
# --------------------------------------------------

curl -fsSL https://pkg.cloudflare.com/cloudflared.repo -o /etc/yum.repos.d/cloudflared.repo
retry_pkg dnf install -y cloudflared
command -v aws >/dev/null 2>&1 || retry_pkg dnf install -y awscli-2

mkdir -p /etc/cloudflare-tunnel
[[ -f /etc/cloudflare-tunnel/param ]] || : > /etc/cloudflare-tunnel/param

cat > /usr/local/sbin/cloudflare-tunnel-run.sh <<'SCRIPT'
#!/bin/bash
set -e

PARAM=$(tr -d '[:space:]' < /etc/cloudflare-tunnel/param 2>/dev/null || true)
[[ -n "$PARAM" ]] || { echo "cloudflare-tunnel: no parameter configured" >&2; exit 1; }

IMDS_TOKEN=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
REGION=$(curl -fsS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

TUNNEL_TOKEN=$(aws ssm get-parameter --region "$REGION" --name "$PARAM" --with-decryption \
    --query Parameter.Value --output text) \
    || { echo "cloudflare-tunnel: can't read $PARAM - does the instance profile allow ssm:GetParameter on it?" >&2; exit 1; }
export TUNNEL_TOKEN

exec /usr/bin/cloudflared --no-autoupdate tunnel run
SCRIPT

chmod 700 /usr/local/sbin/cloudflare-tunnel-run.sh

# start/restart or stop cloudflared to match /etc/cloudflare-tunnel/param - what user-data and
# `sync` call after writing it. A restart re-fetches the token, which is how rotation lands.
cat > /usr/local/sbin/cloudflare-tunnel.sh <<'SCRIPT'
#!/bin/bash
set -e

PARAM=$(tr -d '[:space:]' < /etc/cloudflare-tunnel/param 2>/dev/null || true)

if [[ -z "$PARAM" ]]; then
    systemctl disable --now cloudflare-tunnel.service >/dev/null 2>&1 || true
    echo "cloudflare-tunnel: off"
    exit 0
fi

systemctl enable cloudflare-tunnel.service >/dev/null 2>&1
systemctl restart cloudflare-tunnel.service
sleep 3
if systemctl is-active --quiet cloudflare-tunnel.service; then
    echo "cloudflare-tunnel: running (token from $PARAM)"
else
    echo "cloudflare-tunnel: failed to start - journalctl -u cloudflare-tunnel" >&2
    journalctl -u cloudflare-tunnel.service -n 20 --no-pager >&2 || true
    exit 1
fi
SCRIPT

chmod +x /usr/local/sbin/cloudflare-tunnel.sh

cat > /etc/systemd/system/cloudflare-tunnel.service <<'EOF'
[Unit]
Description=Cloudflare Tunnel (token from SSM Parameter Store)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/cloudflare-tunnel-run.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
cloudflared --version

# --------------------------------------------------
# Load balancer half. The backend list can't be baked in - the app instances don't exist yet
# at build time and their private IPs change every relaunch - so the nginx config is rendered
# from plain files instead:
#   /etc/egress-balancer/backends    one host:port per line (# comments allowed)
#   /etc/egress-balancer/method      round_robin (default) | least_conn | ip_hash
#   /etc/egress-balancer/https.conf  KEY=VALUE lines, HTTPS settings - see the cert script below
# manage_egress_balancer.sh writes them (user-data at launch, SSM send-command on `sync`) and
# then runs the cert script, which always finishes by running the render script: validate,
# swap the config in, `nginx -t`, roll back on failure, reload. An empty backend list is valid:
# nginx answers 503 instead of failing to start on an upstream block with no servers. The :443
# server only appears once a certificate actually exists - until then (DNS not pointed here yet,
# issuance failed) the balancer keeps serving plain HTTP rather than refusing to start.
# --------------------------------------------------

mkdir -p /etc/egress-balancer
[[ -f /etc/egress-balancer/backends ]]   || echo "# host:port, one per line" > /etc/egress-balancer/backends
[[ -f /etc/egress-balancer/method ]]     || echo "round_robin" > /etc/egress-balancer/method
[[ -f /etc/egress-balancer/https.conf ]] || : > /etc/egress-balancer/https.conf

cat > /usr/local/sbin/egress-balancer-render.sh <<'SCRIPT'
#!/bin/bash
set -e

CONF_DIR=/etc/egress-balancer
BACKENDS_FILE=$CONF_DIR/backends
METHOD_FILE=$CONF_DIR/method
HTTPS_FILE=$CONF_DIR/https.conf
CERT_DIR=/etc/letsencrypt/live/egress-balancer
ACME_ROOT=/var/www/egress-balancer-acme
CONF=/etc/nginx/conf.d/egress-balancer.conf

# https.conf is KEY=VALUE written by manage_egress_balancer.sh - parsed, never sourced
https_get() { sed -n "s/^$1=//p" "$HTTPS_FILE" 2>/dev/null | tail -1; }

METHOD=$(tr -d '[:space:]' < "$METHOD_FILE" 2>/dev/null || true)
case "${METHOD:-round_robin}" in
    round_robin)        METHOD_LINE="" ;;
    least_conn|ip_hash) METHOD_LINE="    $METHOD;" ;;
    *) echo "egress-balancer-render: unknown method '$METHOD' (round_robin|least_conn|ip_hash)" >&2; exit 1 ;;
esac

# strictly host:port per line - this file ends up spliced into nginx config, so anything else
# (stray `;`, `}`, directives) is rejected rather than trusted
SERVERS=""
COUNT=0
while read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || { echo "egress-balancer-render: invalid backend '$line'" >&2; exit 1; }
    SERVERS+="    server $line max_fails=3 fail_timeout=10s;"$'\n'
    COUNT=$((COUNT + 1))
done < "$BACKENDS_FILE"

# TLS only when HTTPS is configured *and* a certificate is actually on disk - never render a
# :443 server pointing at files that aren't there, nginx would refuse the whole config
DOMAINS=$(https_get DOMAINS)
REDIRECT=$(https_get REDIRECT)
TLS=0
[[ -n "$DOMAINS" && -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]] && TLS=1

# nginx workers (not root) serve challenge files out of here - must be world-readable
mkdir -p "$ACME_ROOT"
chmod 755 "$ACME_ROOT"

if [[ "$COUNT" -gt 0 ]]; then
    UPSTREAM="upstream egress_balancer_backends {
$METHOD_LINE
$SERVERS    keepalive 32;
}
"
    PROXY="        proxy_pass http://egress_balancer_backends;
        proxy_http_version 1.1;
        proxy_set_header Connection \"\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 3s;
        proxy_next_upstream error timeout http_502 http_503 http_504;"
else
    UPSTREAM=""
    PROXY="        default_type text/plain;
        return 503 \"egress-balancer: no backends configured\\n\";"
fi

# the balancer's own liveness, answered locally on both listeners - doesn't depend on any backend
HEALTH="    location = /lb-health {
        access_log off;
        default_type text/plain;
        return 200 \"ok backends=$COUNT https=$TLS\\n\";
    }"

# :80 always serves the ACME HTTP-01 webroot (issuance and every renewal go through it) and
# /lb-health; everything else is either proxied or, once TLS is up and REDIRECT isn't false,
# bounced to https
if [[ "$TLS" == "1" && "$REDIRECT" != "false" ]]; then
    HTTP_ROOT="        return 301 https://\$host\$request_uri;"
else
    HTTP_ROOT="$PROXY"
fi

HTTPS_SERVER=""
if [[ "$TLS" == "1" ]]; then
    HTTPS_SERVER="
server {
    listen 443 ssl default_server;
    server_name _;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:egress_balancer_tls:10m;
    ssl_session_timeout 1d;

$HEALTH

    location / {
$PROXY
    }
}"
fi

# Cloudflare Tunnel origin: loopback-only, so the only thing that can reach it is cloudflared on
# this box - which is what makes trusting CF-Connecting-IP from 127.0.0.1 safe. Its own listener
# rather than :80 because :80 may 301 to https, and the tunnel already arrives as http from an
# https edge - pointing it at :80 would redirect-loop. Always rendered; unused without a tunnel.
TUNNEL_PROXY=${PROXY/'X-Forwarded-Proto $scheme'/'X-Forwarded-Proto https'}
TUNNEL_SERVER="
server {
    listen 127.0.0.1:8080;
    server_name _;

    set_real_ip_from 127.0.0.1;
    real_ip_header   CF-Connecting-IP;

$HEALTH

    location / {
$TUNNEL_PROXY
    }
}"

NEW=$(mktemp)
cat > "$NEW" <<NGINX
# rendered by /usr/local/sbin/egress-balancer-render.sh from $CONF_DIR - edit those, not this
${UPSTREAM}server {
    listen 80 default_server;
    server_name _;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_ROOT;
        default_type text/plain;
    }

$HEALTH

    location / {
$HTTP_ROOT
    }
}
$HTTPS_SERVER
$TUNNEL_SERVER
NGINX

BACKUP=""
[[ -f "$CONF" ]] && { BACKUP=$(mktemp); cp "$CONF" "$BACKUP"; }
install -m 0644 "$NEW" "$CONF"
rm -f "$NEW"

if ! nginx -t -q; then
    echo "egress-balancer-render: nginx -t failed - restoring previous config" >&2
    if [[ -n "$BACKUP" ]]; then cp "$BACKUP" "$CONF"; else rm -f "$CONF"; fi
    rm -f "$BACKUP"
    exit 1
fi
rm -f "$BACKUP"

systemctl reload-or-restart nginx.service
echo "egress-balancer-render: $COUNT backend(s), method=${METHOD:-round_robin}, https=$TLS"
SCRIPT

chmod +x /usr/local/sbin/egress-balancer-render.sh


# --------------------------------------------------
# Certificate half - Let's Encrypt via certbot's webroot mode, so nginx keeps serving throughout
# (no --standalone, which would need :80 to itself). /etc/egress-balancer/https.conf:
#   DOMAINS=example.com,www.example.com   empty = HTTPS off (plain HTTP only)
#   EMAIL=ops@example.com                 empty = --register-unsafely-without-email
#   REDIRECT=true|false                   http -> https once a cert exists (default true)
#   STAGING=true|false                    Let's Encrypt staging CA, for testing (default false)
#   DNS_CHECK=true|false                  only ask LE once every domain resolves to this box's
#                                         public IP (default true); false behind a proxy like
#                                         Cloudflare, where DNS points at the proxy instead
# Idempotent - run at first boot (user-data), on every `sync`, and twice a day by a timer:
# issues when there's no cert or DOMAINS/STAGING changed since the last issuance, otherwise
# just `certbot renew` (a no-op until 30 days before expiry). Always ends by rendering nginx.
# The DNS check exists because the public IP isn't known until launch - the first boot usually
# can't validate yet, and failed validations count against Let's Encrypt's rate limits.
# --------------------------------------------------

cat > /usr/local/sbin/egress-balancer-cert.sh <<'SCRIPT'
#!/bin/bash
set -e

CONF_DIR=/etc/egress-balancer
HTTPS_FILE=$CONF_DIR/https.conf
ISSUED_FILE=$CONF_DIR/cert-issued
CERT_NAME=egress-balancer
CERT_DIR=/etc/letsencrypt/live/$CERT_NAME
ACME_ROOT=/var/www/egress-balancer-acme
CERTBOT=/usr/local/bin/certbot
RENDER=/usr/local/sbin/egress-balancer-render.sh

https_get() { sed -n "s/^$1=//p" "$HTTPS_FILE" 2>/dev/null | tail -1; }

DOMAINS=$(https_get DOMAINS)
EMAIL=$(https_get EMAIL)
STAGING=$(https_get STAGING)
DNS_CHECK=$(https_get DNS_CHECK)

if [[ -z "$DOMAINS" ]]; then
    # HTTPS off - any old cert is left on disk (harmless, render ignores it without DOMAINS)
    exec "$RENDER"
fi

[[ "$DOMAINS" =~ ^[A-Za-z0-9.-]+(,[A-Za-z0-9.-]+)*$ ]] || { echo "egress-balancer-cert: invalid DOMAINS '$DOMAINS'" >&2; exit 1; }
[[ -z "$EMAIL" || "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || { echo "egress-balancer-cert: invalid EMAIL '$EMAIL'" >&2; exit 1; }
IFS=, read -ra DOMAIN_LIST <<< "$DOMAINS"

WANT="$DOMAINS staging=${STAGING:-false}"

# already have exactly this cert - just renew (certbot decides whether it's due)
if [[ -s "$CERT_DIR/fullchain.pem" && "$(cat "$ISSUED_FILE" 2>/dev/null)" == "$WANT" ]]; then
    "$CERTBOT" renew --cert-name "$CERT_NAME" --non-interactive --quiet \
        --deploy-hook "systemctl reload nginx.service" \
        || echo "egress-balancer-cert: renew failed - keeping the current certificate" >&2
    exec "$RENDER"
fi

if [[ "$DNS_CHECK" != "false" ]]; then
    TOKEN=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)
    MY_IP=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 || true)

    for d in "${DOMAIN_LIST[@]}"; do
        if ! getent ahostsv4 "$d" | awk '{print $1}' | grep -qxF "${MY_IP:-unknown}"; then
            echo "egress-balancer-cert: $d doesn't resolve to this instance's public IP (${MY_IP:-unknown}) yet - not requesting a certificate." >&2
            echo "egress-balancer-cert: point DNS at it, then 'run.sh egress-balancer <name> sync' (or HTTPS_DNS_CHECK=false behind a proxy)." >&2
            exec "$RENDER"
        fi
    done
fi

# domains or CA changed since the last issuance - drop the old lineage rather than letting
# certbot decide it's "not due for renewal yet" and keep serving the wrong names/CA. Render
# first so nginx never has a config pointing at files that are about to disappear.
if [[ -d "$CERT_DIR" ]]; then
    rm -f "$ISSUED_FILE"
    mv "$HTTPS_FILE" "$HTTPS_FILE.pending"
    "$RENDER" || true
    mv "$HTTPS_FILE.pending" "$HTTPS_FILE"
    "$CERTBOT" delete --cert-name "$CERT_NAME" --non-interactive
fi

"$RENDER"   # :80 with the ACME webroot must be live before asking for validation

args=(certonly --webroot -w "$ACME_ROOT" --cert-name "$CERT_NAME" --non-interactive --agree-tos
      --deploy-hook "systemctl reload nginx.service")
for d in "${DOMAIN_LIST[@]}"; do args+=(-d "$d"); done
if [[ -n "$EMAIL" ]]; then args+=(-m "$EMAIL"); else args+=(--register-unsafely-without-email); fi
[[ "$STAGING" == "true" ]] && args+=(--staging)

if "$CERTBOT" "${args[@]}"; then
    echo "$WANT" > "$ISSUED_FILE"
    echo "egress-balancer-cert: certificate issued for $DOMAINS"
else
    echo "egress-balancer-cert: certbot failed - serving plain HTTP until the next attempt" >&2
fi

exec "$RENDER"
SCRIPT

chmod +x /usr/local/sbin/egress-balancer-cert.sh

# renewals - certbot installed via pip ships no timer of its own
cat > /etc/systemd/system/egress-balancer-cert.service <<'EOF'
[Unit]
Description=Issue/renew the egress balancer's Let's Encrypt certificate
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/egress-balancer-cert.sh
EOF

cat > /etc/systemd/system/egress-balancer-cert.timer <<'EOF'
[Unit]
Description=Twice-daily egress balancer certificate issue/renew

[Timer]
OnBootSec=10min
OnUnitActiveSec=12h
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF

systemctl enable nginx.service
systemctl enable egress-balancer-cert.timer
/usr/local/sbin/egress-balancer-render.sh


# --------------------------------------------------
# Smoke test before snapshotting: with no backends yet, the balancer itself must be up
# (/lb-health 200) and everything else must be a clean 503, not a connection error. Then render
# against a throwaway local backend to prove the proxy path works, over HTTP and - with a
# self-signed stand-in placed where certbot would put the real cert - over HTTPS plus the
# http->https redirect. Everything is put back so the image boots into the "no backends, no
# HTTPS" state until manage_egress_balancer.sh says otherwise.
# --------------------------------------------------

sleep 1

curl -fsS http://127.0.0.1/lb-health | grep -q 'ok backends=0' \
    && echo "egress-balancer.sh: smoke test passed - /lb-health answered" \
    || { echo "egress-balancer.sh: smoke test failed - /lb-health not answering" >&2; exit 1; }

[[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/)" == "503" ]] \
    && echo "egress-balancer.sh: smoke test passed - 503 with no backends" \
    || { echo "egress-balancer.sh: smoke test failed - expected 503 with no backends" >&2; exit 1; }

mkdir -p /tmp/egress-balancer-smoke
echo "smoke-backend" > /tmp/egress-balancer-smoke/index.html
python3 -m http.server 18080 --bind 127.0.0.1 --directory /tmp/egress-balancer-smoke >/dev/null 2>&1 &
SMOKE_PID=$!
sleep 1

echo "127.0.0.1:18080" > /etc/egress-balancer/backends
/usr/local/sbin/egress-balancer-render.sh
sleep 1

SMOKE_HTTP=0
curl -fsS http://127.0.0.1/ | grep -q 'smoke-backend' && SMOKE_HTTP=1

SMOKE_CERT_DIR=/etc/letsencrypt/live/egress-balancer
[[ -e "$SMOKE_CERT_DIR" ]] && { echo "egress-balancer.sh: $SMOKE_CERT_DIR already exists on the builder - refusing to overwrite" >&2; exit 1; }
mkdir -p "$SMOKE_CERT_DIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=smoke.invalid" \
    -keyout "$SMOKE_CERT_DIR/privkey.pem" -out "$SMOKE_CERT_DIR/fullchain.pem" 2>/dev/null
echo "DOMAINS=smoke.invalid" > /etc/egress-balancer/https.conf
/usr/local/sbin/egress-balancer-render.sh
sleep 1

SMOKE_HTTPS=0
curl -fsSk https://127.0.0.1/ | grep -q 'smoke-backend' && SMOKE_HTTPS=1
SMOKE_REDIRECT=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/)

kill "$SMOKE_PID" 2>/dev/null || true
rm -rf /tmp/egress-balancer-smoke "$SMOKE_CERT_DIR"
rmdir /etc/letsencrypt/live /etc/letsencrypt 2>/dev/null || true
: > /etc/egress-balancer/https.conf
echo "# host:port, one per line" > /etc/egress-balancer/backends
/usr/local/sbin/egress-balancer-render.sh

[[ "$SMOKE_HTTP" == "1" ]] \
    && echo "egress-balancer.sh: smoke test passed - request proxied to a backend" \
    || { echo "egress-balancer.sh: smoke test failed - request not proxied to a backend" >&2; exit 1; }

[[ "$SMOKE_HTTPS" == "1" ]] \
    && echo "egress-balancer.sh: smoke test passed - request proxied over https" \
    || { echo "egress-balancer.sh: smoke test failed - request not proxied over https" >&2; exit 1; }

[[ "$SMOKE_REDIRECT" == "301" ]] \
    && echo "egress-balancer.sh: smoke test passed - http redirected to https" \
    || { echo "egress-balancer.sh: smoke test failed - expected 301 on http with https on, got $SMOKE_REDIRECT" >&2; exit 1; }
