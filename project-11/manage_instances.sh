# EC2 instances launched into the network/keys/ssm resources already in $STATE_FILE - source
# it first so DATE_NAME (from `run.sh keys`), INSTANCE_PROFILE_NAME (from `run.sh ssm`), and
# the VPC's subnets/security groups (from `run.sh network`) are all in scope without
# re-specifying any of them by hand. If keys/network/ssm were each run more than once under
# this Purpose, sourcing the whole log leaves whatever each one's *last* entry set - same
# "latest wins" behavior as manage_keys.sh's own delete().

source "$STATE_FILE"

[[ "$NAME" =~ ^(create|delete|keys|ssm|network|instances)$ ]] && { echo "error: invalid name '$NAME'" >&2; exit 1; }
[[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -ge 1 ] || { echo "error: count must be a positive integer" >&2; exit 1; }

TIER="${TIER:-app}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
AMI_ID="${AMI_ID:-}"

case "$TIER" in
    bastion) SUBNET_ID="$BASTION_SUBNET_ID"; SG_ID="$BASTION_SG" ;;
    app)     SUBNET_ID="$APP_SUBNET_ID";     SG_ID="$APP_SG" ;;
    db)      SUBNET_ID="$DB_SUBNET_ID";      SG_ID="$DB_SG" ;;
    *) echo "error: TIER must be bastion, app or db" >&2; exit 1 ;;
esac

: "${SUBNET_ID:?no subnet for tier=$TIER in $STATE_FILE - run 'run.sh network create' first}"
: "${SG_ID:?no security group for tier=$TIER in $STATE_FILE - run 'run.sh network create' first}"

[[ -n "$DATE_NAME" ]] || echo "warning: no DATE_NAME in $STATE_FILE - launching without a key pair (run 'run.sh keys <name> create' for SSH access)"
[[ -n "$INSTANCE_PROFILE_NAME" ]] || echo "warning: no INSTANCE_PROFILE_NAME in $STATE_FILE - launching without SSM access (run 'run.sh ssm create' first)"

statefile() {
    local var_prefix
    var_prefix="INSTANCE_$(echo "$INSTANCE_NAME" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"

    {
        echo
        echo "# $INSTANCE_NAME"
        echo "export AWS_REGION=\"$AWS_REGION\""
        echo "export ${var_prefix}_ID=\"$INSTANCE_ID\""
        echo "export ${var_prefix}_TIER=\"$TIER\""
        echo "export ${var_prefix}_PUBLIC_IP=\"$PUBLIC_IP\""
        echo "export ${var_prefix}_PRIVATE_IP=\"$PRIVATE_IP\""
    } >> "$STATE_FILE"

    echo "State appended to $STATE_FILE"
}

create() {
    if [[ -z "$AMI_ID" ]]; then
        echo "AMI_ID not set - looking up the latest Amazon Linux 2023 AMI for $AWS_REGION"
        AMI_ID=$(aws ssm get-parameters \
            --region "$AWS_REGION" \
            --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
            --query 'Parameters[0].Value' \
            --output text)
        echo "AMI_ID: $AMI_ID"
    fi

    local run_args=(
        --region "$AWS_REGION"
        --image-id "$AMI_ID"
        --instance-type "$INSTANCE_TYPE"
        --subnet-id "$SUBNET_ID"
        --security-group-ids "$SG_ID"
    )
    [[ -n "$DATE_NAME" ]] && run_args+=(--key-name "$DATE_NAME")
    [[ -n "$INSTANCE_PROFILE_NAME" ]] && run_args+=(--iam-instance-profile "Name=$INSTANCE_PROFILE_NAME")

    for i in $(seq 1 "$COUNT"); do
        INSTANCE_NAME="${NAME}-${i}"

        echo "=== Launching $INSTANCE_NAME (tier=$TIER) ==="

        INSTANCE_ID=$(aws ec2 run-instances \
            "${run_args[@]}" \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$INSTANCE_NAME},{Key=Tier,Value=$TIER}]" \
            --query 'Instances[0].InstanceId' \
            --output text)

        echo "waiting for $INSTANCE_ID to be running..."
        aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"

        PUBLIC_IP=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
        PRIVATE_IP=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

        echo "$INSTANCE_NAME: $INSTANCE_ID  public=$PUBLIC_IP  private=$PRIVATE_IP"

        statefile
    done

    echo
    echo "========================================"
    echo "$COUNT instance(s) launched under '$NAME' (tier=$TIER)"
    echo "========================================"
}

delete() {
    echo "=== Finding instances tagged Purpose=$Purpose, Name=${NAME}-* ==="

    INSTANCE_IDS=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=${NAME}-*" \
                   "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text)

    if [[ -z "$INSTANCE_IDS" ]]; then
        echo "no matching instances"
        return
    fi

    echo "Terminating: $INSTANCE_IDS"
    aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids $INSTANCE_IDS >/dev/null

    echo "waiting for termination..."
    aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids $INSTANCE_IDS

    echo "=== Cleanup complete ==="
    echo "note: $STATE_FILE is an append-only log - these instances' entries stay there for history"
}

case "$4" in
    create)
        create
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh instances <name> <count> {create|delete}"
        exit 1
        ;;
esac
