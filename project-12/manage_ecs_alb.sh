# Web tier via an Application Load Balancer - the AWS-native answer to "ECS + load
# balancing": ECS registers/deregisters each task's IP in the target group automatically as
# the service scales. Tasks stay private (project-11's app-tier subnet, no public IP); only
# the ALB itself is internet-facing, in two public subnets across two AZs (a hard ALB
# requirement - project-11's subnets were all created without an explicit AZ, so nothing
# guarantees even two of them differ). Run `run.sh worker <name> create` first (migrations).
#
# The ECS cluster is shared with manage_ecs_worker.sh/manage_ecs_tunnel.sh - delete() here
# only removes what this script owns: the service, target group, listener, ALB, and the
# dedicated task/ALB security groups. Never the cluster.

source "$STATE_FILE"

[[ "$NAME" =~ ^(create|delete|rds|worker|tunnel|alb)$ ]] && { echo "error: invalid name '$NAME'" >&2; exit 1; }

: "${VPC_ID:?no VPC_ID in \$STATE_FILE - run '../project-11/run.sh network create' first}"
: "${APP_SUBNET_ID:?no APP_SUBNET_ID in \$STATE_FILE - run '../project-11/run.sh network create' first}"
: "${BASTION_SUBNET_ID:?no BASTION_SUBNET_ID in \$STATE_FILE - run '../project-11/run.sh network create' first}"
: "${DATABASE_URL_PARAM:?no DATABASE_URL_PARAM in \$STATE_FILE - run 'run.sh rds $NAME create' first}"

IMAGE_TAG="${IMAGE_TAG:-latest}"
DESIRED_COUNT="${DESIRED_COUNT:-1}"

CLUSTER="${Purpose}-${NAME}"
SERVICE_NAME="${NAME}-web-alb"
TASK_FAMILY="${Purpose}-${NAME}-web-alb"
LOG_GROUP="/ecs/${Purpose}-${NAME}"
EXEC_ROLE_NAME="ecsTaskExecutionRole-${Purpose}-${NAME}-alb"
ALB_NAME="${Purpose}-${NAME}-alb"
TG_NAME="${Purpose}-${NAME}-tg"

statefile() {
    {
        echo
        echo "# $NAME (ecs web, alb)"
        echo "export AWS_REGION=\"$AWS_REGION\""
        echo "export ECS_CLUSTER=\"$CLUSTER\""
        echo "export ALB_SERVICE=\"$SERVICE_NAME\""
        echo "export ALB_TASK_FAMILY=\"$TASK_FAMILY\""
        echo "export ALB_EXEC_ROLE_ARN=\"$EXEC_ROLE_ARN\""
        echo "export ECR_REPO_URI=\"$ECR_REPO_URI\""
        echo "export ALB_ARN=\"$ALB_ARN\""
        echo "export ALB_DNS_NAME=\"$ALB_DNS_NAME\""
        echo "export ALB_SG=\"$ALB_SG\""
        echo "export ALB_TASK_SG=\"$ALB_TASK_SG\""
        echo "export ALB_LISTENER_ARN=\"$LISTENER_ARN\""
        echo "export ALB_TARGET_GROUP_ARN=\"$TG_ARN\""
        echo "export ALB_AZ2_SUBNET_ID=\"$AZ2_SUBNET_ID\""
    } >> "$STATE_FILE"

    echo "State appended to $STATE_FILE"
}

ensure_ecr_repo() {
    local repo="${Purpose}-${NAME}"
    ECR_REPO_URI=$(aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$repo" \
        --query 'repositories[0].repositoryUri' --output text 2>/dev/null)

    if [[ -z "$ECR_REPO_URI" || "$ECR_REPO_URI" == "None" ]]; then
        ECR_REPO_URI=$(aws ecr create-repository \
            --region "$AWS_REGION" \
            --repository-name "$repo" \
            --image-scanning-configuration scanOnPush=true \
            --tags "Key=Purpose,Value=$Purpose" "Key=Name,Value=$NAME" \
            --query 'repository.repositoryUri' --output text)
        echo "Created ECR repo: $ECR_REPO_URI"
    else
        echo "Reusing ECR repo: $ECR_REPO_URI"
    fi
}

ensure_log_group() {
    aws logs create-log-group --region "$AWS_REGION" --log-group-name "$LOG_GROUP" 2>/dev/null || true
}

ensure_cluster() {
    aws ecs create-cluster --region "$AWS_REGION" --cluster-name "$CLUSTER" \
        --tags "key=Purpose,value=$Purpose" >/dev/null
}

ensure_execution_role() {
    EXEC_ROLE_ARN=$(aws iam get-role --role-name "$EXEC_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)

    if [[ -z "$EXEC_ROLE_ARN" || "$EXEC_ROLE_ARN" == "None" ]]; then
        local trust_policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

        EXEC_ROLE_ARN=$(aws iam create-role \
            --role-name "$EXEC_ROLE_NAME" \
            --assume-role-policy-document "$trust_policy" \
            --tags "Key=Purpose,Value=$Purpose" "Key=Name,Value=$NAME" \
            --query 'Role.Arn' --output text)

        aws iam attach-role-policy \
            --role-name "$EXEC_ROLE_NAME" \
            --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

        local account db_param_arn secrets_policy
        account=$(aws sts get-caller-identity --query Account --output text)
        db_param_arn="arn:aws:ssm:${AWS_REGION}:${account}:parameter${DATABASE_URL_PARAM}"

        secrets_policy=$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"ssm:GetParameters","Resource":"${db_param_arn}"}]}
