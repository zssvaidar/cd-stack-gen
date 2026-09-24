# Launches a small public EC2 instance as a self-managed NAT instance - a cheap, DIY stand-in
# for a NAT Gateway. manage_network.sh's app/db subnets have a route to the Internet Gateway
# but no public IP and no NAT, so they have no way to actually reach it; this instance sits in
# a public subnet with a public IP, and create() rewires the relayed subnets' route table so
# their 0.0.0.0/0 traffic goes to this instance instead. The instance itself is built from a
# custom AMI (`run.sh ami <ami-name> egress-gateway create` - see ami-scripts/egress-gateway.sh)
# that already has IP forwarding and NAT baked in; this script only handles what has to happen
# at launch time: disabling source/dest check (required for any instance to route traffic that
# isn't addressed to itself) and pointing the relay subnets at it.

source "$STATE_FILE"

[[ "$NAME" =~ ^(create|delete|keys|ssm|network|instances|s3|ami|instance-ami|egress)$ ]] && { echo "error: invalid name '$NAME'" >&2; exit 1; }

AMI_NAME="${AMI_NAME:-$NAME}"
TIER="${TIER:-egress}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"

# which subnets get their default route pointed at this instance - app only by default. db
# stays off the internet entirely unless you opt it in; least privilege beats convenience for a
# tier that shouldn't need outbound access in the first place.
RELAY_SUBNET_IDS="${RELAY_SUBNET_IDS:-$APP_SUBNET_ID}"

AMI_KEY="AMI_$(echo "${AMI_NAME}_egress_gateway" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
AMI_ID_VAR="${AMI_KEY}_ID"
AMI_ID="${!AMI_ID_VAR}"

: "${AMI_ID:?no egress-gateway AMI found for name=$AMI_NAME in $STATE_FILE - run 'run.sh ami $AMI_NAME egress-gateway create' first (set AMI_NAME if the AMI was built under a different name than this instance)}"

case "$TIER" in
    bastion) SUBNET_ID="$BASTION_SUBNET_ID" ;;
    app)     SUBNET_ID="$APP_SUBNET_ID" ;;
    db)      SUBNET_ID="$DB_SUBNET_ID" ;;
    egress)  SUBNET_ID="$EGRESS_SUBNET_ID" ;;
    *) echo "error: TIER must be bastion, app, db or egress" >&2; exit 1 ;;
esac

: "${SUBNET_ID:?no subnet for tier=$TIER in $STATE_FILE - run 'run.sh network create' first}"
: "${VPC_ID:?no VPC in $STATE_FILE - run 'run.sh network create' first}"
: "${PUBLIC_RT_ID:?no PUBLIC_RT_ID in $STATE_FILE - run 'run.sh network create' first}"

[[ -n "$DATE_NAME" ]] || echo "warning: no DATE_NAME in $STATE_FILE - launching without a key pair (run 'run.sh keys <name> create' for SSH access)"
[[ -n "$INSTANCE_PROFILE_NAME" ]] || echo "warning: no INSTANCE_PROFILE_NAME in $STATE_FILE - launching without SSM access (run 'run.sh ssm create' first)"

statefile() {
    local var_prefix
    var_prefix="EGRESS_$(echo "$NAME" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"

    {
        echo
        echo "# $NAME (egress gateway)"
        echo "export AWS_REGION=\"$AWS_REGION\""
        echo "export ${var_prefix}_ID=\"$INSTANCE_ID\""
        echo "export ${var_prefix}_SG=\"$SG_ID\""
        echo "export ${var_prefix}_RT=\"$PRIVATE_RT_ID\""
        echo "export ${var_prefix}_PUBLIC_IP=\"$PUBLIC_IP\""
        echo "export ${var_prefix}_PRIVATE_IP=\"$PRIVATE_IP\""
    } >> "$STATE_FILE"

    echo "State appended to $STATE_FILE"
}

