
CIDR="${CIDR:-10.0.0.0/16}"
DATE="$(date +%Y-%m-%d)"

[[ -f "$STATE_FILE" ]] || { echo "no state file $STATE_FILE"; exit 1; }

statefile() {
    cat >> "$STATE_FILE" <<EOF
# $DATE
export AWS_REGION="$AWS_REGION"

export VPC_ID="$VPC_ID"

export BASTION_SG="$BASTION_SG"
export APP_SG="$APP_SG"
export DB_SG="$DB_SG"

export BASTION_SUBNET_ID="$BASTION_SUBNET_ID"
export APP_SUBNET_ID="$APP_SUBNET_ID"
export DB_SUBNET_ID="$DB_SUBNET_ID"

export IGW_ID="$IGW_ID"
export PUBLIC_RT_ID="$PUBLIC_RT_ID"

export BASTION_ASSOC_ID="$BASTION_ASSOC_ID"
export APP_ASSOC_ID="$APP_ASSOC_ID"
export DB_ASSOC_ID="$DB_ASSOC_ID"
EOF

    echo "State saved to $STATE_FILE"
}

create() {
    echo "=== Creating VPC ==="

    VPC_ID=$(aws ec2 create-vpc \
        --region "$AWS_REGION" \
        --cidr-block "$CIDR" \
        --tag-specifications \
        "ResourceType=vpc,Tags=[{Key=Purpose,Value=$Purpose}]" \
        --query 'Vpc.VpcId' \
        --output text)

    echo "VPC: $VPC_ID"


    # --------------------------------------------------
    # Security Groups
    # --------------------------------------------------

    echo "=== Creating Security Groups ==="

    BASTION_SG=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name bastion-sg \
        --description "Bastion host - SSH jump box" \
        --vpc-id "$VPC_ID" \
        --tag-specifications \
        "ResourceType=security-group,Tags=[{Key=Purpose,Value=$Purpose}]" \
        --query 'GroupId' \
        --output text)

    APP_SG=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name app-sg \
        --description "Application tier" \
        --vpc-id "$VPC_ID" \
        --tag-specifications \
        "ResourceType=security-group,Tags=[{Key=Purpose,Value=$Purpose}]" \
        --query 'GroupId' \
        --output text)

    DB_SG=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name db-sg \
        --description "Database tier" \
        --vpc-id "$VPC_ID" \
        --tag-specifications \
        "ResourceType=security-group,Tags=[{Key=Purpose,Value=$Purpose}]" \
        --query 'GroupId' \
        --output text)

    echo "Bastion SG: $BASTION_SG"
    echo "App SG:     $APP_SG"
    echo "DB SG:      $DB_SG"


    # --------------------------------------------------
    # Subnets
    # --------------------------------------------------

    echo "=== Creating Subnets ==="

    BASTION_SUBNET_ID=$(aws ec2 create-subnet \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --cidr-block "10.0.1.0/24" \
        --tag-specifications \
        "ResourceType=subnet,Tags=[{Key=Purpose,Value=$Purpose},{Key=Tier,Value=bastion}]" \
        --query 'Subnet.SubnetId' \
        --output text)

    APP_SUBNET_ID=$(aws ec2 create-subnet \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --cidr-block "10.0.2.0/24" \
        --tag-specifications \
        "ResourceType=subnet,Tags=[{Key=Purpose,Value=$Purpose},{Key=Tier,Value=app}]" \
        --query 'Subnet.SubnetId' \
        --output text)

    DB_SUBNET_ID=$(aws ec2 create-subnet \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --cidr-block "10.0.3.0/24" \
        --tag-specifications \
        "ResourceType=subnet,Tags=[{Key=Purpose,Value=$Purpose},{Key=Tier,Value=db}]" \
        --query 'Subnet.SubnetId' \
        --output text)

    echo "Bastion subnet: $BASTION_SUBNET_ID"
    echo "App subnet:     $APP_SUBNET_ID"
    echo "DB subnet:      $DB_SUBNET_ID"


    # --------------------------------------------------
    # Internet Gateway
    # --------------------------------------------------

    echo "=== Creating Internet Gateway ==="

    IGW_ID=$(aws ec2 create-internet-gateway \
        --region "$AWS_REGION" \
        --tag-specifications \
        "ResourceType=internet-gateway,Tags=[{Key=Purpose,Value=$Purpose}]" \
        --query 'InternetGateway.InternetGatewayId' \
        --output text)

    echo "Internet Gateway: $IGW_ID"


    # --------------------------------------------------
    # Attach Internet Gateway to VPC
    # --------------------------------------------------

    echo "=== Attaching Internet Gateway ==="

    aws ec2 attach-internet-gateway \
        --region "$AWS_REGION" \
        --internet-gateway-id "$IGW_ID" \
        --vpc-id "$VPC_ID"


    # --------------------------------------------------
    # Route Table
    # --------------------------------------------------

    echo "=== Creating Public Route Table ==="

    PUBLIC_RT_ID=$(aws ec2 create-route-table \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --tag-specifications \
        "ResourceType=route-table,Tags=[{Key=Purpose,Value=$Purpose},{Key=Tier,Value=public}]" \
        --query 'RouteTable.RouteTableId' \
        --output text)

    echo "Public Route Table: $PUBLIC_RT_ID"


    # --------------------------------------------------
    # Default Internet Route
    # --------------------------------------------------

    echo "=== Creating Internet Route ==="

    aws ec2 create-route \
        --region "$AWS_REGION" \
        --route-table-id "$PUBLIC_RT_ID" \
        --destination-cidr-block "0.0.0.0/0" \
        --gateway-id "$IGW_ID"


    # --------------------------------------------------
    # Associate Bastion Subnet with Public Route Table
    # --------------------------------------------------

    echo "=== Associating Bastion,App,Db Subnet ==="

    BASTION_ASSOC_ID=$(aws ec2 associate-route-table \
        --region "$AWS_REGION" \
        --route-table-id "$PUBLIC_RT_ID" \
        --subnet-id "$BASTION_SUBNET_ID" \
        --query 'AssociationId' \
        --output text)


    APP_ASSOC_ID=$(aws ec2 associate-route-table \
        --region "$AWS_REGION" \
        --route-table-id "$PUBLIC_RT_ID" \
        --subnet-id "$APP_SUBNET_ID" \
        --query 'AssociationId' \
        --output text)

    DB_ASSOC_ID=$(aws ec2 associate-route-table \
        --region "$AWS_REGION" \
        --route-table-id "$PUBLIC_RT_ID" \
        --subnet-id "$DB_SUBNET_ID" \
        --query 'AssociationId' \
        --output text)

    echo "Association: $BASTION_ASSOC_ID"

    echo "Bastion associate subnet: $BASTION_ASSOC_ID"
    echo "App     associate subnet: $APP_ASSOC_ID"
    echo "DB      associate subnet: $DB_ASSOC_ID"

    # --------------------------------------------------
    # Summary
    # --------------------------------------------------

    echo
    echo "========================================"
    echo "Network created"
    echo "========================================"
    echo "VPC:              $VPC_ID"
    echo "Bastion SG:       $BASTION_SG"
    echo "App SG:            $APP_SG"
    echo "DB SG:             $DB_SG"
    echo "Bastion subnet:   $BASTION_SUBNET_ID"
    echo "App subnet:       $APP_SUBNET_ID"
    echo "DB subnet:        $DB_SUBNET_ID"
    echo "Internet Gateway: $IGW_ID"
    echo "Public RT:        $PUBLIC_RT_ID"
    echo "========================================"

    statefile
}


