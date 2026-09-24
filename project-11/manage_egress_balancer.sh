# Launches an egress *balancer*: the same self-managed NAT instance as manage_egress_instance.sh,
# built from its own AMI (`run.sh ami <ami-name> egress-balancer create` - see
# ami-scripts/egress-balancer.sh) that additionally runs nginx on :80 as an HTTP load balancer
# in front of the app tier. Kept separate from `run.sh egress` on purpose: different AMI,
# different Role tag, its own SG/route table/state keys, so a plain NAT gateway and a balancer
# can be created, replaced and torn down independently of each other.
#
# On top of what `egress` does at launch time (source/dest check off, relay subnets rewired),
# this also:
#   - resolves which app instances to balance across (BACKEND_NAME tag pattern or BACKEND_IPS)
#     and hands them to the instance via user-data, rendered into nginx at first boot
#   - opens LB_PORT (80) to LB_INGRESS_CIDR on its own SG, and BACKEND_PORT from its own SG on
#     BACKEND_SG (default $APP_SG) - the per-tier SGs manage_network.sh creates are empty
#   - `sync` re-resolves the backends and pushes them over SSM, no relaunch needed
#   - optional HTTPS (HTTPS_DOMAINS set): opens :443 too and has the instance get and renew a
#     Let's Encrypt certificate for those domains - see ami-scripts/egress-balancer.sh

source "$STATE_FILE"

[[ "$NAME" =~ ^(create|delete|sync|keys|ssm|network|instances|s3|ami|instance-ami|egress|egress-balancer)$ ]] && { echo "error: invalid name '$NAME'" >&2; exit 1; }

AMI_NAME="${AMI_NAME:-$NAME}"
TIER="${TIER:-egress}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"

# same default as `run.sh egress` - app only. RELAY_SUBNET_IDS=none launches a pure load
# balancer that leaves every subnet's routing alone (e.g. a plain egress gateway already
# relays the app tier and you only want the LB half from this one).
RELAY_SUBNET_IDS="${RELAY_SUBNET_IDS:-$APP_SUBNET_ID}"
[[ "$RELAY_SUBNET_IDS" == "none" ]] && RELAY_SUBNET_IDS=""

# which instances nginx balances across: BACKEND_IPS (space-separated private IPs) wins if set,
# otherwise every running instance in this VPC tagged Purpose=$Purpose and Name matching
# BACKEND_NAME (wildcards ok - e.g. 'myapp-production-*' for an `instance-ami myapp production`
# batch). Neither set is allowed on `create`: the balancer comes up answering 503 until a later
# `sync` with one of them.
BACKEND_NAME="${BACKEND_NAME:-}"
BACKEND_IPS="${BACKEND_IPS:-}"
BACKENDS_SET="${BACKEND_NAME}${BACKEND_IPS}"   # `sync` only rewrites the list when one is given
BACKEND_PORT="${BACKEND_PORT:-80}"
BACKEND_SG="${BACKEND_SG:-$APP_SG}"
LB_METHOD_SET="${LB_METHOD:+1}"   # `sync` only overwrites the method when one is actually given
LB_METHOD="${LB_METHOD:-round_robin}"
LB_PORT=80   # fixed - it's what ami-scripts/egress-balancer.sh's nginx listens on
LB_INGRESS_CIDR="${LB_INGRESS_CIDR:-0.0.0.0/0}"

