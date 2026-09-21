export VAULT_ADDR="http://127.0.0.1:8200"


VAULT_KV_PATH="${VAULT_KV_PATH:-secret/jenkins}"
SCRIPT_DIR=$(pwd)

[[ "$NAME" =~ ^(create|delete|keys|ssm|network|instances|s3)$ ]] && { echo "error: invalid name '$NAME'" >&2; exit 1; }
[[ -f "$STATE_FILE" ]] || { echo "no state file $STATE_FILE"; exit 1; }

statefile() {
    {
        echo
        echo "# $DATE_NAME"
        echo "export AWS_REGION=\"$AWS_REGION\""
        echo "export DATE_NAME=\"$DATE_NAME\""
        echo "export VAULT_PATH=\"$VAULT_KV_PATH/$DATE_NAME\""
    } >> "$STATE_FILE"

    echo "State appended to $STATE_FILE"
}


create() {
    echo "=== Creating ssh keys ==="

    DATE_NAME="$(date +%Y-%m-%d)_${NAME}"
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
        public_key=@"$KEY_DIR/keys.pub"

    echo
    echo "$DATE_NAME"
    echo "  local:  $KEY_DIR/keys{,.pub}"
    echo "  aws:    key pair '$DATE_NAME' in $AWS_REGION (Purpose=$Purpose)"
    echo "  vault:  $VAULT_KV_PATH/$DATE_NAME (private_key, public_key)"

    statefile
}

delete() {

    source $STATE_FILE

    echo $AWS_REGION $DATE_NAME $VAULT_PATH

    local key_dir="$SCRIPT_DIR/credentials/$DATE_NAME"

    if [[ -d "$key_dir" ]]; then
        echo "Removing local keys: $key_dir"
        rm -rf "$key_dir"
    fi

    if aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$DATE_NAME" >/dev/null 2>&1; then
        echo "Deleting AWS key pair: $DATE_NAME"
        aws ec2 delete-key-pair --region "$AWS_REGION" --key-name "$DATE_NAME"
    fi

    echo "Deleting vault secret: $VAULT_KV_PATH/$DATE_NAME"
    vault kv metadata delete "$VAULT_KV_PATH/$DATE_NAME" 2>/dev/null || true

    echo "=== Cleanup complete ==="
    echo "note: $STATE_FILE is an append-only log - $DATE_NAME's entry stays there for history"
}

case "$3" in
    create)
        create
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh keys <name> {create|delete}"
        exit 1
        ;;
esac
