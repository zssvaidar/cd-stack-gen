#!/bin/bash
# Built via: ENV_TYPE=egress-gateway ./run.sh ami <ami-name> egress-gateway create
# Bakes IP forwarding + NAT (nftables masquerade) into the image, persisted across reboots by
# a small systemd unit - manage_egress_instance.sh launches instances from this AMI and owns
# the EC2-API-level half (disabling source/dest check, pointing the relayed subnets' route
# table at the launched instance). This script only has to make the box *capable* of NAT'ing;
# it has no idea yet which instance-id or route table it'll end up wired into.
# Also installs cloudflared, off until manage_egress_instance.sh points it at a tunnel token
# stored in SSM (CLOUDFLARE_TUNNEL_TOKEN) - see the Cloudflare Tunnel section below.
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

command -v nft >/dev/null 2>&1 || retry_pkg dnf install -y nftables


# --------------------------------------------------
# IP forwarding - off by default on any Linux box, has to be explicitly enabled for this
# instance to route packets between the VPC and the internet instead of just terminating them
# --------------------------------------------------

cat > /etc/sysctl.d/99-egress-gateway.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF

sysctl --system >/dev/null


# --------------------------------------------------
# Optional inbound HTTPS passthrough: when /etc/egress-gateway/https-forward holds a single
# `ip:port` (written by manage_egress_instance.sh via user-data, or `run.sh egress <name> sync`),
# tcp/443 arriving *addressed to this box* is DNAT'd to that backend untouched - TLS is terminated
# by the backend, not here, so no certificate ever lives on the gateway. The DNAT'd connection
# is also masqueraded on its way to the backend (same postrouting rule as everything else), so
# the backend replies to the gateway rather than straight to the client - works no matter how
# the backend's subnet routes, at the cost of the backend seeing the gateway's IP, not the
# client's. Empty/missing file: no prerouting chain at all, pure NAT as before.
# --------------------------------------------------

mkdir -p /etc/egress-gateway
[[ -f /etc/egress-gateway/https-forward ]] || : > /etc/egress-gateway/https-forward


# --------------------------------------------------
# NAT ruleset - applied by a script rather than baked in as a static nft file, since the
# primary network interface's name (eth0/ens5/...) depends on the instance's kernel/driver and
# isn't worth hardcoding into an image meant to be launched as any instance type. Only forwards
# traffic sourced from RFC1918 ranges: a box with a public IP and an unrestricted forward chain
# is an open relay for anyone on the internet who can route packets to it - restricting by
# source keeps it usable only as a gateway *for* private instances, not *by* the open internet.
# --------------------------------------------------

cat > /usr/local/sbin/egress-gateway-nat.sh <<'SCRIPT'
#!/bin/bash
set -e

IFACE=$(ip -4 route show default | awk '{print $5; exit}')
[[ -n "$IFACE" ]] || { echo "egress-gateway-nat: no default route interface found" >&2; exit 1; }

HTTPS_FORWARD=$(tr -d '[:space:]' < /etc/egress-gateway/https-forward 2>/dev/null || true)
PREROUTING=""
FORWARD_DNAT=""
if [[ -n "$HTTPS_FORWARD" ]]; then
    [[ "$HTTPS_FORWARD" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] \
        || { echo "egress-gateway-nat: invalid https-forward '$HTTPS_FORWARD' (want ip:port)" >&2; exit 1; }
    # `fib daddr type local` is what keeps this to inbound traffic for the gateway itself - the
    # relayed app tier's own outbound HTTPS arrives on this same interface with dport 443, and
    # without it every outbound https request would get hijacked to the backend
    PREROUTING="    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iif \"$IFACE\" fib daddr type local tcp dport 443 dnat to $HTTPS_FORWARD
    }"
    FORWARD_DNAT="        ct status dnat accept"
fi

nft -f - <<NFT
flush ruleset

table ip nat {
$PREROUTING
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oif "$IFACE" masquerade
    }
}

table ip filter {
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
$FORWARD_DNAT
        ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } oif "$IFACE" accept
    }
}
NFT

echo "egress-gateway-nat: applied ruleset (interface $IFACE, https-forward ${HTTPS_FORWARD:-off})"
SCRIPT

chmod +x /usr/local/sbin/egress-gateway-nat.sh


# --------------------------------------------------
# Apply at every boot, not just now - a dedicated systemd unit instead of relying on
# nftables.service's own config-file conventions (which vary by distro/version), since this
# only needs to run one script once per boot, after the network is up.
# --------------------------------------------------

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

echo "egress-gateway-nat.service enabled and applied"


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
