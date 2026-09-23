#!/bin/bash
# EC2 user-data: installs Docker so the host is ready to receive images from the
# ec2-deploy Jenkinsfile. Targets Amazon Linux 2023 (dnf), falls back to Amazon Linux 2 (yum).
set -e

if command -v dnf >/dev/null 2>&1; then
    dnf update -y
    dnf install -y docker
else
    yum update -y
    yum install -y docker
fi

systemctl enable --now docker
usermod -aG docker ec2-user || true
