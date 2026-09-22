# Builds a custom AMI: launches a temporary "builder" instance from a base AMI, runs a
# provisioning script as user-data (which script depends on ENV_TYPE - see ami-scripts/),
# waits for it to finish, stops the instance for a consistent snapshot, creates a tagged
# image from it, waits for the image to become available, then terminates the builder - the
# AMI is what's kept, not the instance.

source "$STATE_FILE"

[[ "$NAME" =~ ^(create|delete|keys|ssm|network|instances|s3|ami|instance-ami)$ ]] && { echo "error: invalid name '$NAME'" >&2; exit 1; }

ENV_TYPE="${ENV_TYPE:?set ENV_TYPE, e.g. production/staging/dev}"
PROVISION_SCRIPT="${PROVISION_SCRIPT:-ami-scripts/${ENV_TYPE}.sh}"
TIER="${TIER:-app}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
BASE_AMI_ID="${BASE_AMI_ID:-}"

case "$TIER" in
    bastion) SUBNET_ID="$BASTION_SUBNET_ID"; SG_ID="$BASTION_SG" ;;
    app)     SUBNET_ID="$APP_SUBNET_ID";     SG_ID="$APP_SG" ;;
    db)      SUBNET_ID="$DB_SUBNET_ID";      SG_ID="$DB_SG" ;;
    *) echo "error: TIER must be bastion, app or db" >&2; exit 1 ;;
esac

: "${SUBNET_ID:?no subnet for tier=$TIER in $STATE_FILE - run 'run.sh network create' first}"
: "${SG_ID:?no security group for tier=$TIER in $STATE_FILE - run 'run.sh network create' first}"

AMI_KEY="AMI_$(echo "${NAME}_${ENV_TYPE}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"

statefile() {
    {
        echo
        echo "# $NAME ($ENV_TYPE)"
        echo "export AWS_REGION=\"$AWS_REGION\""
        echo "export ${AMI_KEY}_ID=\"$AMI_ID\""
        echo "export ${AMI_KEY}_NAME=\"$AMI_NAME\""
    } >> "$STATE_FILE"

    echo "State appended to $STATE_FILE"
}

