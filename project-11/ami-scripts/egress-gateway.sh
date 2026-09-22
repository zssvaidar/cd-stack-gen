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
