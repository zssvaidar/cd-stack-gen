#!/usr/bin/env bash
# ln -s ../wrapper wrapper

set -euo pipefail

source "wrapper/common/init.sh"
source "wrapper/config/.env"

unset_aws
set_root
whoami

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
Purpose="${PURPOSE:-testing}"
VAULT_KV_PATH="${VAULT_KV_PATH:-secret/ec2-agents}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/state/$Purpose.env"

# unlike the one-shot state files elsewhere in this stack (one VPC, one role - overwritten
# each run), this one is a log: a single Purpose can hold many keypairs over time (one per
# agent), so each create appends a new block instead of replacing the file. Plain `>>`
# already creates the file if it doesn't exist yet, so "create if missing, append if not"
# falls out for free - no separate branch needed.
statefile() {
    mkdir -p "$(dirname "$STATE_FILE")"

    # DATE_NAME contains dashes and starts with a digit - neither is legal in a bash
    # identifier, so give each entry's exports a distinct, name-safe prefix instead of
    # reusing plain KEY_DIR/DATE_NAME (which would just get clobbered by the next append).
    local var_prefix
    var_prefix="AGENT_$(echo "$DATE_NAME" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"

    {
        echo
        echo "# $DATE_NAME"
        echo "export AWS_REGION=\"$AWS_REGION\""
        echo "export ${var_prefix}_DATE_NAME=\"$DATE_NAME\""
        echo "export ${var_prefix}_KEY_DIR=\"$KEY_DIR\""
        echo "export ${var_prefix}_VAULT_PATH=\"$VAULT_KV_PATH/$DATE_NAME\""
    } >> "$STATE_FILE"

    echo "State appended to $STATE_FILE"
}


create() {
    local name="$1"
    DATE_NAME="$(date +%Y-%m-%d)_${name}"
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
        --public-key-material "fileb://$KEY_DIR/keys.pub" \
        --tag-specifications "ResourceType=key-pair,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$DATE_NAME}]"

    echo "storing keypair in vault at $VAULT_KV_PATH/$DATE_NAME"
    vault kv put "$VAULT_KV_PATH/$DATE_NAME" \
        private_key=@"$KEY_DIR/keys" \
        public_key=@"$KEY_DIR/keys.pub" \
        purpose="$Purpose"

    echo
    echo "$DATE_NAME"
    echo "  local:  $KEY_DIR/keys{,.pub}"
    echo "  aws:    key pair '$DATE_NAME' in $AWS_REGION (Purpose=$Purpose)"
    echo "  vault:  $VAULT_KV_PATH/$DATE_NAME (private_key, public_key, purpose)"

    statefile
}


destroy() {
    local date_name="$1"
    local key_dir="$SCRIPT_DIR/credentials/$date_name"

    echo "=== Destroying $date_name ==="

    if [[ -d "$key_dir" ]]; then
        echo "Removing local keys: $key_dir"
        rm -rf "$key_dir"
    fi

    if aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$date_name" >/dev/null 2>&1; then
        echo "Deleting AWS key pair: $date_name"
        aws ec2 delete-key-pair --region "$AWS_REGION" --key-name "$date_name"
    fi

    echo "Deleting vault secret: $VAULT_KV_PATH/$date_name"
    vault kv metadata delete "$VAULT_KV_PATH/$date_name" 2>/dev/null || true

    echo "=== Cleanup complete ==="
    echo "note: $STATE_FILE is an append-only log - $date_name's entry stays there for history"
}


# ------------------------------------------------------
# Command
# ------------------------------------------------------
# Usage:
#   PURPOSE=web ./generate-and-store.sh create web-host    -> 2026-09-17_web-host
#   PURPOSE=web ./generate-and-store.sh destroy 2026-09-17_web-host

case "${1:-}" in
    create)
        create "${2:?usage: $0 create <name>}"
        ;;
    destroy)
        destroy "${2:?usage: $0 destroy <date_name>}"
        ;;
    *)
        echo "Usage: $0 {create <name>|destroy <date_name>}"
        exit 1
        ;;
esac