create() {
    [[ -f "$PROVISION_SCRIPT" ]] || { echo "error: PROVISION_SCRIPT not found: $PROVISION_SCRIPT" >&2; exit 1; }

    if [[ -z "$BASE_AMI_ID" ]]; then
        echo "BASE_AMI_ID not set - looking up the latest Amazon Linux 2023 AMI for $AWS_REGION"
        BASE_AMI_ID=$(aws ssm get-parameters \
            --region "$AWS_REGION" \
            --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
            --query 'Parameters[0].Value' \
            --output text)
        echo "BASE_AMI_ID: $BASE_AMI_ID"
    fi

    local run_args=(
        --region "$AWS_REGION"
        --image-id "$BASE_AMI_ID"
        --instance-type "$INSTANCE_TYPE"
        --subnet-id "$SUBNET_ID"
        --security-group-ids "$SG_ID"
        --user-data "file://$PROVISION_SCRIPT"
    )
    [[ -n "$DATE_NAME" ]] && run_args+=(--key-name "$DATE_NAME")
    [[ -n "$INSTANCE_PROFILE_NAME" ]] && run_args+=(--iam-instance-profile "Name=$INSTANCE_PROFILE_NAME")


    # --------------------------------------------------
    # Launch the builder
    # --------------------------------------------------

    echo "=== Launching builder instance from $BASE_AMI_ID ==="

    BUILDER_ID=$(aws ec2 run-instances \
        "${run_args[@]}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=ami-builder-$NAME-$ENV_TYPE}]" \
        --query 'Instances[0].InstanceId' \
        --output text)

    echo "Builder instance: $BUILDER_ID"
    echo "waiting for it to be running..."
    aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$BUILDER_ID"


    # --------------------------------------------------
    # Wait for the provisioning script (user-data) to finish
    # --------------------------------------------------
    # cloud-init runs user-data asynchronously after boot - `instance-running` only means the
    # instance answered, not that provisioning is done. `cloud-init status --wait` blocks
    # until it actually is; run it over SSM and poll for up to 5 minutes, same pattern
    # bun-hydrate's Jenkinsfile already uses for its own SSM command polling.

    echo "=== Waiting for provisioning to finish ==="

    COMMAND_ID=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$BUILDER_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["cloud-init status --wait"]' \
        --query 'Command.CommandId' --output text)

    STATUS=""
    for i in $(seq 1 60); do
        STATUS=$(aws ssm list-command-invocations \
            --region "$AWS_REGION" \
            --command-id "$COMMAND_ID" \
            --query 'CommandInvocations[0].Status' --output text 2>/dev/null)
        case "$STATUS" in
            Pending|InProgress|""|None) sleep 5 ;;
            *) break ;;
        esac
    done

    if [[ "$STATUS" != "Success" ]]; then
        echo "error: provisioning did not succeed on $BUILDER_ID (status=$STATUS) - leaving it running for inspection" >&2
        exit 1
    fi
    echo "provisioning finished"


    # --------------------------------------------------
    # Stop for a consistent snapshot, then image it
    # --------------------------------------------------

    echo "=== Stopping builder for a consistent snapshot ==="

    aws ec2 stop-instances --region "$AWS_REGION" --instance-ids "$BUILDER_ID" >/dev/null
    aws ec2 wait instance-stopped --region "$AWS_REGION" --instance-ids "$BUILDER_ID"

    AMI_NAME="${Purpose}-${NAME}-${ENV_TYPE}-$(date +%Y%m%d%H%M%S)"

    echo "=== Creating image $AMI_NAME ==="

    AMI_ID=$(aws ec2 create-image \
        --region "$AWS_REGION" \
        --instance-id "$BUILDER_ID" \
        --name "$AMI_NAME" \
        --description "Built by manage_ami.sh for $NAME/$ENV_TYPE, Purpose=$Purpose" \
        --tag-specifications \
            "ResourceType=image,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$NAME},{Key=Environment,Value=$ENV_TYPE}]" \
            "ResourceType=snapshot,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$NAME},{Key=Environment,Value=$ENV_TYPE}]" \
        --query 'ImageId' --output text)

    echo "waiting for $AMI_ID to become available (this can take a few minutes)..."
    aws ec2 wait image-available --region "$AWS_REGION" --image-ids "$AMI_ID"


    # --------------------------------------------------
    # The AMI is the product - the builder isn't needed anymore
    # --------------------------------------------------

    echo "=== Terminating builder instance ==="
    aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$BUILDER_ID" >/dev/null


    # --------------------------------------------------
    # Summary
    # --------------------------------------------------

    echo
    echo "========================================"
    echo "AMI built"
    echo "========================================"
    echo "AMI ID:      $AMI_ID"
    echo "AMI name:    $AMI_NAME"
    echo "Environment: $ENV_TYPE"
    echo "========================================"

    statefile
}

delete() {
    echo "=== Finding AMIs tagged Purpose=$Purpose, Name=$NAME, Environment=$ENV_TYPE ==="

    AMI_IDS=$(aws ec2 describe-images \
        --region "$AWS_REGION" \
        --owners self \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$NAME" "Name=tag:Environment,Values=$ENV_TYPE" \
        --query 'Images[*].ImageId' \
        --output text)

    if [[ -z "$AMI_IDS" ]]; then
        echo "no matching AMIs"
        return
    fi

    for ami_id in $AMI_IDS; do
        # snapshots have to be looked up before deregistering - the image metadata that
        # points to them disappears the moment deregister-image runs
        SNAPSHOT_IDS=$(aws ec2 describe-images \
            --region "$AWS_REGION" \
            --image-ids "$ami_id" \
            --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' \
            --output text)

        echo "Deregistering AMI: $ami_id"
        aws ec2 deregister-image --region "$AWS_REGION" --image-id "$ami_id"

        for snap_id in $SNAPSHOT_IDS; do
            [[ -n "$snap_id" && "$snap_id" != "None" ]] || continue
            echo "Deleting snapshot: $snap_id"
            aws ec2 delete-snapshot --region "$AWS_REGION" --snapshot-id "$snap_id"
        done
    done

    echo "=== Cleanup complete ==="
    echo "note: $STATE_FILE is an append-only log - these AMIs' entries stay there for history"
}

case "$4" in
    create)
        create
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh ami <name> <env-type> {create|delete}"
        exit 1
        ;;
esac
