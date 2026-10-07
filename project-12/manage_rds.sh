# Postgres via RDS - the real DATABASE_URL backing bun-hydrate's web/worker services, replacing
# the default sqlite://:memory: (always re-migrated on start, loses data on every restart).
# Reuses project-11's VPC/db-tier subnet rather than provisioning a second network; only
# creates what RDS itself needs on top of that: a second-AZ subnet (RDS subnet groups need at
# least 2 AZs, and project-11's subnets were all created without an explicit AZ, so nothing
# guarantees they're spread out), a subnet group, a dedicated SG, and the instance itself.
# manage_ecs_tunnel.sh/manage_ecs_alb.sh and manage_ecs_worker.sh all read $DATABASE_URL_PARAM
# from this script's state to wire it in.
#
# This second-AZ subnet is this script's own (tagged rds-standby), not shared with
# manage_ecs_alb.sh's own second-AZ subnet for the ALB - sharing one would mean trusting that
# RDS's AZ2 and the ALB's AZ1 never land in the same AZ, which nothing here guarantees either.
# Two independent subnets, each verified against the one AZ it actually needs to differ from,
# costs one more /24 and removes that risk entirely.

source "$STATE_FILE"

[[ "$NAME" =~ ^(create|delete|rds|worker|tunnel|alb)$ ]] && { echo "error: invalid name '$NAME'" >&2; exit 1; }

DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-db.t4g.micro}"
DB_ALLOCATED_STORAGE="${DB_ALLOCATED_STORAGE:-20}"
DB_NAME="${DB_NAME:-hydrate}"
DB_MASTER_USERNAME="${DB_MASTER_USERNAME:-hydrate}"

: "${VPC_ID:?no VPC_ID in \$STATE_FILE - run '../project-11/run.sh network create' first}"
: "${DB_SUBNET_ID:?no DB_SUBNET_ID in \$STATE_FILE - run '../project-11/run.sh network create' first}"
: "${APP_SG:?no APP_SG in \$STATE_FILE - run '../project-11/run.sh network create' first}"

# deterministic, not looked up - delete() recomputes the exact same identifiers rather than
# discovering them by tag (RDS instance tags aren't queryable with the same ease as EC2's).
DB_INSTANCE_ID="${Purpose}-${NAME}"
DATABASE_URL_PARAM="/${Purpose}/${NAME}/database-url"
RDS_SUBNET_GROUP="${Purpose}-${NAME}-subnet-group"

statefile() {
    {
        echo
        echo "# $NAME (rds)"
        echo "export AWS_REGION=\"$AWS_REGION\""
        echo "export RDS_INSTANCE_ID=\"$DB_INSTANCE_ID\""
        echo "export RDS_SG=\"$RDS_SG\""
        echo "export RDS_SUBNET_GROUP=\"$RDS_SUBNET_GROUP\""
        echo "export RDS_ENDPOINT=\"$RDS_ENDPOINT\""
        echo "export DATABASE_URL_PARAM=\"$DATABASE_URL_PARAM\""
        echo "export AZ2_SUBNET_ID=\"$AZ2_SUBNET_ID\""
    } >> "$STATE_FILE"

    echo "State appended to $STATE_FILE"
}

# shared with manage_ecs_alb.sh, which needs the same second AZ for its ALB - found by tag
# first so either script can create it once and the other just reuses it.
ensure_az2_subnet() {
    AZ2_SUBNET_ID=$(aws ec2 describe-subnets \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Tier,Values=rds-standby" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null)

    if [[ -n "$AZ2_SUBNET_ID" && "$AZ2_SUBNET_ID" != "None" ]]; then
        echo "Reusing existing rds-standby subnet: $AZ2_SUBNET_ID"
        return
    fi

    local primary_az az2
    primary_az=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$DB_SUBNET_ID" \
        --query 'Subnets[0].AvailabilityZone' --output text)
    az2=$(aws ec2 describe-availability-zones --region "$AWS_REGION" \
        --filters "Name=state,Values=available" \
        --query "AvailabilityZones[?ZoneName!=\`$primary_az\`].ZoneName | [0]" --output text)

    AZ2_SUBNET_ID=$(aws ec2 create-subnet \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --cidr-block "10.0.6.0/24" \
        --availability-zone "$az2" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Purpose,Value=$Purpose},{Key=Tier,Value=rds-standby}]" \
        --query 'Subnet.SubnetId' --output text)

    [[ -n "$PUBLIC_RT_ID" ]] && aws ec2 associate-route-table \
        --region "$AWS_REGION" --route-table-id "$PUBLIC_RT_ID" --subnet-id "$AZ2_SUBNET_ID" >/dev/null

    echo "Created rds-standby subnet: $AZ2_SUBNET_ID (az=$az2)"
}

