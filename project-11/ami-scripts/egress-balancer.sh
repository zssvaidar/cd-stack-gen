#!/bin/bash
# Built via: TIER=egress ./run.sh ami <ami-name> egress-balancer create
# The egress-gateway.sh image plus nginx as an HTTP load balancer on :80, so one public instance
# in the egress tier does both jobs: NATs the app tier's outbound traffic *and* spreads inbound
# HTTP across the app-tier instances. manage_egress_balancer.sh launches instances from this AMI
# and owns everything that's only known at launch time - disabling source/dest check, pointing
# the relayed subnets at it, and which backend IPs nginx balances across (written by user-data at
# first boot, re-pushed over SSM by `run.sh egress-balancer <name> sync`). This script only has
# to make the box *capable* of both; it has no idea yet which backends it'll end up fronting.
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

retry_pkg dnf install -y nftables nginx


# --------------------------------------------------
# NAT half - identical to egress-gateway.sh (Packer uploads one provisioner script per build, so
# it's repeated here rather than shared). See that file for why the interface is resolved at
# boot and why the forward chain only accepts RFC1918 sources. No input chain is defined, so
# nothing here filters traffic addressed to the box itself - nginx's :80 is gated by the
# instance's security group, same as any other instance.
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
# Load balancer half. The backend list can't be baked in - the app instances don't exist yet
# at build time and their private IPs change every relaunch - so the nginx config is rendered
# from two plain files instead:
#   /etc/egress-balancer/backends   one host:port per line (# comments allowed)
#   /etc/egress-balancer/method     round_robin (default) | least_conn | ip_hash
# manage_egress_balancer.sh writes both (user-data at launch, SSM send-command on `sync`) and
# then runs the render script, which validates, swaps the config in, `nginx -t`s it, rolls back
# on failure, and reloads. An empty backend list is valid: nginx answers 503 instead of failing
# to start on an upstream block with no servers.
# --------------------------------------------------

mkdir -p /etc/egress-balancer
[[ -f /etc/egress-balancer/backends ]] || echo "# host:port, one per line" > /etc/egress-balancer/backends
[[ -f /etc/egress-balancer/method ]]   || echo "round_robin" > /etc/egress-balancer/method

cat > /usr/local/sbin/egress-balancer-render.sh <<'SCRIPT'
#!/bin/bash
set -e

BACKENDS_FILE=/etc/egress-balancer/backends
METHOD_FILE=/etc/egress-balancer/method
CONF=/etc/nginx/conf.d/egress-balancer.conf

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

if [[ "$COUNT" -gt 0 ]]; then
    UPSTREAM="upstream egress_balancer_backends {
$METHOD_LINE
$SERVERS    keepalive 32;
}
"
    ROOT_LOCATION="        proxy_pass http://egress_balancer_backends;
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
    ROOT_LOCATION="        default_type text/plain;
        return 503 \"egress-balancer: no backends configured\\n\";"
fi

NEW=$(mktemp)
cat > "$NEW" <<NGINX
# rendered by /usr/local/sbin/egress-balancer-render.sh from $BACKENDS_FILE - edit that, not this
${UPSTREAM}server {
    listen 80 default_server;
    server_name _;

    # the balancer's own liveness, answered locally - doesn't depend on any backend being up
    location = /lb-health {
        access_log off;
        default_type text/plain;
        return 200 "ok backends=$COUNT\n";
    }

    location / {
$ROOT_LOCATION
    }
}
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
echo "egress-balancer-render: $COUNT backend(s), method=${METHOD:-round_robin}"
SCRIPT

chmod +x /usr/local/sbin/egress-balancer-render.sh

systemctl enable nginx.service
/usr/local/sbin/egress-balancer-render.sh


# --------------------------------------------------
# Smoke test before snapshotting: with no backends yet, the balancer itself must be up
# (/lb-health 200) and everything else must be a clean 503, not a connection error. Then render
# once against a throwaway local backend to prove the proxy path actually works, and put the
# empty config back so the image boots into the "no backends" state until manage_egress_balancer.sh
# says otherwise.
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

SMOKE_OK=0
curl -fsS http://127.0.0.1/ | grep -q 'smoke-backend' && SMOKE_OK=1

kill "$SMOKE_PID" 2>/dev/null || true
rm -rf /tmp/egress-balancer-smoke
echo "# host:port, one per line" > /etc/egress-balancer/backends
/usr/local/sbin/egress-balancer-render.sh

[[ "$SMOKE_OK" == "1" ]] \
    && echo "egress-balancer.sh: smoke test passed - request proxied to a backend" \
    || { echo "egress-balancer.sh: smoke test failed - request not proxied to a backend" >&2; exit 1; }
