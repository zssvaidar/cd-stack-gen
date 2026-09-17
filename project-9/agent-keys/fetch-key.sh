#!/usr/bin/env bash
# Fetches a previously generated agent keypair's private key from Vault into a local file.
# Used by ec2-deploy/Jenkinsfile at deploy time (so the key never sits in Jenkins as a
# static credential) and can be used the same way for a manual ssh.
#
# Usage: ./fetch-key.sh <date_name> [output_path]   (output_path defaults to ./agent_key)
# Required: vault CLI logged in (VAULT_ADDR + token/approle already set up)
# Optional env vars: VAULT_KV_PATH (default secret/ec2-agents)
set -euo pipefail

DATE_NAME="${1:?usage: fetch-key.sh <date_name> [output_path]}"
OUTPUT_PATH="${2:-./agent_key}"
VAULT_KV_PATH="${VAULT_KV_PATH:-secret/ec2-agents}"

vault kv get -field=private_key "$VAULT_KV_PATH/$DATE_NAME" > "$OUTPUT_PATH"
chmod 600 "$OUTPUT_PATH"

echo "wrote private key for $DATE_NAME to $OUTPUT_PATH"
