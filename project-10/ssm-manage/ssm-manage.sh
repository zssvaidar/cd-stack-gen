#!/usr/bin/env bash
# ln -s ../../project-9/wrapper wrapper

set -euo pipefail

source "wrapper/common/init.sh"
source "wrapper/config/.env"

unset_aws
set_root
whoami

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
Purpose="${PURPOSE:-testing}"
STATE_FILE=state/$Purpose.env

POLICY_ARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
ROLE_NAME="ssm-instance-role-$Purpose"
INSTANCE_PROFILE_NAME="ssm-instance-profile-$Purpose"
ENDPOINT_SG_NAME="ssm-endpoints-sg-$Purpose"

statefile() {
    cat > "$STATE_FILE" <<EOF
export AWS_REGION="$AWS_REGION"

export VPC_ID="$VPC_ID"

export ROLE_NAME="$ROLE_NAME"
export INSTANCE_PROFILE_NAME="$INSTANCE_PROFILE_NAME"

export ENDPOINT_SG="$ENDPOINT_SG"

export SSM_ENDPOINT_ID="$SSM_ENDPOINT_ID"
export SSMMESSAGES_ENDPOINT_ID="$SSMMESSAGES_ENDPOINT_ID"
export EC2MESSAGES_ENDPOINT_ID="$EC2MESSAGES_ENDPOINT_ID"
EOF

    echo "State saved to $STATE_FILE"
}


create() {
    echo "=== Looking up VPC + subnets tagged Purpose=$Purpose ==="

    VPC_ID=$(aws ec2 describe-vpcs \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" \
        --query 'Vpcs[0].VpcId' \
        --output text)

    if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
        echo "no vpc tagged Purpose=$Purpose - provision the network first" >&2
        exit 1
    fi

    VPC_CIDR=$(aws ec2 describe-vpcs \
        --region "$AWS_REGION" \
        --vpc-ids "$VPC_ID" \
        --query 'Vpcs[0].CidrBlock' \
        --output text)

    SUBNET_IDS=$(aws ec2 describe-subnets \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" \
        --query 'Subnets[*].SubnetId' \
        --output text)

    if [ -z "$SUBNET_IDS" ]; then
        echo "no subnets tagged Purpose=$Purpose - provision the network first" >&2
        exit 1
    fi

    echo "VPC:     $VPC_ID ($VPC_CIDR)"
    echo "Subnets: $SUBNET_IDS"


    # --------------------------------------------------
    # IAM role + instance profile
    # --------------------------------------------------

    echo "=== Creating IAM role ==="

    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        --tags "Key=Purpose,Value=$Purpose" \
        --output text >/dev/null

    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "$POLICY_ARN"

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

    # a fresh instance profile isn't usable by ec2 the instant iam returns it - it needs a
    # few seconds to propagate, or launching/associating against it fails intermittently
    echo "waiting for instance profile to propagate..."
    sleep 10


    # --------------------------------------------------
    # Security group for the interface endpoints
    # --------------------------------------------------

    echo "=== Creating endpoint security group ==="

    ENDPOINT_SG=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$ENDPOINT_SG_NAME" \
        --description "HTTPS from the VPC to SSM interface endpoints" \
        --vpc-id "$VPC_ID" \
        --tag-specifications \
        "ResourceType=security-group,Tags=[{Key=Purpose,Value=$Purpose}]" \
        --query 'GroupId' \
        --output text)

    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$ENDPOINT_SG" \
        --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$VPC_CIDR,Description=\"vpc -> ssm endpoints\"}]"

    echo "Endpoint SG: $ENDPOINT_SG"


    # --------------------------------------------------
    # Interface endpoints: ssm, ssmmessages, ec2messages
    # --------------------------------------------------
    # these three are what let an instance reach Session Manager without any inbound rule
    # on its own security group, and without a route to the internet at all - handy for a
    # private subnet with no NAT gateway.

    echo "=== Creating VPC endpoints ==="

    SSM_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --service-name "com.amazonaws.$AWS_REGION.ssm" \
        --vpc-endpoint-type Interface \
        --subnet-ids $SUBNET_IDS \
        --security-group-ids "$ENDPOINT_SG" \
        --private-dns-enabled \
        --tag-specifications \
        "ResourceType=vpc-endpoint,Tags=[{Key=Purpose,Value=$Purpose}]" \
        --query 'VpcEndpoint.VpcEndpointId' \
        --output text)

    SSMMESSAGES_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --service-name "com.amazonaws.$AWS_REGION.ssmmessages" \
        --vpc-endpoint-type Interface \
        --subnet-ids $SUBNET_IDS \
        --security-group-ids "$ENDPOINT_SG" \
        --private-dns-enabled \
        --tag-specifications \
        "ResourceType=vpc-endpoint,Tags=[{Key=Purpose,Value=$Purpose}]" \
        --query 'VpcEndpoint.VpcEndpointId' \
        --output text)

    EC2MESSAGES_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --service-name "com.amazonaws.$AWS_REGION.ec2messages" \
        --vpc-endpoint-type Interface \
        --subnet-ids $SUBNET_IDS \
        --security-group-ids "$ENDPOINT_SG" \
        --private-dns-enabled \
        --tag-specifications \
        "ResourceType=vpc-endpoint,Tags=[{Key=Purpose,Value=$Purpose}]" \
        --query 'VpcEndpoint.VpcEndpointId' \
        --output text)

    echo "ssm endpoint:         $SSM_ENDPOINT_ID"
    echo "ssmmessages endpoint: $SSMMESSAGES_ENDPOINT_ID"
    echo "ec2messages endpoint: $EC2MESSAGES_ENDPOINT_ID"


    # --------------------------------------------------
    # Summary
    # --------------------------------------------------

    echo
    echo "========================================"
    echo "SSM management ready"
    echo "========================================"
    echo "VPC:                  $VPC_ID"
    echo "IAM role:              $ROLE_NAME"
    echo "Instance profile:      $INSTANCE_PROFILE_NAME"
    echo "Endpoint SG:           $ENDPOINT_SG"
    echo "ssm endpoint:          $SSM_ENDPOINT_ID"
    echo "ssmmessages endpoint:  $SSMMESSAGES_ENDPOINT_ID"
    echo "ec2messages endpoint:  $EC2MESSAGES_ENDPOINT_ID"
    echo "========================================"
    echo
    echo "launch an instance with:  --iam-instance-profile Name=$INSTANCE_PROFILE_NAME"
    echo "attach to a running one:  aws ec2 associate-iam-instance-profile --instance-id <id> --iam-instance-profile Name=$INSTANCE_PROFILE_NAME"
    echo "connect with:             aws ssm start-session --target <instance-id>"

    statefile
}