EOF
)
        aws iam put-role-policy \
            --role-name "$EXEC_ROLE_NAME" \
            --policy-name "read-database-url" \
            --policy-document "$secrets_policy"

        echo "Created execution role: $EXEC_ROLE_ARN"
        echo "waiting for IAM role propagation..."
        sleep 10
    else
        echo "Reusing execution role: $EXEC_ROLE_ARN"
    fi
}

# this script's own second-AZ subnet, verified against BASTION_SUBNET_ID's AZ specifically
# (the AZ1 half of the ALB's pair below) - not manage_rds.sh's rds-standby subnet, which is
# only verified against DB_SUBNET_ID's AZ and could coincidentally be the same AZ as
# BASTION_SUBNET_ID.
ensure_az2_subnet() {
    AZ2_SUBNET_ID=$(aws ec2 describe-subnets \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Tier,Values=alb-standby" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null)

    if [[ -n "$AZ2_SUBNET_ID" && "$AZ2_SUBNET_ID" != "None" ]]; then
        echo "Reusing existing alb-standby subnet: $AZ2_SUBNET_ID"
        return
    fi

    local primary_az az2
    primary_az=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$BASTION_SUBNET_ID" \
        --query 'Subnets[0].AvailabilityZone' --output text)
    az2=$(aws ec2 describe-availability-zones --region "$AWS_REGION" \
        --filters "Name=state,Values=available" \
        --query "AvailabilityZones[?ZoneName!=\`$primary_az\`].ZoneName | [0]" --output text)

    AZ2_SUBNET_ID=$(aws ec2 create-subnet \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --cidr-block "10.0.7.0/24" \
        --availability-zone "$az2" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Purpose,Value=$Purpose},{Key=Tier,Value=alb-standby}]" \
        --query 'Subnet.SubnetId' --output text)

    [[ -n "$PUBLIC_RT_ID" ]] && aws ec2 associate-route-table \
        --region "$AWS_REGION" --route-table-id "$PUBLIC_RT_ID" --subnet-id "$AZ2_SUBNET_ID" >/dev/null

    echo "Created alb-standby subnet: $AZ2_SUBNET_ID (az=$az2)"
}

ensure_security_groups() {
    ALB_SG=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$NAME" "Name=tag:Role,Values=alb" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

    if [[ -z "$ALB_SG" || "$ALB_SG" == "None" ]]; then
        ALB_SG=$(aws ec2 create-security-group \
            --region "$AWS_REGION" \
            --group-name "alb-${Purpose}-${NAME}" \
            --description "ALB - $Purpose/$NAME" \
            --vpc-id "$VPC_ID" \
            --tag-specifications "ResourceType=security-group,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$NAME},{Key=Role,Value=alb}]" \
            --query 'GroupId' --output text)

        aws ec2 authorize-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$ALB_SG" \
            --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=public HTTP}]" \
            >/dev/null

        echo "Created ALB security group: $ALB_SG (80 from 0.0.0.0/0)"
    else
        echo "Reusing ALB security group: $ALB_SG"
    fi

    ALB_TASK_SG=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$NAME" "Name=tag:Role,Values=alb-task" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

    if [[ -z "$ALB_TASK_SG" || "$ALB_TASK_SG" == "None" ]]; then
        ALB_TASK_SG=$(aws ec2 create-security-group \
            --region "$AWS_REGION" \
            --group-name "alb-task-${Purpose}-${NAME}" \
            --description "ECS tasks behind the ALB - $Purpose/$NAME" \
            --vpc-id "$VPC_ID" \
            --tag-specifications "ResourceType=security-group,Tags=[{Key=Purpose,Value=$Purpose},{Key=Name,Value=$NAME},{Key=Role,Value=alb-task}]" \
            --query 'GroupId' --output text)

        # only the ALB itself can reach the tasks, and only on the app's port - not the
        # broader "anything in the VPC" rule manage_egress_instance.sh needs for NAT.
        aws ec2 authorize-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$ALB_TASK_SG" \
            --ip-permissions "IpProtocol=tcp,FromPort=3000,ToPort=3000,UserIdGroupPairs=[{GroupId=$ALB_SG,Description=from the ALB}]" \
            >/dev/null

        echo "Created task security group: $ALB_TASK_SG (3000 from $ALB_SG)"
    else
        echo "Reusing task security group: $ALB_TASK_SG"
    fi
}

