#!/bin/bash
# Copy this to ami-scripts/<env-type>.sh and replace the body with whatever that
# environment actually needs baked in - this one just installs cloudflared as a placeholder
# so `run.sh ami` has something real to build and you can see the shape of a working script.
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

curl -fsSL https://pkg.cloudflare.com/cloudflared.repo | tee /etc/yum.repos.d/cloudflared.repo

if command -v dnf >/dev/null 2>&1; then
    retry_pkg dnf install -y cloudflared
else
    retry_pkg yum install -y cloudflared
fi
