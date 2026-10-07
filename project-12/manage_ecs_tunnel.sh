# Web tier via a Cloudflare Tunnel sidecar - no ALB, no public IP, no inbound security-group
# rule at all. Two containers in the same task: `app` (bun-hydrate's web process) and
# `cloudflared`, talking to each other over the task's own localhost (awsvpc mode shares one
# network namespace per task). Every task replica connects to the SAME tunnel ID using the
# same token - Cloudflare's edge load-balances across however many connector replicas are
# currently up, so scaling this service's desired count just adds/removes tunnel connections,
# no separate load balancer needed. Run `run.sh worker <name> create` first (migrations).
#
# The ECS cluster is shared with manage_ecs_worker.sh/manage_ecs_alb.sh - delete() here only
# removes this service, never the cluster.

source "$STATE_FILE"

[[ "$NAME" =~ ^(create|delete|rds|worker|tunnel|alb)$ ]] && { echo "error: invalid name '$NAME'" >&2; exit 1; }

: "${APP_SUBNET_ID:?no APP_SUBNET_ID in \$STATE_FILE - run '../project-11/run.sh network create' first}"
: "${APP_SG:?no APP_SG in \$STATE_FILE - run '../project-11/run.sh network create' first}"
: "${DATABASE_URL_PARAM:?no DATABASE_URL_PARAM in \$STATE_FILE - run 'run.sh rds $NAME create' first}"

IMAGE_TAG="${IMAGE_TAG:-latest}"
DESIRED_COUNT="${DESIRED_COUNT:-1}"
CLOUDFLARE_TOKEN_PARAM="${CLOUDFLARE_TOKEN_PARAM:-/cloudflare/${NAME}/tunnel-token}"

CLUSTER="${Purpose}-${NAME}"
SERVICE_NAME="${NAME}-web-tunnel"
TASK_FAMILY="${Purpose}-${NAME}-web-tunnel"
LOG_GROUP="/ecs/${Purpose}-${NAME}"
EXEC_ROLE_NAME="ecsTaskExecutionRole-${Purpose}-${NAME}-tunnel"

statefile() {
    {
        echo
        echo "# $NAME (ecs web, tunnel)"
        echo "export AWS_REGION=\"$AWS_REGION\""
        echo "export ECS_CLUSTER=\"$CLUSTER\""
        echo "export TUNNEL_SERVICE=\"$SERVICE_NAME\""
        echo "export TUNNEL_TASK_FAMILY=\"$TASK_FAMILY\""
        echo "export TUNNEL_EXEC_ROLE_ARN=\"$EXEC_ROLE_ARN\""
        echo "export ECR_REPO_URI=\"$ECR_REPO_URI\""
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

# scoped to exactly what this service needs: DATABASE_URL (like every other service here) plus
# the Cloudflare tunnel token - not shared with worker's/alb's role, neither of which needs
# the tunnel token at all.
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

        local account db_param_arn token_param_arn secrets_policy
        account=$(aws sts get-caller-identity --query Account --output text)
        db_param_arn="arn:aws:ssm:${AWS_REGION}:${account}:parameter${DATABASE_URL_PARAM}"
        token_param_arn="arn:aws:ssm:${AWS_REGION}:${account}:parameter${CLOUDFLARE_TOKEN_PARAM}"

        secrets_policy=$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"ssm:GetParameters","Resource":["${db_param_arn}","${token_param_arn}"]}]}
EOF
)
        aws iam put-role-policy \
            --role-name "$EXEC_ROLE_NAME" \
            --policy-name "read-secrets" \
            --policy-document "$secrets_policy"

        echo "Created execution role: $EXEC_ROLE_ARN"
        echo "waiting for IAM role propagation..."
        sleep 10
    else
        echo "Reusing execution role: $EXEC_ROLE_ARN"
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
          "awslogs-stream-prefix": "web-tunnel-app"
        }
      }
    },
    {
      "name": "cloudflared",
      "image": "cloudflare/cloudflared:latest",
      "essential": true,
      "command": ["tunnel", "--no-autoupdate", "run"],
      "secrets": [
        {"name": "TUNNEL_TOKEN", "valueFrom": "${CLOUDFLARE_TOKEN_PARAM}"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "web-tunnel-cloudflared"
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
            --network-configuration "awsvpcConfiguration={subnets=[$APP_SUBNET_ID],securityGroups=[$APP_SG],assignPublicIp=DISABLED}" \
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

    register_task_def
    create_or_update_service

    echo
    echo "========================================"
    echo "Web (tunnel) service deployed"
    echo "========================================"
    echo "Cluster:     $CLUSTER"
    echo "Service:     $SERVICE_NAME"
    echo "Desired:     $DESIRED_COUNT task(s)"
    echo "Tunnel token param: $CLOUDFLARE_TOKEN_PARAM"
    echo "========================================"

    statefile
}

delete() {
    echo "=== Deleting web (tunnel) service $SERVICE_NAME ==="

    local status
    status=$(aws ecs describe-services --region "$AWS_REGION" --cluster "$CLUSTER" --services "$SERVICE_NAME" \
        --query 'services[0].status' --output text 2>/dev/null)

    if [[ "$status" != "ACTIVE" ]]; then
        echo "no active service $SERVICE_NAME in cluster $CLUSTER"
        return
    fi

    aws ecs update-service --region "$AWS_REGION" --cluster "$CLUSTER" --service "$SERVICE_NAME" --desired-count 0 >/dev/null
    aws ecs wait services-stable --region "$AWS_REGION" --cluster "$CLUSTER" --services "$SERVICE_NAME"
    aws ecs delete-service --region "$AWS_REGION" --cluster "$CLUSTER" --service "$SERVICE_NAME" >/dev/null

    echo "=== Cleanup complete ==="
    echo "note: the cluster, ECR repo, execution role, and log group are left in place"
}

case "$3" in
    create)
        create
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh tunnel <name> {create|delete}"
        exit 1
        ;;
esac
