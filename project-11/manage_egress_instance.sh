# Launches a small public EC2 instance as a self-managed NAT instance - a cheap, DIY stand-in
# for a NAT Gateway. manage_network.sh's app/db subnets have a route to the Internet Gateway
# but no public IP and no NAT, so they have no way to actually reach it; this instance sits in
# a public subnet with a public IP, and create() rewires the relayed subnets' route table so
# their 0.0.0.0/0 traffic goes to this instance instead. The instance itself is built from a
# custom AMI (`run.sh ami <ami-name> egress-gateway create` - see ami-scripts/egress-gateway.sh)
# that already has IP forwarding and NAT baked in; this script only handles what has to happen
# at launch time: disabling source/dest check (required for any instance to route traffic that
# isn't addressed to itself) and pointing the relay subnets at it.
#
# Optional inbound HTTPS passthrough (HTTPS_BACKEND_IP or HTTPS_BACKEND_NAME set): tcp/443 hitting
# the gateway's public IP is DNAT'd to one app instance, which terminates TLS itself - the
# gateway never holds a certificate. `sync` re-points it (e.g. after the backend was relaunched
# and got a new private IP) over SSM, no relaunch needed. For TLS termination and more than one
# backend, use `run.sh egress-balancer` instead.

source "$STATE_FILE"

[[ "$NAME" =~ ^(create|delete|keys|ssm|network|instances|s3|ami|sync|instance-ami|egress|egress-balancer)$ ]] && { echo "error: invalid name '$NAME'" >&2; exit 1; }

AMI_NAME="${AMI_NAME:-$NAME}"
TIER="${TIER:-egress}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"

# which subnets get their default route pointed at this instance - app only by default. db
# stays off the internet entirely unless you opt it in; least privilege beats convenience for a
# tier that shouldn't need outbound access in the first place.
RELAY_SUBNET_IDS="${RELAY_SUBNET_IDS:-$APP_SUBNET_ID}"

# inbound HTTPS passthrough - off unless one of these is set. HTTPS_BACKEND_IP wins; otherwise the
# first running instance in this VPC tagged Purpose=$Purpose with Name matching HTTPS_BACKEND_NAME
# (wildcards ok). `none` on either turns passthrough off again on `sync`.
HTTPS_BACKEND_IP="${HTTPS_BACKEND_IP:-}"
HTTPS_BACKEND_NAME="${HTTPS_BACKEND_NAME:-}"
HTTPS_BACKEND_PORT="${HTTPS_BACKEND_PORT:-443}"
HTTPS_BACKEND_SG="${HTTPS_BACKEND_SG:-$APP_SG}"
HTTPS_INGRESS_CIDR="${HTTPS_INGRESS_CIDR:-0.0.0.0/0}"

[[ "$HTTPS_BACKEND_PORT" =~ ^[0-9]+$ ]] || { echo "error: HTTPS_BACKEND_PORT must be a port number" >&2; exit 1; }

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

HTTPS_REQUESTED=""
[[ -n "$HTTPS_BACKEND_IP$HTTPS_BACKEND_NAME" ]] && HTTPS_REQUESTED=1


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

# sets HTTPS_FORWARD to "ip:port" (or "" = passthrough off) from HTTPS_BACKEND_IP/HTTPS_BACKEND_NAME
resolve_https_backend() {
    local ip="$HTTPS_BACKEND_IP"
    HTTPS_FORWARD=""

    [[ "$ip" == "none" || "$HTTPS_BACKEND_NAME" == "none" ]] && { echo "HTTPS passthrough: off"; return; }

    if [[ -z "$ip" && -n "$HTTPS_BACKEND_NAME" ]]; then
        ip=$(aws ec2 describe-instances \
            --region "$AWS_REGION" \
            --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$HTTPS_BACKEND_NAME" \
                      "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running" \
            --query 'Reservations[].Instances[].PrivateIpAddress | [0]' \
            --output text)
        [[ "$ip" == "None" ]] && ip=""
        [[ -n "$ip" ]] || { echo "error: no running instance tagged Name=$HTTPS_BACKEND_NAME for HTTPS passthrough" >&2; exit 1; }
    fi

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "error: HTTPS backend '$ip' isn't an IPv4 address" >&2; exit 1; }

    HTTPS_FORWARD="$ip:$HTTPS_BACKEND_PORT"
    echo "HTTPS passthrough: tcp/443 -> $HTTPS_FORWARD"
}

# shell snippet that writes the forward target and re-applies the ruleset - shared by user-data
# (create) and SSM send-command (sync)
nat_commands() {
    echo "mkdir -p /etc/egress-gateway"
    echo "echo '$HTTPS_FORWARD' > /etc/egress-gateway/https-forward"
    echo "/usr/local/sbin/egress-gateway-nat.sh"
}

