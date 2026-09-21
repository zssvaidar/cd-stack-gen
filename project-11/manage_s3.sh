# S3 bucket create/delete. Bucket names are global - unique across every AWS account, not
# just this one - so $BUCKET_NAME is derived from Purpose + <name> + the account id rather
# than using <name> alone, which would collide with anyone else's bucket of the same name.

[[ "$NAME" =~ ^(create|delete|keys|ssm|network|instances|s3)$ ]] && { echo "error: invalid name '$NAME'" >&2; exit 1; }
[[ -f "$STATE_FILE" ]] || { echo "no state file $STATE_FILE"; exit 1; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="${Purpose}-${NAME}-${ACCOUNT_ID}"

statefile() {
    {
        echo
        echo "# $BUCKET_NAME"
        echo "export AWS_REGION=\"$AWS_REGION\""
        echo "export BUCKET_NAME=\"$BUCKET_NAME\""
    } >> "$STATE_FILE"

    echo "State appended to $STATE_FILE"
}

create() {
    echo "=== Creating S3 bucket $BUCKET_NAME ==="

    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws s3api create-bucket \
            --region "$AWS_REGION" \
            --bucket "$BUCKET_NAME"
    else
        aws s3api create-bucket \
            --region "$AWS_REGION" \
            --bucket "$BUCKET_NAME" \
            --create-bucket-configuration "LocationConstraint=$AWS_REGION"
    fi


    # --------------------------------------------------
    # Block public access
    # --------------------------------------------------

    echo "=== Blocking public access ==="

    aws s3api put-public-access-block \
        --bucket "$BUCKET_NAME" \
        --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true


    # --------------------------------------------------
    # Default encryption
    # --------------------------------------------------

    echo "=== Enabling default encryption (SSE-S3) ==="

    aws s3api put-bucket-encryption \
        --bucket "$BUCKET_NAME" \
        --server-side-encryption-configuration \
        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'


    # --------------------------------------------------
    # Versioning
    # --------------------------------------------------

    echo "=== Enabling versioning ==="

    aws s3api put-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled


    # --------------------------------------------------
    # Tags
    # --------------------------------------------------

    echo "=== Tagging ==="

    aws s3api put-bucket-tagging \
        --bucket "$BUCKET_NAME" \
        --tagging "TagSet=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$NAME}]"


    # --------------------------------------------------
    # Summary
    # --------------------------------------------------

    echo
    echo "========================================"
    echo "Bucket created"
    echo "========================================"
    echo "Bucket:         $BUCKET_NAME"
    echo "Region:         $AWS_REGION"
    echo "Public access:  blocked"
    echo "Encryption:     SSE-S3 (AES256)"
    echo "Versioning:     enabled"
    echo "========================================"

    statefile
}

delete() {
    echo "=== Deleting S3 bucket $BUCKET_NAME ==="

    if ! aws s3api head-bucket --bucket "$BUCKET_NAME" >/dev/null 2>&1; then
        echo "no such bucket: $BUCKET_NAME"
        return
    fi

    echo "Emptying current objects..."
    aws s3 rm "s3://$BUCKET_NAME" --recursive >/dev/null 2>&1 || true

    # versioning means `s3 rm` above only added delete markers - it didn't remove the old
    # versions underneath them, and AWS refuses to delete a non-empty bucket either way. Purge
    # every version and delete marker that's left, whether or not versioning was ever enabled
    # (if it wasn't, both loops below just find nothing and no-op).
    echo "Purging object versions..."
    aws s3api list-object-versions --bucket "$BUCKET_NAME" \
        --query 'Versions[].[Key,VersionId]' --output text 2>/dev/null |
    while read -r key version_id; do
        [[ -n "$key" ]] && aws s3api delete-object --bucket "$BUCKET_NAME" --key "$key" --version-id "$version_id" >/dev/null
    done

    echo "Purging delete markers..."
    aws s3api list-object-versions --bucket "$BUCKET_NAME" \
        --query 'DeleteMarkers[].[Key,VersionId]' --output text 2>/dev/null |
    while read -r key version_id; do
        [[ -n "$key" ]] && aws s3api delete-object --bucket "$BUCKET_NAME" --key "$key" --version-id "$version_id" >/dev/null
    done

    echo "Deleting bucket: $BUCKET_NAME"
    aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"

    echo "=== Cleanup complete ==="
    echo "note: $STATE_FILE is an append-only log - $BUCKET_NAME's entry stays there for history"
}

case "$3" in
    create)
        create
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh s3 <name> {create|delete}"
        exit 1
        ;;
esac
