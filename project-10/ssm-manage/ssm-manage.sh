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

statefile() {
    cat > "$STATE_FILE" <<EOF
export AWS_REGION="$AWS_REGION"

export ROLE_NAME="$ROLE_NAME"
export INSTANCE_PROFILE_NAME="$INSTANCE_PROFILE_NAME"
EOF

    echo "State saved to $STATE_FILE"
}


create() {
    # --------------------------------------------------
    # IAM role + instance profile
    # --------------------------------------------------
    # this is the only thing SSM actually needs: the instance calls out to the public SSM
    # API over the internet access it already has, so there's no VPC endpoint or security
    # group to create here - see README.md if that ever changes (a private/no-internet
    # subnet needs VPC interface endpoints instead).

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


    # --------------------------------------------------
    # Summary
    # --------------------------------------------------

    echo
    echo "========================================"
    echo "SSM management ready"
    echo "========================================"
    echo "IAM role:          $ROLE_NAME"
    echo "Instance profile:  $INSTANCE_PROFILE_NAME"
    echo "========================================"
    echo
    echo "note: a fresh instance profile can take a few seconds to propagate - if launching"
    echo "or associating against it fails right away, wait a moment and retry."
    echo
    echo "launch an instance with:  --iam-instance-profile Name=$INSTANCE_PROFILE_NAME"
    echo "attach to a running one:  aws ec2 associate-iam-instance-profile --instance-id <id> --iam-instance-profile Name=$INSTANCE_PROFILE_NAME"
    echo "connect with:             aws ssm start-session --target <instance-id>"

    statefile
}


destroy() {
    echo "=== Finding resources tagged Purpose=$Purpose ==="

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