[[ "$LB_METHOD" =~ ^(round_robin|least_conn|ip_hash)$ ]] || { echo "error: LB_METHOD must be round_robin, least_conn or ip_hash" >&2; exit 1; }
[[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || { echo "error: BACKEND_PORT must be a port number" >&2; exit 1; }

# HTTPS - off unless HTTPS_DOMAINS is set (comma-separated; the first is the cert's primary
# name). The instance requests the certificate itself over HTTP-01, so every domain's DNS has to
# point at the balancer's public IP first - which isn't known until `create` prints it. Expect
# to create, point DNS, then `sync` (HTTPS_DOMAINS again) to actually get the cert; until then it
# serves plain HTTP. `sync` leaves HTTPS settings alone unless HTTPS_DOMAINS is given, and
# HTTPS_DOMAINS=none turns HTTPS back off.
HTTPS_DOMAINS="${HTTPS_DOMAINS:-}"
HTTPS_SET="${HTTPS_DOMAINS:+1}"
[[ "$HTTPS_DOMAINS" == "none" ]] && HTTPS_DOMAINS=""
HTTPS_EMAIL="${HTTPS_EMAIL:-}"
HTTPS_REDIRECT="${HTTPS_REDIRECT:-true}"
HTTPS_STAGING="${HTTPS_STAGING:-false}"
HTTPS_DNS_CHECK="${HTTPS_DNS_CHECK:-true}"
HTTPS_PORT=443   # fixed, same as LB_PORT

[[ -z "$HTTPS_DOMAINS" || "$HTTPS_DOMAINS" =~ ^[A-Za-z0-9.-]+(,[A-Za-z0-9.-]+)*$ ]] || { echo "error: HTTPS_DOMAINS must be comma-separated domain names" >&2; exit 1; }
[[ -z "$HTTPS_EMAIL" || "$HTTPS_EMAIL" =~ ^[^[:space:]@\'\"]+@[^[:space:]@\'\"]+$ ]] || { echo "error: HTTPS_EMAIL doesn't look like an email address" >&2; exit 1; }
for v in HTTPS_REDIRECT HTTPS_STAGING HTTPS_DNS_CHECK; do
    [[ "${!v}" =~ ^(true|false)$ ]] || { echo "error: $v must be true or false" >&2; exit 1; }
done

AMI_KEY="AMI_$(echo "${AMI_NAME}_egress_balancer" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
AMI_ID_VAR="${AMI_KEY}_ID"
AMI_ID="${!AMI_ID_VAR}"

case "$TIER" in
    bastion) SUBNET_ID="$BASTION_SUBNET_ID" ;;
    app)     SUBNET_ID="$APP_SUBNET_ID" ;;
    db)      SUBNET_ID="$DB_SUBNET_ID" ;;
    egress)  SUBNET_ID="$EGRESS_SUBNET_ID" ;;
    *) echo "error: TIER must be bastion, app, db or egress" >&2; exit 1 ;;
esac

VAR_PREFIX="EGRESS_BALANCER_$(echo "$NAME" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"

statefile() {
    {
        echo
        echo "# $NAME (egress balancer)"
        echo "export AWS_REGION=\"$AWS_REGION\""
        echo "export ${VAR_PREFIX}_ID=\"$INSTANCE_ID\""
        echo "export ${VAR_PREFIX}_SG=\"$SG_ID\""
        echo "export ${VAR_PREFIX}_RT=\"$PRIVATE_RT_ID\""
        echo "export ${VAR_PREFIX}_PUBLIC_IP=\"$PUBLIC_IP\""
        echo "export ${VAR_PREFIX}_PRIVATE_IP=\"$PRIVATE_IP\""
    } >> "$STATE_FILE"

    echo "State appended to $STATE_FILE"
}