ensure_load_balancer() {
    ALB_ARN=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --names "$ALB_NAME" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)

    if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
        ALB_ARN=$(aws elbv2 create-load-balancer \
            --region "$AWS_REGION" \
            --name "$ALB_NAME" \
            --type application \
            --scheme internet-facing \
            --subnets "$BASTION_SUBNET_ID" "$AZ2_SUBNET_ID" \
            --security-groups "$ALB_SG" \
            --tags "Key=Purpose,Value=$Purpose" "Key=Name,Value=$NAME" \
            --query 'LoadBalancers[0].LoadBalancerArn' --output text)
        echo "Created ALB: $ALB_ARN"
    else
        echo "Reusing ALB: $ALB_ARN"
    fi

    ALB_DNS_NAME=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --load-balancer-arns "$ALB_ARN" \
        --query 'LoadBalancers[0].DNSName' --output text)

    TG_ARN=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --names "$TG_NAME" \
        --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)

    if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then
        TG_ARN=$(aws elbv2 create-target-group \
            --region "$AWS_REGION" \
            --name "$TG_NAME" \
            --protocol HTTP \
            --port 3000 \
            --vpc-id "$VPC_ID" \
            --target-type ip \
            --health-check-path /ready \
            --tags "Key=Purpose,Value=$Purpose" "Key=Name,Value=$NAME" \
            --query 'TargetGroups[0].TargetGroupArn' --output text)
        echo "Created target group: $TG_ARN"
    else
        echo "Reusing target group: $TG_ARN"
    fi

    LISTENER_ARN=$(aws elbv2 describe-listeners --region "$AWS_REGION" --load-balancer-arn "$ALB_ARN" \
        --query 'Listeners[0].ListenerArn' --output text 2>/dev/null)

    if [[ -z "$LISTENER_ARN" || "$LISTENER_ARN" == "None" ]]; then
        LISTENER_ARN=$(aws elbv2 create-listener \
            --region "$AWS_REGION" \
            --load-balancer-arn "$ALB_ARN" \
            --protocol HTTP \
            --port 80 \
            --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
            --query 'Listeners[0].ListenerArn' --output text)
        echo "Created listener: $LISTENER_ARN"
    else
        echo "Reusing listener: $LISTENER_ARN"
    fi
}

register_task_def() {
    cat > "/tmp/${TASK_FAMILY}-taskdef.json" <<EOF
{
  "family": "${TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "app",
      "image": "${ECR_REPO_URI}:${IMAGE_TAG}",
      "essential": true,
      "portMappings": [{"containerPort": 3000, "protocol": "tcp"}],
      "environment": [
        {"name": "NODE_ENV", "value": "production"},
        {"name": "PORT", "value": "3000"},
        {"name": "HOST", "value": "0.0.0.0"}
      ],
      "secrets": [
        {"name": "DATABASE_URL", "valueFrom": "${DATABASE_URL_PARAM}"}
      ],
      "healthCheck": {
        "command": ["CMD-SHELL", "wget -q -O - http://localhost:3000/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 10
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "web-alb"
        }
      }
    }
  ]
}
EOF

    aws ecs register-task-definition --region "$AWS_REGION" --cli-input-json "file:///tmp/${TASK_FAMILY}-taskdef.json" >/dev/null
    rm -f "/tmp/${TASK_FAMILY}-taskdef.json"
}