create() {
    VPC_CIDR=$(aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" \
        --query 'Vpcs[0].CidrBlock' --output text)

    echo "=== Creating security group for $NAME ==="

    SG_ID=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "egress-gw-${Purpose}-${NAME}" \
        --description "Egress gateway (NAT instance) - $NAME" \
        --vpc-id "$VPC_ID" \
        --tag-specifications \
        "ResourceType=security-group,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$NAME},{Key=Role,Value=egress-gateway}]" \
        --query 'GroupId' \
        --output text)

    # forwarded traffic hitting this instance's ENI is filtered by its security group same as
    # traffic addressed to the instance itself - the relay subnets need to reach it on whatever
    # port their own outbound connections use, so this has to allow all traffic, not just SSH.
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=$VPC_CIDR,Description=relay traffic from the VPC}]" \
        >/dev/null

    echo "Security group: $SG_ID (allows all traffic from $VPC_CIDR)"


    echo "=== Launching $NAME (tier=$TIER) ==="

    local run_args=(
        --region "$AWS_REGION"
        --image-id "$AMI_ID"
        --instance-type "$INSTANCE_TYPE"
        --subnet-id "$SUBNET_ID"
        --security-group-ids "$SG_ID"
        --associate-public-ip-address
    )
    [[ -n "$DATE_NAME" ]] && run_args+=(--key-name "$DATE_NAME")
    [[ -n "$INSTANCE_PROFILE_NAME" ]] && run_args+=(--iam-instance-profile "Name=$INSTANCE_PROFILE_NAME")

    INSTANCE_ID=$(aws ec2 run-instances \
        "${run_args[@]}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$NAME},{Key=Role,Value=egress-gateway},{Key=Tier,Value=$TIER}]" \
        --query 'Instances[0].InstanceId' \
        --output text)

    echo "waiting for $INSTANCE_ID to be running..."
    aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"

    # the one EC2-API-level thing that actually makes this a router instead of just an
    # instance with NAT software installed: without this, AWS drops any packet whose source or
    # destination isn't the instance's own IP, no matter what the OS does with it.
    aws ec2 modify-instance-attribute \
        --region "$AWS_REGION" \
        --instance-id "$INSTANCE_ID" \
        --no-source-dest-check

    PUBLIC_IP=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    PRIVATE_IP=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

    echo "$NAME: $INSTANCE_ID  public=$PUBLIC_IP  private=$PRIVATE_IP"


    echo "=== Creating private route table for relayed subnets ==="

    PRIVATE_RT_ID=$(aws ec2 create-route-table \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --tag-specifications \
        "ResourceType=route-table,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$NAME},{Key=Role,Value=egress-gateway}]" \
        --query 'RouteTable.RouteTableId' \
        --output text)

    aws ec2 create-route \
        --region "$AWS_REGION" \
        --route-table-id "$PRIVATE_RT_ID" \
        --destination-cidr-block "0.0.0.0/0" \
        --instance-id "$INSTANCE_ID" \
        >/dev/null

    echo "Private route table: $PRIVATE_RT_ID (0.0.0.0/0 -> $INSTANCE_ID)"


    echo "=== Pointing relay subnets at $NAME ==="

    for subnet in $RELAY_SUBNET_IDS; do
        assoc_id=$(aws ec2 describe-route-tables \
            --region "$AWS_REGION" \
            --filters "Name=association.subnet-id,Values=$subnet" \
            --query 'RouteTables[0].Associations[?SubnetId==`'"$subnet"'`].RouteTableAssociationId | [0]' \
            --output text)

        if [[ -z "$assoc_id" || "$assoc_id" == "None" ]]; then
            echo "warning: $subnet has no explicit route table association - associating it with $PRIVATE_RT_ID directly" >&2
            aws ec2 associate-route-table \
                --region "$AWS_REGION" \
                --route-table-id "$PRIVATE_RT_ID" \
                --subnet-id "$subnet" \
                >/dev/null
        else
            aws ec2 replace-route-table-association \
                --region "$AWS_REGION" \
                --association-id "$assoc_id" \
                --route-table-id "$PRIVATE_RT_ID" \
                >/dev/null
        fi

        echo "$subnet -> $PRIVATE_RT_ID"
    done

    echo
    echo "========================================"
    echo "Egress gateway created"
    echo "========================================"
    echo "Instance:     $INSTANCE_ID"
    echo "Public IP:    $PUBLIC_IP"
    echo "Private IP:   $PRIVATE_IP"
    echo "Relaying:     $RELAY_SUBNET_IDS"
    echo "========================================"

    statefile
}

delete() {
    echo "=== Finding egress gateway instances tagged Purpose=$Purpose, Name=$NAME ==="

    INSTANCE_IDS=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$NAME" "Name=tag:Role,Values=egress-gateway" \
                   "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text)

    if [[ -z "$INSTANCE_IDS" ]]; then
        echo "no matching egress gateway"
        return
    fi

    for instance_id in $INSTANCE_IDS; do
        echo "=== Restoring routing for $instance_id ==="

        # found by what actually routes to this instance right now, rather than by trusting
        # $RELAY_SUBNET_IDS to still match what create() was run with - the route tables
        # themselves are the source of truth for what's currently relayed through it.
        for rt in $(aws ec2 describe-route-tables \
            --region "$AWS_REGION" \
            --filters "Name=route.instance-id,Values=$instance_id" \
            --query 'RouteTables[*].RouteTableId' \
            --output text); do

            for assoc_id in $(aws ec2 describe-route-tables \
                --region "$AWS_REGION" \
                --route-table-ids "$rt" \
                --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
                --output text); do

                if [[ -n "$PUBLIC_RT_ID" ]]; then
                    echo "restoring $assoc_id to $PUBLIC_RT_ID"
                    aws ec2 replace-route-table-association \
                        --region "$AWS_REGION" \
                        --association-id "$assoc_id" \
                        --route-table-id "$PUBLIC_RT_ID" \
                        >/dev/null
                else
                    echo "warning: no PUBLIC_RT_ID in $STATE_FILE - disassociating $assoc_id, subnet falls back to the VPC's main route table" >&2
                    aws ec2 disassociate-route-table --region "$AWS_REGION" --association-id "$assoc_id" >/dev/null
                fi
            done

            echo "Deleting route table: $rt"
            aws ec2 delete-route-table --region "$AWS_REGION" --route-table-id "$rt"
        done

        echo "Terminating: $instance_id"
        aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$instance_id" >/dev/null

        echo "waiting for termination..."
        aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "$instance_id"
    done

    echo "=== Deleting security group(s) ==="

    for sg in $(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$NAME" "Name=tag:Role,Values=egress-gateway" \
        --query 'SecurityGroups[*].GroupId' \
        --output text); do

        echo "Deleting security group: $sg"
        aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg"
    done

    echo "=== Cleanup complete ==="
    echo "note: $STATE_FILE is an append-only log - this gateway's entries stay there for history"
}

case "$3" in
    create)
        create
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh egress <name> {create|delete}"
        exit 1
        ;;
esac
