#!/usr/bin/env bash
# Generates a new SSH keypair for an EC2 deploy target, saves it locally under
# credentials/<date_name>/keys{,.pub}, imports the public half into AWS as an EC2 key pair,
# and writes both halves into Vault so Jenkins can fetch the private key at deploy time
# instead of it living as a static Jenkins credential.
#
# Usage: ./generate-and-store.sh <name>
# Produces DATE_NAME = <YYYY-MM-DD>_<name>, e.g. 2026-09-17_web-host — use that value as
# KEY_NAME for ec2-deploy/bootstrap/provision-ec2.sh and as DATE_NAME for ec2-deploy/Jenkinsfile.
#
# Required: vault CLI logged in (VAULT_ADDR + token/approle already set up, same as the rest
#           of this stack), aws CLI configured with permission to import key pairs.
# Optional env vars: AWS_REGION (default ap-northeast-1), VAULT_KV_PATH (default secret/ec2-agents)
set -euo pipefail

NAME="${1:?usage: generate-and-store.sh <name>}"
DATE_NAME="$(date +%Y-%m-%d)_${NAME}"

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
VAULT_KV_PATH="${VAULT_KV_PATH:-secret/ec2-agents}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_DIR="$SCRIPT_DIR/credentials/$DATE_NAME"

if [[ -e "$KEY_DIR" ]]; then
    echo "$KEY_DIR already exists - pick a different name, or remove it first" >&2
    exit 1
fi
mkdir -p "$KEY_DIR"

if ! ssh-keygen -t ed25519 -f "$KEY_DIR/keys" -N "" -C "$DATE_NAME"; then
    rmdir "$KEY_DIR" 2>/dev/null || true
    exit 1
fi
chmod 600 "$KEY_DIR/keys"
chmod 644 "$KEY_DIR/keys.pub"

echo "importing keypair into AWS ($AWS_REGION) as $DATE_NAME"
aws ec2 import-key-pair \
    --region "$AWS_REGION" \
    --key-name "$DATE_NAME" \
    --public-key-material "fileb://$KEY_DIR/keys.pub"

echo "storing keypair in vault at $VAULT_KV_PATH/$DATE_NAME"
vault kv put "$VAULT_KV_PATH/$DATE_NAME" \
    private_key=@"$KEY_DIR/keys" \
    public_key=@"$KEY_DIR/keys.pub"

echo
echo "$DATE_NAME"
echo "  local:  $KEY_DIR/keys{,.pub}"
echo "  aws:    key pair '$DATE_NAME' in $AWS_REGION"
echo "  vault:  $VAULT_KV_PATH/$DATE_NAME (private_key, public_key)"