create() {
    ensure_az2_subnet

    echo "=== Creating DB subnet group ==="
    aws rds create-db-subnet-group \
        --region "$AWS_REGION" \
        --db-subnet-group-name "$RDS_SUBNET_GROUP" \
        --db-subnet-group-description "bun-hydrate RDS - $Purpose/$NAME" \
        --subnet-ids "$DB_SUBNET_ID" "$AZ2_SUBNET_ID" \
        --tags "Key=Purpose,Value=$Purpose" "Key=Name,Value=$NAME" \
        >/dev/null

    echo "=== Creating security group ==="
    RDS_SG=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "rds-${Purpose}-${NAME}" \
        --description "RDS Postgres - $Purpose/$NAME" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$NAME},{Key=Role,Value=rds}]" \
        --query 'GroupId' --output text)

    # anything using APP_SG - the ECS tasks included, see manage_ecs_*.sh - can reach
    # Postgres; nothing else can.
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$RDS_SG" \
        --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$APP_SG,Description=app tier}]" \
        >/dev/null

    echo "Security group: $RDS_SG (5432 from $APP_SG)"

    echo "=== Creating RDS instance (this takes several minutes) ==="
    DB_MASTER_PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)

    aws rds create-db-instance \
        --region "$AWS_REGION" \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --engine postgres \
        --db-instance-class "$DB_INSTANCE_CLASS" \
        --allocated-storage "$DB_ALLOCATED_STORAGE" \
        --master-username "$DB_MASTER_USERNAME" \
        --master-user-password "$DB_MASTER_PASSWORD" \
        --db-name "$DB_NAME" \
        --db-subnet-group-name "$RDS_SUBNET_GROUP" \
        --vpc-security-group-ids "$RDS_SG" \
        --backup-retention-period 1 \
        --no-multi-az \
        --no-publicly-accessible \
        --storage-encrypted \
        --tags "Key=Purpose,Value=$Purpose" "Key=Name,Value=$NAME" \
        >/dev/null

    echo "waiting for $DB_INSTANCE_ID to become available..."
    aws rds wait db-instance-available --region "$AWS_REGION" --db-instance-identifier "$DB_INSTANCE_ID"

    RDS_ENDPOINT=$(aws rds describe-db-instances \
        --region "$AWS_REGION" \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --query 'DBInstances[0].Endpoint.Address' --output text)
    RDS_PORT=$(aws rds describe-db-instances \
        --region "$AWS_REGION" \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --query 'DBInstances[0].Endpoint.Port' --output text)

    DATABASE_URL="postgres://${DB_MASTER_USERNAME}:${DB_MASTER_PASSWORD}@${RDS_ENDPOINT}:${RDS_PORT}/${DB_NAME}"

    aws ssm put-parameter \
        --region "$AWS_REGION" \
        --name "$DATABASE_URL_PARAM" \
        --type SecureString \
        --value "$DATABASE_URL" \
        --overwrite \
        >/dev/null

    echo
    echo "========================================"
    echo "RDS instance created"
    echo "========================================"
    echo "Instance:        $DB_INSTANCE_ID"
    echo "Endpoint:        $RDS_ENDPOINT:$RDS_PORT"
    echo "DATABASE_URL at: $DATABASE_URL_PARAM (SSM SecureString)"
    echo "========================================"

    statefile
}

delete() {
    echo "=== Deleting RDS instance $DB_INSTANCE_ID ==="

    if aws rds describe-db-instances --region "$AWS_REGION" --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1; then
        aws rds delete-db-instance \
            --region "$AWS_REGION" \
            --db-instance-identifier "$DB_INSTANCE_ID" \
            --skip-final-snapshot \
            >/dev/null

        echo "waiting for deletion..."
        aws rds wait db-instance-deleted --region "$AWS_REGION" --db-instance-identifier "$DB_INSTANCE_ID"
    else
        echo "no instance $DB_INSTANCE_ID found"
    fi

    echo "Deleting subnet group: $RDS_SUBNET_GROUP"
    aws rds delete-db-subnet-group --region "$AWS_REGION" --db-subnet-group-name "$RDS_SUBNET_GROUP" 2>/dev/null || true

    for sg in $(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$NAME" "Name=tag:Role,Values=rds" \
        --query 'SecurityGroups[*].GroupId' --output text); do
        echo "Deleting security group: $sg"
        aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg"
    done

    echo "Deleting SSM parameter: $DATABASE_URL_PARAM"
    aws ssm delete-parameter --region "$AWS_REGION" --name "$DATABASE_URL_PARAM" 2>/dev/null || true

    echo "=== Cleanup complete ==="
    echo "note: the rds-standby subnet is left in place - harmless and reused if you run"
    echo "'run.sh rds $NAME create' again"
}

case "$3" in
    create)
        create
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh rds <name> {create|delete}"
        exit 1
        ;;
esac
