#!/bin/bash
# Docker host running HashiCorp Vault in a container, with S3 as Vault's storage backend and AWS
# KMS auto-unseal. Built by project-13's live/shared/ami-docker-vault, launched by
# modules/vault (live/<env>/vault).
#
# Baked in: Docker, the Vault image (pinned by digest, pulled now so instances never need Docker
# Hub), vault.service, the config renderer and a `vault` CLI wrapper. NOT baked in: anything
# per-deployment. At boot the instance needs /etc/vault/vault.env - written by user-data:
#
#   VAULT_S3_BUCKET=<bucket>     Vault's storage
#   VAULT_KMS_KEY_ID=<key id>    auto-unseal key
#   AWS_REGION=<region>
#
# Credentials for both come from the instance role (IMDSv2) - no keys anywhere on disk. The TLS
# certificate is self-signed and generated on first boot, per instance (SANs: its private IP,
# 127.0.0.1, localhost), so no private key is ever baked into the AMI.
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

retry_pkg dnf install -y docker openssl
systemctl enable --now docker.service


# --------------------------------------------------
# Vault image - pinned by digest (the multi-arch index), bump tag and digest together:
#   curl -s https://hub.docker.com/v2/repositories/hashicorp/vault/tags/<tag> | jq -r .digest
# --------------------------------------------------

VAULT_IMAGE="hashicorp/vault:2.1.2@sha256:c2f666266f383d2cf424d86b8bb8ce7d065562173ffec2b476d762943608bb55"

n=0
until docker pull "$VAULT_IMAGE"; do
    n=$((n + 1))
    [[ "$n" -ge 5 ]] && { echo "docker_vault.sh: can't pull $VAULT_IMAGE" >&2; exit 1; }
    sleep 5
done

# the image runs Vault as its own `vault` user - files mounted into the container (TLS key,
# config) have to be readable by that uid, so record it instead of assuming a number
VAULT_UID=$(docker run --rm --entrypoint id "$VAULT_IMAGE" -u vault)
VAULT_GID=$(docker run --rm --entrypoint id "$VAULT_IMAGE" -g vault)

mkdir -p /etc/vault/config /etc/vault/tls
cat > /etc/vault/image.env <<EOF
VAULT_IMAGE=$VAULT_IMAGE
VAULT_UID=$VAULT_UID
VAULT_GID=$VAULT_GID
EOF


# --------------------------------------------------
# Config renderer - runs before every start (ExecStartPre), so a changed vault.env takes effect
# on restart. Writes /etc/vault/config/vault.hcl and, once, the TLS certificate.
# --------------------------------------------------

cat > /usr/local/sbin/vault-render.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail

[[ -f /etc/vault/vault.env ]] || { echo "vault-render: /etc/vault/vault.env missing - set by user-data (see docker_vault.sh)" >&2; exit 1; }
source /etc/vault/image.env
source /etc/vault/vault.env
: "${VAULT_S3_BUCKET:?vault-render: VAULT_S3_BUCKET not set in /etc/vault/vault.env}"
: "${VAULT_KMS_KEY_ID:?vault-render: VAULT_KMS_KEY_ID not set in /etc/vault/vault.env}"
: "${AWS_REGION:?vault-render: AWS_REGION not set in /etc/vault/vault.env}"

if [[ -z "${VAULT_PRIVATE_IP:-}" ]]; then
    token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
    VAULT_PRIVATE_IP=$(curl -fsS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/local-ipv4)
fi

