#!/bin/bash
# Built via: ENV_TYPE=egress-gateway ./run.sh ami <ami-name> egress-gateway create
# Bakes IP forwarding + NAT (nftables masquerade) into the image, persisted across reboots by
# a small systemd unit - manage_egress_instance.sh launches instances from this AMI and owns
# the EC2-API-level half (disabling source/dest check, pointing the relayed subnets' route
# table at the launched instance). This script only has to make the box *capable* of NAT'ing;
# it has no idea yet which instance-id or route table it'll end up wired into.
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
