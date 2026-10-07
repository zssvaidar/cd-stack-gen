#!/usr/bin/env bash
# Temporarily give one instance a public IP (Elastic IP) - e.g. so its SSM agent can reach AWS
# on a network with no NAT, or to open the site from a browser - then take it away again.
#
# Which instance, first match wins:
#   INSTANCE_ID=i-...        use this id as-is, no lookup
#   ./connect.sh <action> <name>
#   INSTANCE_NAME=<name>     from the environment
#   DEFAULT_INSTANCE_NAME    below
# A name is the instance's Name tag as run.sh gives it (`<name>-<i>` from `run.sh instances`,
# `<name>-<env-type>-<i>` from `run.sh instance-ami`), looked up live in AWS under this
# Purpose - not from the state file, which keeps entries for instances that are long gone.

source "wrapper/common/init.sh"
source "wrapper/config/.env"

unset_aws
set_root
whoami

DEFAULT_INSTANCE_NAME="web-docker-1"

Purpose="${PURPOSE:-testing}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
ACTION="$1"
INSTANCE_NAME="${2:-${INSTANCE_NAME:-$DEFAULT_INSTANCE_NAME}}"

resolve_instance() {
    if [[ -n "$INSTANCE_ID" ]]; then
        echo "using INSTANCE_ID=$INSTANCE_ID from the environment"
        return
    fi

    local ids
    ids=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=tag:Purpose,Values=$Purpose" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text)

    local count
    count=$(wc -w <<< "$ids")
    [[ "$count" -eq 0 ]] && { echo "error: no instance named '$INSTANCE_NAME' (Purpose=$Purpose) in $AWS_REGION" >&2; exit 1; }
    [[ "$count" -gt 1 ]] && { echo "error: '$INSTANCE_NAME' matches $count instances ($ids) - set INSTANCE_ID to pick one" >&2; exit 1; }

    INSTANCE_ID="$ids"
    echo "$INSTANCE_NAME -> $INSTANCE_ID"
}

attach_eip() {
    # already has one - reuse it instead of allocating a second (associate-address would
    # silently swap it in and leave the old EIP allocated, idle and billed)
    local existing
    existing=$(aws ec2 describe-addresses \
        --filters "Name=instance-id,Values=$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Addresses[0].PublicIp' --output text)
    if [[ -n "$existing" && "$existing" != "None" ]]; then
        echo "$INSTANCE_ID already has $existing"
        EIP_CREATED=false
        return
    fi

    local alloc
    alloc=$(aws ec2 allocate-address \
        --domain vpc --region "$AWS_REGION" \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$INSTANCE_NAME}]" \
        --query '[AllocationId,PublicIp]' --output text) || exit 1
    read -r ALLOCATION_ID PUBLIC_IP <<< "$alloc"

    if ! ASSOCIATION_ID=$(aws ec2 associate-address \
        --instance-id "$INSTANCE_ID" \
        --allocation-id "$ALLOCATION_ID" \
        --region "$AWS_REGION" \
        --query 'AssociationId' --output text); then
        echo "error: associate failed - releasing $PUBLIC_IP so it isn't left allocated" >&2
        aws ec2 release-address --allocation-id "$ALLOCATION_ID" --region "$AWS_REGION"
        exit 1
    fi

    EIP_CREATED=true
    echo "attached $PUBLIC_IP to $INSTANCE_ID"
    echo "  AllocationId=$ALLOCATION_ID  AssociationId=$ASSOCIATION_ID"
}

detach_eip() {
    local addr
    addr=$(aws ec2 describe-addresses \
        --filters "Name=instance-id,Values=$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Addresses[0].[AssociationId,AllocationId,PublicIp]' --output text)
    read -r ASSOCIATION_ID ALLOCATION_ID PUBLIC_IP <<< "$addr"

    [[ "$ASSOCIATION_ID" == "None" || -z "$ASSOCIATION_ID" ]] && { echo "no EIP attached to $INSTANCE_ID"; return; }

    aws ec2 disassociate-address --association-id "$ASSOCIATION_ID" --region "$AWS_REGION"

    # attach always allocates a fresh EIP, so keeping the old one would pile up idle, billed
    # addresses across attach/detach cycles - release by default, KEEP_EIP=true to hold on to it
    if [[ "$KEEP_EIP" == "true" ]]; then
        echo "detached $PUBLIC_IP from $INSTANCE_ID (AllocationId=$ALLOCATION_ID still allocated to you)"
    else
        aws ec2 release-address --allocation-id "$ALLOCATION_ID" --region "$AWS_REGION"
        echo "detached and released $PUBLIC_IP from $INSTANCE_ID"
    fi
}

# instead of a fixed sleep: the SSM agent needs a moment after the EIP lands to reach AWS
# and report in - poll until it does (or give up after ~2 min)
wait_ssm() {
    echo "waiting for SSM agent on $INSTANCE_ID..."
    for _ in $(seq 1 24); do
        status=$(aws ssm describe-instance-information \
            --region "$AWS_REGION" \
            --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
            --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
        [[ "$status" == "Online" ]] && { echo "SSM agent online"; return; }
        sleep 5
    done
    echo "error: SSM agent on $INSTANCE_ID never came online (instance profile attached? agent running?)" >&2
    return 1
}

session() {
    wait_ssm || exit 1
    aws ssm start-session --target "$INSTANCE_ID" --region "$AWS_REGION"
}

usage() {
    echo "Usage: connect.sh {attach|detach|session|connect} [instance-name]"
    echo "  attach   allocate an EIP and associate it with the instance"
    echo "  detach   disassociate and release it (KEEP_EIP=true to keep it allocated)"
    echo "  session  open an SSM session (waits for the agent to be online)"
    echo "  connect  attach, open a session, detach again when the session ends"
    echo "instance: INSTANCE_ID, else [instance-name], else INSTANCE_NAME, else '$DEFAULT_INSTANCE_NAME'"
    exit 1
}

case "$ACTION" in
    attach)  resolve_instance; attach_eip ;;
    detach)  resolve_instance; detach_eip ;;
    session) resolve_instance; session ;;
    connect)
        resolve_instance
        attach_eip
        # detach even if the session errors or is interrupted with Ctrl-C - but only an EIP
        # this run attached; one that was already there before stays put
        [[ "$EIP_CREATED" == "true" ]] && trap detach_eip EXIT
        session
        ;;
    *) usage ;;
esac
