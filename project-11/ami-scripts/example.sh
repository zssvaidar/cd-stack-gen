#!/bin/bash
# Copy this to ami-scripts/<env-type>.sh and replace the body with whatever that
# environment actually needs baked in - this one just installs cloudflared as a placeholder
# so `run.sh ami` has something real to build and you can see the shape of a working script.
# Targets Amazon Linux 2023 (dnf), falls back to Amazon Linux 2 (yum).
set -e

curl -fsSL https://pkg.cloudflare.com/cloudflared.repo | tee /etc/yum.repos.d/cloudflared.repo

if command -v dnf >/dev/null 2>&1; then
    dnf install -y cloudflared
else
    yum install -y cloudflared
fi