# idempotent: the listener on the gateway's own SG, and "from the gateway" on the backend's SG.
# The backend sees the gateway's private IP (the DNAT'd connection is masqueraded), so an
# SG-reference rule is enough - it never has to be opened to the internet itself.
open_https_rules() {
    local sg="$1"

    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$sg" \
        --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$HTTPS_INGRESS_CIDR,Description=https passthrough}]" \
        >/dev/null 2>&1 \
        && echo "Security group $sg: tcp/443 from $HTTPS_INGRESS_CIDR" \
        || echo "Security group $sg: tcp/443 rule already present (or couldn't be added)"

    if [[ -n "$HTTPS_BACKEND_SG" ]]; then
        aws ec2 authorize-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$HTTPS_BACKEND_SG" \
            --ip-permissions "IpProtocol=tcp,FromPort=$HTTPS_BACKEND_PORT,ToPort=$HTTPS_BACKEND_PORT,UserIdGroupPairs=[{GroupId=$sg,Description=https passthrough from egress $NAME}]" \
            >/dev/null 2>&1 \
            && echo "Backend SG $HTTPS_BACKEND_SG: tcp/$HTTPS_BACKEND_PORT from $sg" \
            || echo "Backend SG $HTTPS_BACKEND_SG: tcp/$HTTPS_BACKEND_PORT from $sg already present (or couldn't be added)"
    fi
}

create() {
    [[ -n "$DATE_NAME" ]] || echo "warning: no DATE_NAME in $STATE_FILE - launching without a key pair (run 'run.sh keys <name> create' for SSH access)"
    [[ -n "$INSTANCE_PROFILE_NAME" ]] || echo "warning: no INSTANCE_PROFILE_NAME in $STATE_FILE - launching without SSM access, 'sync' won't work (run 'run.sh ssm create' first)"

    HTTPS_FORWARD=""
    [[ -n "$HTTPS_REQUESTED" ]] && resolve_https_backend

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

    [[ -n "$HTTPS_FORWARD" ]] && open_https_rules "$SG_ID"


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

    # only needed for passthrough - without it the image's boot-time unit already applies plain NAT
    local user_data_file=""
    if [[ -n "$HTTPS_FORWARD" ]]; then
        user_data_file=$(mktemp)
        { echo "#!/bin/bash"; echo "set -e"; nat_commands; } > "$user_data_file"
        run_args+=(--user-data "file://$user_data_file")
    fi

    INSTANCE_ID=$(aws ec2 run-instances \
        "${run_args[@]}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$NAME},{Key=Role,Value=egress-gateway},{Key=Tier,Value=$TIER}]" \
        --query 'Instances[0].InstanceId' \
        --output text)

    [[ -n "$user_data_file" ]] && rm -f "$user_data_file"

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
    [[ -n "$HTTPS_FORWARD" ]] && echo "HTTPS:        https://$PUBLIC_IP/ -> $HTTPS_FORWARD (passthrough, TLS on the backend)"
    echo "========================================"

    statefile
}

# re-point (or turn off) HTTPS passthrough on the running gateway(s) over SSM - for when the
# backend was relaunched with a new private IP, or passthrough is being enabled after the fact
sync_https() {
    [[ -n "$HTTPS_REQUESTED" ]] || { echo "error: set HTTPS_BACKEND_IP or HTTPS_BACKEND_NAME (or =none to turn passthrough off)" >&2; exit 1; }
    resolve_https_backend

    INSTANCE_IDS=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$NAME" "Name=tag:Role,Values=egress-gateway" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text)
    [[ -n "$INSTANCE_IDS" ]] || { echo "error: no running egress gateway tagged Purpose=$Purpose, Name=$NAME" >&2; exit 1; }

    if [[ -n "$HTTPS_FORWARD" ]]; then
        for sg in $(aws ec2 describe-security-groups \
            --region "$AWS_REGION" \
            --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$NAME" "Name=tag:Role,Values=egress-gateway" \
            --query 'SecurityGroups[*].GroupId' \
            --output text); do
            open_https_rules "$sg"
        done
    fi

    local params cmds=()
    while IFS= read -r line; do cmds+=("\"$line\""); done < <(nat_commands)
    params="{\"commands\":[$(IFS=,; echo "${cmds[*]}")]}"

    for instance_id in $INSTANCE_IDS; do
        echo "=== Pushing https-forward to $instance_id over SSM ==="

        COMMAND_ID=$(aws ssm send-command \
            --region "$AWS_REGION" \
            --instance-ids "$instance_id" \
            --document-name AWS-RunShellScript \
            --comment "egress sync $NAME" \
            --parameters "$params" \
            --query 'Command.CommandId' \
            --output text) || { echo "error: send-command failed - does $instance_id have an SSM instance profile? ('run.sh ssm create')" >&2; exit 1; }

        aws ssm wait command-executed --region "$AWS_REGION" --command-id "$COMMAND_ID" --instance-id "$instance_id" || true

        aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$COMMAND_ID" \
            --instance-id "$instance_id" \
            --query '[Status, StandardOutputContent, StandardErrorContent]' \
            --output text
    done

    if [[ -z "$HTTPS_FORWARD" ]]; then
        echo "note: passthrough is off on the instance; the tcp/443 SG rules stay until 'delete'"
    fi
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

        # HTTPS passthrough adds a rule on the backend's SG referencing this one, and AWS won't
        # delete an SG something still references - revoke those first, found by what
        # references it now rather than trusting HTTPS_BACKEND_SG
        for ref_sg in $(aws ec2 describe-security-groups \
            --region "$AWS_REGION" \
            --filters "Name=ip-permission.group-id,Values=$sg" \
            --query 'SecurityGroups[*].GroupId' \
            --output text); do

            [[ "$ref_sg" == "$sg" ]] && continue

            rule_ids=$(aws ec2 describe-security-group-rules \
                --region "$AWS_REGION" \
                --filters "Name=group-id,Values=$ref_sg" \
                --query "SecurityGroupRules[?IsEgress==\`false\` && ReferencedGroupInfo.GroupId=='$sg'].SecurityGroupRuleId" \
                --output text)

            if [[ -n "$rule_ids" && "$rule_ids" != "None" ]]; then
                echo "Revoking rule(s) on $ref_sg referencing $sg: $rule_ids"
                aws ec2 revoke-security-group-ingress \
                    --region "$AWS_REGION" \
                    --group-id "$ref_sg" \
                    --security-group-rule-ids $rule_ids \
                    >/dev/null
            fi
        done

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
    sync)
        sync_https
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh egress <name> {create|sync|delete}"
        exit 1
        ;;
esac