destroy() {
    echo "=== Finding resources tagged Purpose=$Purpose ==="

    # --------------------------------------------------
    # VPC endpoints
    # --------------------------------------------------

    ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=vpc-endpoint-state,Values=available,pending" \
        --query 'VpcEndpoints[*].VpcEndpointId' \
        --output text)

    if [ -n "$ENDPOINT_IDS" ]; then
        echo "Deleting vpc endpoints: $ENDPOINT_IDS"

        aws ec2 delete-vpc-endpoints \
            --region "$AWS_REGION" \
            --vpc-endpoint-ids $ENDPOINT_IDS

        echo "waiting for endpoints to finish deleting..."
        aws ec2 wait vpc-endpoint-deleted \
            --region "$AWS_REGION" \
            --vpc-endpoint-ids $ENDPOINT_IDS
    fi


    # --------------------------------------------------
    # Endpoint security group
    # --------------------------------------------------

    for sg in $(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=group-name,Values=$ENDPOINT_SG_NAME" \
        --query 'SecurityGroups[*].GroupId' \
        --output text); do

        echo "Deleting security group: $sg"

        aws ec2 delete-security-group \
            --region "$AWS_REGION" \
            --group-id "$sg"
    done


    # --------------------------------------------------
    # Instance profile (iam is global - no --region)
    # --------------------------------------------------

    if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
        echo "Removing role from instance profile: $INSTANCE_PROFILE_NAME"

        aws iam remove-role-from-instance-profile \
            --instance-profile-name "$INSTANCE_PROFILE_NAME" \
            --role-name "$ROLE_NAME" 2>/dev/null || true

        echo "Deleting instance profile: $INSTANCE_PROFILE_NAME"

        aws iam delete-instance-profile \
            --instance-profile-name "$INSTANCE_PROFILE_NAME"
    fi


    # --------------------------------------------------
    # IAM role
    # --------------------------------------------------

    if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
        echo "Detaching policy from role: $ROLE_NAME"

        aws iam detach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn "$POLICY_ARN"

        echo "Deleting role: $ROLE_NAME"

        aws iam delete-role \
            --role-name "$ROLE_NAME"
    fi

    rm -f "$STATE_FILE"

    echo "=== Cleanup complete ==="
}


# ------------------------------------------------------
# Command
# ------------------------------------------------------

case "$1" in
    create)
        create
        ;;
    destroy)
        destroy
        ;;
    *)
        echo "Usage: $0 {create|destroy}"
        exit 1
        ;;
esac
