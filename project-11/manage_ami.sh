# Builds a custom AMI with Packer instead of hand-rolled EC2 API calls: packer/ami.pkr.hcl
# owns the actual build mechanics (launch, wait for SSH, run the provisioner, snapshot, tag,
# tear down its own temporary keypair and the builder instance) - this script resolves the
# inputs from $STATE_FILE, drives `packer init/validate/build`, and reads the resulting AMI
# ID back out of Packer's manifest to append to state. delete() is unchanged from before:
# Packer builds, it doesn't manage teardown of what it built, so cleanup stays plain aws cli.

source "$STATE_FILE"

[[ "$NAME" =~ ^(create|delete|keys|ssm|network|instances|s3|ami|instance-ami|egress)$ ]] && { echo "error: invalid name '$NAME'" >&2; exit 1; }

ENV_TYPE="${ENV_TYPE:?set ENV_TYPE, e.g. production/staging/dev}"
PROVISION_SCRIPT="${PROVISION_SCRIPT:-ami-scripts/${ENV_TYPE}.sh}"
TIER="${TIER:-app}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
BASE_AMI_ID="${BASE_AMI_ID:-}"
ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-true}"

PACKER_DIR="packer"
MANIFEST_FILE="$PACKER_DIR/packer-manifest.json"

case "$TIER" in
    bastion) SUBNET_ID="$BASTION_SUBNET_ID"; SG_ID="$BASTION_SG" ;;
    app)     SUBNET_ID="$APP_SUBNET_ID";     SG_ID="$APP_SG" ;;
    db)      SUBNET_ID="$DB_SUBNET_ID";      SG_ID="$DB_SG" ;;
    egress)  SUBNET_ID="$EGRESS_SUBNET_ID"; SG_ID="$EGRESS_SG" ;;
    *) echo "error: TIER must be bastion, app, db or egress" >&2; exit 1 ;;
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
    command -v packer >/dev/null 2>&1 || { echo "error: packer not found - https://developer.hashicorp.com/packer/install" >&2; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "error: jq not found - needed to read packer's manifest" >&2; exit 1; }

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


    # --------------------------------------------------
    # Preflight: Packer connects over plain SSH, so the chosen tier's security group needs
    # to actually allow it in - manage_network.sh creates all three tiers with zero rules,
    # so this is very likely the first thing to trip someone up. Warn, don't block - there
    # are legitimate reasons this check could be wrong (a broader rule that isn't an exact
    # port-22 match, SSH allowed by a different mechanism entirely).
    # --------------------------------------------------

    SSH_RULE_COUNT=$(aws ec2 describe-security-group-rules \
        --region "$AWS_REGION" \
        --filters "Name=group-id,Values=$SG_ID" \
        --query "length(SecurityGroupRules[?IsEgress==\`false\` && FromPort==\`22\`])" \
        --output text 2>/dev/null)

    if [[ "$SSH_RULE_COUNT" == "0" ]]; then
        echo "warning: $SG_ID has no inbound rule for port 22 - Packer's SSH connection to the" >&2
        echo "builder will hang until it times out. Add one first, e.g.:" >&2
        echo "  ../project-10/security-groups/scripts/add-rule.sh --sg $SG_ID --direction ingress \\" >&2
        echo "      --protocol tcp --port 22 --cidr <your-ip>/32" >&2
    fi

    # a public IP only works if the subnet's own default route goes to the Internet Gateway -
    # AWS's 1:1 NAT for a public IP has nothing to translate through if 0.0.0.0/0 instead points
    # at an egress gateway instance (run.sh egress). Easy to hit by accident: TIER defaults to
    # app, and that's exactly the subnet `run.sh egress` relays through by default.
    if [[ "$ASSIGN_PUBLIC_IP" == "true" ]]; then
        DEFAULT_ROUTE_GW=$(aws ec2 describe-route-tables \
            --region "$AWS_REGION" \
            --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
            --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
            --output text 2>/dev/null)

        if [[ -z "$DEFAULT_ROUTE_GW" || "$DEFAULT_ROUTE_GW" == "None" || "$DEFAULT_ROUTE_GW" != igw-* ]]; then
            echo "warning: tier=$TIER's subnet ($SUBNET_ID) default route doesn't go to an Internet" >&2
            echo "Gateway - it's likely relayed through an egress gateway instance instead. Packer's" >&2
            echo "SSH connection to the builder's public IP will hang, same as if it had none. Build" >&2
            echo "in a tier that still routes to the IGW directly, e.g.:" >&2
            echo "  TIER=bastion run.sh ami $NAME $ENV_TYPE create" >&2
        fi
    fi


    # --------------------------------------------------
    # Build
    # --------------------------------------------------

    local packer_vars=(
        -var "aws_region=$AWS_REGION"
        -var "purpose=$Purpose"
        -var "name=$NAME"
        -var "env_type=$ENV_TYPE"
        -var "provision_script=$(cd "$(dirname "$PROVISION_SCRIPT")" && pwd)/$(basename "$PROVISION_SCRIPT")"
        -var "base_ami_id=$BASE_AMI_ID"
        -var "subnet_id=$SUBNET_ID"
        -var "security_group_id=$SG_ID"
        -var "instance_type=$INSTANCE_TYPE"
        -var "assign_public_ip=$ASSIGN_PUBLIC_IP"
        -var "instance_profile_name=$INSTANCE_PROFILE_NAME"
    )

    echo "=== packer init ==="
    packer init "$PACKER_DIR" || exit 1

    echo "=== packer validate ==="
    packer validate "${packer_vars[@]}" "$PACKER_DIR" || exit 1

    echo "=== packer build ==="
    rm -f "$MANIFEST_FILE"

    # the manifest post-processor's `output` is resolved relative to whatever directory
    # `packer build` is invoked FROM, not the template directory it's pointed at - cd into
    # $PACKER_DIR so the manifest lands at $MANIFEST_FILE like the rest of this script assumes,
    # instead of one level up in $PACKER_DIR's parent.
    (cd "$PACKER_DIR" && packer build "${packer_vars[@]}" .) || exit 1

    [[ -f "$MANIFEST_FILE" ]] || { echo "error: packer build did not produce $MANIFEST_FILE" >&2; exit 1; }


    # --------------------------------------------------
    # Read the result back out of Packer's manifest, not its stdout
    # --------------------------------------------------

    AMI_ID=$(jq -r '.builds[-1].artifact_id' "$MANIFEST_FILE" | cut -d: -f2)
    AMI_NAME=$(jq -r '.builds[-1].custom_data.ami_name // empty' "$MANIFEST_FILE")

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