tls=/etc/vault/tls
if [[ ! -s $tls/vault.key ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825 \
        -keyout $tls/vault.key -out $tls/vault.crt -subj "/CN=vault" \
        -addext "subjectAltName=IP:$VAULT_PRIVATE_IP,IP:127.0.0.1,DNS:localhost" 2>/dev/null
    echo "vault-render: generated self-signed certificate for $VAULT_PRIVATE_IP"
fi
chown "$VAULT_UID:$VAULT_GID" $tls/vault.key $tls/vault.crt
chmod 0400 $tls/vault.key
chmod 0444 $tls/vault.crt

cat > /etc/vault/config/vault.hcl <<EOF
storage "s3" {
  bucket = "$VAULT_S3_BUCKET"
  region = "$AWS_REGION"
}

seal "awskms" {
  region     = "$AWS_REGION"
  kms_key_id = "$VAULT_KMS_KEY_ID"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/vault/tls/vault.crt"
  tls_key_file  = "/vault/tls/vault.key"
}

api_addr = "https://$VAULT_PRIVATE_IP:8200"
ui       = true
EOF
chown "$VAULT_UID:$VAULT_GID" /etc/vault/config/vault.hcl
chmod 0444 /etc/vault/config/vault.hcl
SCRIPT
chmod 0755 /usr/local/sbin/vault-render.sh


# --------------------------------------------------
# vault.service - the container, host networking (Vault's own :8200, and IMDS reachable with the
# instance's hop limit of 1, which a bridge network would exceed), IPC_LOCK so Vault can mlock.
# --------------------------------------------------

cat > /etc/systemd/system/vault.service <<'EOF'
[Unit]
Description=HashiCorp Vault (docker)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
EnvironmentFile=/etc/vault/image.env
ExecStartPre=/usr/local/sbin/vault-render.sh
ExecStartPre=-/usr/bin/docker rm -f vault
ExecStart=/usr/bin/docker run --rm --name vault --network host --cap-add IPC_LOCK \
    -e SKIP_CHOWN=true \
    -v /etc/vault/config:/vault/config:ro \
    -v /etc/vault/tls:/vault/tls:ro \
    ${VAULT_IMAGE} server
ExecStop=/usr/bin/docker stop vault
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vault.service


# --------------------------------------------------
# `vault ...` on the host = the CLI inside the container, already pointed at this server. In
# /usr/bin, not /usr/local/bin: it needs sudo (docker exec), and sudo's secure_path skips /usr/local.
# --------------------------------------------------

cat > /usr/bin/vault <<'EOF'
#!/bin/bash
tty=-i
[[ -t 0 && -t 1 ]] && tty=-it
exec docker exec $tty \
    -e VAULT_ADDR=https://127.0.0.1:8200 \
    -e VAULT_CACERT=/vault/tls/vault.crt \
    ${VAULT_TOKEN:+-e VAULT_TOKEN="$VAULT_TOKEN"} \
    vault vault "$@"
EOF
chmod 0755 /usr/bin/vault


# --------------------------------------------------
# Smoke test: the image runs and serves (in -dev mode - the real config needs the bucket/key that
# only exist per deployment), and the renderer produces a config Vault accepts. Then remove every
# trace, so each instance generates its own certificate and config.
# --------------------------------------------------

docker run --rm "$VAULT_IMAGE" version

docker run -d --name vault-smoke --network host --cap-add IPC_LOCK \
    -e VAULT_DEV_ROOT_TOKEN_ID=smoke -e VAULT_DEV_LISTEN_ADDRESS=127.0.0.1:18200 \
    "$VAULT_IMAGE" server -dev >/dev/null
ok=false
for _ in $(seq 1 15); do
    if docker exec -e VAULT_ADDR=http://127.0.0.1:18200 vault-smoke vault status >/dev/null 2>&1; then ok=true; break; fi
    sleep 2
done
docker rm -f vault-smoke >/dev/null
$ok || { echo "docker_vault.sh: smoke test failed - vault container didn't come up" >&2; exit 1; }

cat > /etc/vault/vault.env <<'EOF'
VAULT_S3_BUCKET=smoke-test-bucket
VAULT_KMS_KEY_ID=00000000-0000-0000-0000-000000000000
AWS_REGION=ap-northeast-1
EOF
/usr/local/sbin/vault-render.sh
grep -q 'bucket = "smoke-test-bucket"' /etc/vault/config/vault.hcl \
    && openssl x509 -in /etc/vault/tls/vault.crt -noout -ext subjectAltName | grep -q 'IP Address:127.0.0.1' \
    || { echo "docker_vault.sh: renderer didn't produce the expected config/certificate" >&2; exit 1; }
rm -f /etc/vault/vault.env /etc/vault/config/vault.hcl /etc/vault/tls/vault.key /etc/vault/tls/vault.crt

echo "docker_vault.sh: smoke test passed - vault image runs, config renders"