# sets BACKENDS (newline-separated host:port) from BACKEND_IPS or a BACKEND_NAME tag lookup
resolve_backends() {
    local ips="$BACKEND_IPS"

    if [[ -z "$ips" && -n "$BACKEND_NAME" ]]; then
        ips=$(aws ec2 describe-instances \
            --region "$AWS_REGION" \
            --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$BACKEND_NAME" \
                      "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running" \
            --query 'Reservations[].Instances[].PrivateIpAddress' \
            --output text)
        [[ "$ips" == "None" ]] && ips=""
    fi

    BACKENDS=""
    for ip in $ips; do
        BACKENDS+="$ip:$BACKEND_PORT"$'\n'
    done

    if [[ -z "$BACKENDS" ]]; then
        echo "warning: no backends resolved (BACKEND_NAME='$BACKEND_NAME' BACKEND_IPS='$BACKEND_IPS') - nginx will answer 503 until 'run.sh egress-balancer $NAME sync'" >&2
    else
        echo "Backends ($LB_METHOD):"
        printf '  %s\n' $BACKENDS
    fi
}

# shell snippet that writes the backend/method/https files and then runs the cert script (which
# issues/renews if HTTPS is on and always finishes by re-rendering nginx) - shared by user-data
# (`create`: writes everything) and SSM send-command (`sync`: only what's given - backends,
# method and https settings each stay as they are on the instance unless passed again). base64 so the payload survives both transports unquoted.
render_commands() {
    local all="$1" b64

    if [[ -n "$all" || -n "$BACKENDS_SET" ]]; then
        b64=$(printf '%s' "$BACKENDS" | base64 | tr -d '\n')
        echo "echo '$b64' | base64 -d > /etc/egress-balancer/backends"
    fi

    [[ -n "$all" || -n "$LB_METHOD_SET" ]] && echo "echo '$LB_METHOD' > /etc/egress-balancer/method"

    if [[ -n "$all" || -n "$HTTPS_SET" ]]; then
        b64=$(printf 'DOMAINS=%s\nEMAIL=%s\nREDIRECT=%s\nSTAGING=%s\nDNS_CHECK=%s\n' \
            "$HTTPS_DOMAINS" "$HTTPS_EMAIL" "$HTTPS_REDIRECT" "$HTTPS_STAGING" "$HTTPS_DNS_CHECK" | base64 | tr -d '\n')
        echo "echo '$b64' | base64 -d > /etc/egress-balancer/https.conf"
    fi

    echo "/usr/local/sbin/egress-balancer-cert.sh"
}

# idempotent - :443 on the balancer's own SG, for `create` and for HTTPS turned on by a later `sync`
open_https_ingress() {
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$1" \
        --ip-permissions "IpProtocol=tcp,FromPort=$HTTPS_PORT,ToPort=$HTTPS_PORT,IpRanges=[{CidrIp=$LB_INGRESS_CIDR,Description=load balancer https listener}]" \
        >/dev/null 2>&1 \
        && echo "Security group $1: tcp/$HTTPS_PORT from $LB_INGRESS_CIDR" \
        || echo "Security group $1: tcp/$HTTPS_PORT rule already present (or couldn't be added)"
}

find_instances() {
    aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$NAME" "Name=tag:Role,Values=egress-balancer" \
                  "Name=instance-state-name,Values=$1" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text
}

create() {
    : "${AMI_ID:?no egress-balancer AMI found for name=$AMI_NAME in $STATE_FILE - run 'TIER=egress run.sh ami $AMI_NAME egress-balancer create' first (set AMI_NAME if the AMI was built under a different name than this instance)}"
    : "${SUBNET_ID:?no subnet for tier=$TIER in $STATE_FILE - run 'run.sh network create' first}"
    : "${VPC_ID:?no VPC in $STATE_FILE - run 'run.sh network create' first}"
    : "${PUBLIC_RT_ID:?no PUBLIC_RT_ID in $STATE_FILE - run 'run.sh network create' first}"

    [[ -n "$DATE_NAME" ]] || echo "warning: no DATE_NAME in $STATE_FILE - launching without a key pair (run 'run.sh keys <name> create' for SSH access)"
    [[ -n "$INSTANCE_PROFILE_NAME" ]] || echo "warning: no INSTANCE_PROFILE_NAME in $STATE_FILE - launching without SSM access, 'sync' won't work (run 'run.sh ssm create' first)"

    resolve_backends

    VPC_CIDR=$(aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" \
        --query 'Vpcs[0].CidrBlock' --output text)

    echo "=== Creating security group for $NAME ==="

    SG_ID=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "egress-lb-${Purpose}-${NAME}" \
        --description "Egress balancer (NAT instance + nginx LB) - $NAME" \
        --vpc-id "$VPC_ID" \
        --tag-specifications \
        "ResourceType=security-group,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$NAME},{Key=Role,Value=egress-balancer}]" \
        --query 'GroupId' \
        --output text)

    # all traffic from the VPC: forwarded (NAT'd) packets are filtered by this SG like anything
    # else hitting the ENI - same reasoning as manage_egress_instance.sh. Plus the LB listener
    # from wherever clients are.
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --ip-permissions \
        "IpProtocol=-1,IpRanges=[{CidrIp=$VPC_CIDR,Description=relay traffic from the VPC}]" \
        "IpProtocol=tcp,FromPort=$LB_PORT,ToPort=$LB_PORT,IpRanges=[{CidrIp=$LB_INGRESS_CIDR,Description=load balancer listener}]" \
        >/dev/null

    echo "Security group: $SG_ID (all from $VPC_CIDR, tcp/$LB_PORT from $LB_INGRESS_CIDR)"

    [[ -n "$HTTPS_DOMAINS" ]] && open_https_ingress "$SG_ID"

    # backends only need to accept the balancer, not the world - referenced by SG id so it keeps
    # working whatever private IP the balancer ends up with
    if [[ -n "$BACKEND_SG" ]]; then
        aws ec2 authorize-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$BACKEND_SG" \
            --ip-permissions "IpProtocol=tcp,FromPort=$BACKEND_PORT,ToPort=$BACKEND_PORT,UserIdGroupPairs=[{GroupId=$SG_ID,Description=from egress balancer $NAME}]" \
            >/dev/null \
            && echo "Backend SG $BACKEND_SG: allows tcp/$BACKEND_PORT from $SG_ID" \
            || echo "warning: couldn't add tcp/$BACKEND_PORT from $SG_ID to $BACKEND_SG - backends may be unreachable" >&2
    fi


    echo "=== Launching $NAME (tier=$TIER) ==="

    USER_DATA_FILE=$(mktemp)
    { echo "#!/bin/bash"; echo "set -e"; render_commands all; } > "$USER_DATA_FILE"

    local run_args=(
        --region "$AWS_REGION"
        --image-id "$AMI_ID"
        --instance-type "$INSTANCE_TYPE"
        --subnet-id "$SUBNET_ID"
        --security-group-ids "$SG_ID"
        --associate-public-ip-address
        --user-data "file://$USER_DATA_FILE"
    )
    [[ -n "$DATE_NAME" ]] && run_args+=(--key-name "$DATE_NAME")
    [[ -n "$INSTANCE_PROFILE_NAME" ]] && run_args+=(--iam-instance-profile "Name=$INSTANCE_PROFILE_NAME")

    INSTANCE_ID=$(aws ec2 run-instances \
        "${run_args[@]}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$NAME},{Key=Role,Value=egress-balancer},{Key=Tier,Value=$TIER}]" \
        --query 'Instances[0].InstanceId' \
        --output text)

    rm -f "$USER_DATA_FILE"

    echo "waiting for $INSTANCE_ID to be running..."
    aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"

    # still a router for the relayed subnets - see manage_egress_instance.sh
    aws ec2 modify-instance-attribute \
        --region "$AWS_REGION" \
        --instance-id "$INSTANCE_ID" \
        --no-source-dest-check

    PUBLIC_IP=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    PRIVATE_IP=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

    echo "$NAME: $INSTANCE_ID  public=$PUBLIC_IP  private=$PRIVATE_IP"


    PRIVATE_RT_ID=""
    if [[ -n "$RELAY_SUBNET_IDS" ]]; then
        echo "=== Creating private route table for relayed subnets ==="

        PRIVATE_RT_ID=$(aws ec2 create-route-table \
            --region "$AWS_REGION" \
            --vpc-id "$VPC_ID" \
            --tag-specifications \
            "ResourceType=route-table,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$NAME},{Key=Role,Value=egress-balancer}]" \
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
                # if a `run.sh egress` gateway already relays this subnet, this takes it over -
                # its route table stays behind, unassociated, until `run.sh egress <name> delete`
                aws ec2 replace-route-table-association \
                    --region "$AWS_REGION" \
                    --association-id "$assoc_id" \
                    --route-table-id "$PRIVATE_RT_ID" \
                    >/dev/null
            fi

            echo "$subnet -> $PRIVATE_RT_ID"
        done
    else
        echo "RELAY_SUBNET_IDS=none - load balancer only, no subnet routing changed"
    fi

    echo
    echo "========================================"
    echo "Egress balancer created"
    echo "========================================"
    echo "Instance:     $INSTANCE_ID"
    echo "Public IP:    $PUBLIC_IP"
    echo "Private IP:   $PRIVATE_IP"
    echo "Relaying:     ${RELAY_SUBNET_IDS:-none}"
    echo "LB:           http://$PUBLIC_IP/ -> $(echo $BACKENDS | wc -w) backend(s) on :$BACKEND_PORT ($LB_METHOD)"
    echo "Health:       http://$PUBLIC_IP/lb-health"
    if [[ -n "$HTTPS_DOMAINS" ]]; then
        local ca="Let's Encrypt"
        [[ "$HTTPS_STAGING" == "true" ]] && ca="Let's Encrypt staging"
        echo "HTTPS:        $HTTPS_DOMAINS ($ca)"
        [[ "$HTTPS_DNS_CHECK" == "true" ]] && \
        echo "              point DNS at $PUBLIC_IP, then 'run.sh egress-balancer $NAME sync' to request the cert"
    fi
    echo "========================================"

    statefile
}

# push changes to the running balancer(s) over SSM, no relaunch needed: re-resolved backends
# (app instances added/replaced/removed since `create`), a new LB_METHOD, HTTPS turned on/off or
# its domains changed. With nothing set it still re-runs the cert script - which is how the
# certificate gets requested once DNS points at the balancer.
sync_balancer() {
    if [[ -n "$BACKENDS_SET" ]]; then
        resolve_backends
    else
        echo "BACKEND_NAME/BACKEND_IPS not set - leaving the backend list as it is"
    fi

    INSTANCE_IDS=$(find_instances running)
    [[ -n "$INSTANCE_IDS" ]] || { echo "error: no running egress balancer tagged Purpose=$Purpose, Name=$NAME" >&2; exit 1; }

    local params cmds=()
    if [[ -n "$HTTPS_DOMAINS" ]]; then
        for sg in $(aws ec2 describe-security-groups \
            --region "$AWS_REGION" \
            --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$NAME" "Name=tag:Role,Values=egress-balancer" \
            --query 'SecurityGroups[*].GroupId' \
            --output text); do
            open_https_ingress "$sg"
        done
    fi

    while IFS= read -r line; do cmds+=("\"$line\""); done < <(render_commands)
    params="{\"commands\":[$(IFS=,; echo "${cmds[*]}")]}"

    for instance_id in $INSTANCE_IDS; do
        echo "=== Pushing backends to $instance_id over SSM ==="

        COMMAND_ID=$(aws ssm send-command \
            --region "$AWS_REGION" \
            --instance-ids "$instance_id" \
            --document-name AWS-RunShellScript \
            --comment "egress-balancer sync $NAME" \
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
}

delete() {
    echo "=== Finding egress balancer instances tagged Purpose=$Purpose, Name=$NAME ==="

    INSTANCE_IDS=$(find_instances pending,running,stopping,stopped)

    [[ -z "$INSTANCE_IDS" ]] && echo "no matching egress balancer instance"

    for instance_id in $INSTANCE_IDS; do
        echo "=== Restoring routing for $instance_id ==="

        # route tables that actually point at this instance are the source of truth, not
        # whatever RELAY_SUBNET_IDS happens to be now - same as manage_egress_instance.sh
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
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$NAME" "Name=tag:Role,Values=egress-balancer" \
        --query 'SecurityGroups[*].GroupId' \
        --output text); do

        # an SG can't be deleted while another SG's rule references it - revoke the backend
        # rules create() added first, found by what references it now rather than BACKEND_SG
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
    echo "note: $STATE_FILE is an append-only log - this balancer's entries stay there for history"
    echo "note: the AMI is managed separately - 'run.sh ami $AMI_NAME egress-balancer delete' to remove it"
}

case "$3" in
    create)
        create
        ;;
    sync)
        sync_balancer
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh egress-balancer <name> {create|sync|delete}"
        exit 1
        ;;
esac