delete() {
    echo "=== Finding resources ==="

    # --------------------------------------------------
    # Find route tables
    # --------------------------------------------------

    for rt in $(aws ec2 describe-route-tables \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" \
        --query 'RouteTables[*].RouteTableId' \
        --output text); do

        echo "Deleting route table: $rt"

        # Find and remove subnet associations
        for assoc in $(aws ec2 describe-route-tables \
            --region "$AWS_REGION" \
            --route-table-ids "$rt" \
            --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
            --output text); do

            echo "Disassociating: $assoc"

            aws ec2 disassociate-route-table \
                --region "$AWS_REGION" \
                --association-id "$assoc"
        done

        aws ec2 delete-route-table \
            --region "$AWS_REGION" \
            --route-table-id "$rt"
    done


    # --------------------------------------------------
    # Delete Security Groups
    # --------------------------------------------------

    for sg in $(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" \
        --query 'SecurityGroups[*].GroupId' \
        --output text); do

        echo "Deleting security group: $sg"

        aws ec2 delete-security-group \
            --region "$AWS_REGION" \
            --group-id "$sg"
    done


    # --------------------------------------------------
    # Internet Gateway
    # --------------------------------------------------

    for igw in $(aws ec2 describe-internet-gateways \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" \
        --query 'InternetGateways[*].InternetGatewayId' \
        --output text); do

        echo "Detaching Internet Gateway: $igw"

        VPC_FOR_IGW=$(aws ec2 describe-internet-gateways \
            --region "$AWS_REGION" \
            --internet-gateway-ids "$igw" \
            --query 'InternetGateways[0].Attachments[0].VpcId' \
            --output text)

        if [ "$VPC_FOR_IGW" != "None" ] && [ -n "$VPC_FOR_IGW" ]; then
            aws ec2 detach-internet-gateway \
                --region "$AWS_REGION" \
                --internet-gateway-id "$igw" \
                --vpc-id "$VPC_FOR_IGW"
        fi

        echo "Deleting Internet Gateway: $igw"

        aws ec2 delete-internet-gateway \
            --region "$AWS_REGION" \
            --internet-gateway-id "$igw"
    done


    # --------------------------------------------------
    # Delete Subnets
    # --------------------------------------------------

    for subnet in $(aws ec2 describe-subnets \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" \
        --query 'Subnets[*].SubnetId' \
        --output text); do

        echo "Deleting subnet: $subnet"

        aws ec2 delete-subnet \
            --region "$AWS_REGION" \
            --subnet-id "$subnet"
    done


    # --------------------------------------------------
    # Delete VPC
    # --------------------------------------------------

    for vpc in $(aws ec2 describe-vpcs \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" \
        --query 'Vpcs[*].VpcId' \
        --output text); do

        echo "Deleting VPC: $vpc"

        aws ec2 delete-vpc \
            --region "$AWS_REGION" \
            --vpc-id "$vpc"
    done

    echo "=== Cleanup complete ==="
}


# ------------------------------------------------------
# Command
# ------------------------------------------------------

case "$2" in
    create)
        create
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh network {create|delete}"
        exit 1
        ;;
esac
