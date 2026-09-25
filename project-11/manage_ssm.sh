
INSTANCE_PROFILE_NAME="ssm-instance-profile-$Purpose"
ROLE_NAME="${ROLE_NAME:-"jenkins-role"}"
DATE="$(date +%Y-%m-%d)"

statefile() {
    cat >> "$STATE_FILE" <<EOF
# $DATE
export INSTANCE_PROFILE_NAME="$INSTANCE_PROFILE_NAME"
export ROLE_NAME="$ROLE_NAME"
EOF
    echo "State saved to $STATE_FILE"
}

[[ -f "$STATE_FILE" ]] || { echo "no state file $STATE_FILE"; exit 1; }
aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || { echo "no IAM role $ROLE_NAME"; exit 1; }

create() {
    echo "=== Creating instance profile ==="

    aws iam create-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --tags "Key=Purpose,Value=$Purpose" \
        --output text >/dev/null

    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME"

    echo "Role:             $ROLE_NAME"
    echo "Instance profile: $INSTANCE_PROFILE_NAME"

    statefile
}

delete() {
    echo "=== Finding resources tagged Purpose=$Purpose ==="

    # --------------------------------------------------
    # Instance profile (iam is global - no --region)
    # --------------------------------------------------

    # inline policies egress/egress-balancer attached to the role so instances can read their
    # Cloudflare tunnel token (lib_cloudflare_tunnel.sh) - scoped to this Purpose, and the role
    # itself is shared (jenkins-role by default), so only these are removed, never the role
    for policy in $(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames' --output text 2>/dev/null); do
        [[ "$policy" == cloudflare-tunnel-"$Purpose"-* ]] || continue
        echo "Removing inline policy from $ROLE_NAME: $policy"
        aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$policy"
    done

    if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
        echo "Removing role from instance profile: $INSTANCE_PROFILE_NAME"

        aws iam remove-role-from-instance-profile \
            --instance-profile-name "$INSTANCE_PROFILE_NAME" \
            --role-name "$ROLE_NAME" 2>/dev/null || true

        echo "Deleting instance profile: $INSTANCE_PROFILE_NAME"

        aws iam delete-instance-profile \
            --instance-profile-name "$INSTANCE_PROFILE_NAME"
    fi

}

case "$2" in
    create)
        create
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh ssm {create|delete}"
        exit 1
        ;;
esac