create_or_update_service() {
    local status
    status=$(aws ecs describe-services --region "$AWS_REGION" --cluster "$CLUSTER" --services "$SERVICE_NAME" \
        --query 'services[0].status' --output text 2>/dev/null)

    if [[ "$status" == "ACTIVE" ]]; then
        echo "Service $SERVICE_NAME exists - deploying the new task definition revision"
        aws ecs update-service \
            --region "$AWS_REGION" \
            --cluster "$CLUSTER" \
            --service "$SERVICE_NAME" \
            --task-definition "$TASK_FAMILY" \
            --desired-count "$DESIRED_COUNT" \
            --force-new-deployment \
            >/dev/null
    else
        echo "Creating service $SERVICE_NAME"
        aws ecs create-service \
            --region "$AWS_REGION" \
            --cluster "$CLUSTER" \
            --service-name "$SERVICE_NAME" \
            --task-definition "$TASK_FAMILY" \
            --desired-count "$DESIRED_COUNT" \
            --launch-type FARGATE \
            --network-configuration "awsvpcConfiguration={subnets=[$APP_SUBNET_ID],securityGroups=[$ALB_TASK_SG],assignPublicIp=DISABLED}" \
            --load-balancers "targetGroupArn=$TG_ARN,containerName=app,containerPort=3000" \
            --health-check-grace-period-seconds 30 \
            --tags "key=Purpose,value=$Purpose" "key=Name,value=$NAME" \
            >/dev/null
    fi

    echo "waiting for $SERVICE_NAME to stabilize..."
    aws ecs wait services-stable --region "$AWS_REGION" --cluster "$CLUSTER" --services "$SERVICE_NAME"
}

create() {
    ensure_ecr_repo
    ensure_log_group
    ensure_execution_role
    ensure_cluster
    ensure_az2_subnet
    ensure_security_groups
    ensure_load_balancer

    register_task_def
    create_or_update_service

    echo
    echo "========================================"
    echo "Web (ALB) service deployed"
    echo "========================================"
    echo "Cluster:  $CLUSTER"
    echo "Service:  $SERVICE_NAME"
    echo "ALB DNS:  http://$ALB_DNS_NAME"
    echo "========================================"

    statefile
}

delete() {
    echo "=== Deleting web (ALB) service $SERVICE_NAME ==="

    local status
    status=$(aws ecs describe-services --region "$AWS_REGION" --cluster "$CLUSTER" --services "$SERVICE_NAME" \
        --query 'services[0].status' --output text 2>/dev/null)

    if [[ "$status" == "ACTIVE" ]]; then
        aws ecs update-service --region "$AWS_REGION" --cluster "$CLUSTER" --service "$SERVICE_NAME" --desired-count 0 >/dev/null
        aws ecs wait services-stable --region "$AWS_REGION" --cluster "$CLUSTER" --services "$SERVICE_NAME"
        aws ecs delete-service --region "$AWS_REGION" --cluster "$CLUSTER" --service "$SERVICE_NAME" >/dev/null
    else
        echo "no active service $SERVICE_NAME in cluster $CLUSTER"
    fi

    echo "=== Deleting load balancer resources ==="

    LISTENER_ARN=$(aws elbv2 describe-listeners --region "$AWS_REGION" --load-balancer-arn "$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)" \
        --query 'Listeners[0].ListenerArn' --output text 2>/dev/null)
    [[ -n "$LISTENER_ARN" && "$LISTENER_ARN" != "None" ]] && \
        aws elbv2 delete-listener --region "$AWS_REGION" --listener-arn "$LISTENER_ARN"

    ALB_ARN=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --names "$ALB_NAME" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
    if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then
        aws elbv2 delete-load-balancer --region "$AWS_REGION" --load-balancer-arn "$ALB_ARN"
        echo "waiting for ALB to finish deleting..."
        aws elbv2 wait load-balancers-deleted --region "$AWS_REGION" --load-balancer-arns "$ALB_ARN"
    fi

    TG_ARN=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --names "$TG_NAME" \
        --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
    [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]] && \
        aws elbv2 delete-target-group --region "$AWS_REGION" --target-group-arn "$TG_ARN"

    for sg in $(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=tag:Purpose,Values=$Purpose" "Name=tag:Name,Values=$NAME" "Name=tag:Role,Values=alb,alb-task" \
        --query 'SecurityGroups[*].GroupId' --output text); do
        echo "Deleting security group: $sg"
        aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg"
    done

    echo "=== Cleanup complete ==="
    echo "note: the cluster, ECR repo, execution role, log group, and alb-standby subnet are left in place"
}

case "$3" in
    create)
        create
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh alb <name> {create|delete}"
        exit 1
        ;;
esac
