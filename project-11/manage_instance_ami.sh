# Launches EC2 instances from a custom AMI built by `run.sh ami <name> <env-type> create` -
# looked up in $STATE_FILE by that same <name>/<env-type> pair, instead of
# manage_instances.sh's default latest-Amazon-Linux-2023 lookup. Same subnet/security
# group/key/instance-profile wiring as manage_instances.sh otherwise.

source "$STATE_FILE"

[[ "$NAME" =~ ^(create|delete|keys|ssm|network|instances|s3|ami|instance-ami|egress)$ ]] && { echo "error: invalid name '$NAME'" >&2; exit 1; }
[[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -ge 1 ] || { echo "error: count must be a positive integer" >&2; exit 1; }

ENV_TYPE="${ENV_TYPE:?set ENV_TYPE, matching what you built with 'run.sh ami'}"
TIER="${TIER:-app}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
ROLE="${ROLE:-}"

AMI_KEY="AMI_$(echo "${NAME}_${ENV_TYPE}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
AMI_ID_VAR="${AMI_KEY}_ID"
AMI_ID="${!AMI_ID_VAR}"

: "${AMI_ID:?no AMI found for name=$NAME env-type=$ENV_TYPE in $STATE_FILE - run 'run.sh ami $NAME $ENV_TYPE create' first}"

case "$TIER" in
    bastion) SUBNET_ID="$BASTION_SUBNET_ID"; SG_ID="$BASTION_SG" ;;
    app)     SUBNET_ID="$APP_SUBNET_ID";     SG_ID="$APP_SG" ;;
    db)      SUBNET_ID="$DB_SUBNET_ID";      SG_ID="$DB_SG" ;;
    egress)  SUBNET_ID="$EGRESS_SUBNET_ID"; SG_ID="$EGRESS_SG" ;;
    *) echo "error: TIER must be bastion, app, db or egress" >&2; exit 1 ;;
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
        echo "# $INSTANCE_NAME (from AMI $AMI_ID)"
        echo "export AWS_REGION=\"$AWS_REGION\""
        echo "export ${var_prefix}_ID=\"$INSTANCE_ID\""
        echo "export ${var_prefix}_AMI_ID=\"$AMI_ID\""
        echo "export ${var_prefix}_TIER=\"$TIER\""
        echo "export ${var_prefix}_PUBLIC_IP=\"$PUBLIC_IP\""
        echo "export ${var_prefix}_PRIVATE_IP=\"$PRIVATE_IP\""
    } >> "$STATE_FILE"

    echo "State appended to $STATE_FILE"
}

create() {
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
        INSTANCE_NAME="${NAME}-${ENV_TYPE}-${i}"

        echo "=== Launching $INSTANCE_NAME from $AMI_ID (tier=$TIER) ==="

        TAGS="{Key=Purpose,Value=$Purpose},{Key=Name,Value=$INSTANCE_NAME},{Key=Tier,Value=$TIER},{Key=Environment,Value=$ENV_TYPE}"
        [[ -n "$ROLE" ]] && TAGS="$TAGS,{Key=Role,Value=$ROLE}"

        INSTANCE_ID=$(aws ec2 run-instances \
            "${run_args[@]}" \
            --tag-specifications "ResourceType=instance,Tags=[$TAGS]" \
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
    echo "$COUNT instance(s) launched from $AMI_ID under '$NAME' ($ENV_TYPE, tier=$TIER)"
    echo "========================================"
}

delete() {
    echo "=== Finding instances tagged Purpose=$Purpose, Name=${NAME}-${ENV_TYPE}-* ==="

    INSTANCE_IDS=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=${NAME}-${ENV_TYPE}-*" \
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

case "$5" in
    create)
        create
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh instance-ami <name> <env-type> <count> {create|delete}"
        exit 1
        ;;
esac
