# The jobs/events worker: a second ECS service running the same image as the web tier, just
# `bun dist/worker.js` instead of `bun dist/index.js` - no load balancer, no public exposure,
# nothing calls it from outside the cluster. Also owns running migrations: `run.sh worker
# <name> create` registers and runs a one-off `bun hydrate db:migrate` task before the worker
# service itself starts, since (per src/worker.ts.tmpl) "a worker never runs on an older
# schema" and the docs recommend `bun hydrate db:migrate` as an explicit deploy step over
# MIGRATE_ON_START. Run this before `run.sh tunnel`/`run.sh alb <name> create` for the same
# reason - the web tier shouldn't come up against an unmigrated schema either.
#
# The ECS cluster is shared with manage_ecs_tunnel.sh/manage_ecs_alb.sh (one cluster per app,
# multiple services inside it, the normal shape of a real deployment) - delete() here only
# removes the worker service, never the cluster itself, since the web services might still be
# running in it.

source "$STATE_FILE"

[[ "$NAME" =~ ^(create|delete|rds|worker|tunnel|alb)$ ]] && { echo "error: invalid name '$NAME'" >&2; exit 1; }

: "${APP_SUBNET_ID:?no APP_SUBNET_ID in \$STATE_FILE - run '../project-11/run.sh network create' first}"
: "${APP_SG:?no APP_SG in \$STATE_FILE - run '../project-11/run.sh network create' first}"
: "${DATABASE_URL_PARAM:?no DATABASE_URL_PARAM in \$STATE_FILE - run 'run.sh rds $NAME create' first}"

IMAGE_TAG="${IMAGE_TAG:-latest}"
MIGRATE_TAG="${MIGRATE_TAG:-migrate}"

CLUSTER="${Purpose}-${NAME}"
SERVICE_NAME="${NAME}-worker"
TASK_FAMILY="${Purpose}-${NAME}-worker"
MIGRATE_FAMILY="${Purpose}-${NAME}-migrate"
LOG_GROUP="/ecs/${Purpose}-${NAME}"
EXEC_ROLE_NAME="ecsTaskExecutionRole-${Purpose}-${NAME}-worker"

statefile() {
    {
        echo
        echo "# $NAME (ecs worker)"
        echo "export AWS_REGION=\"$AWS_REGION\""
        echo "export ECS_CLUSTER=\"$CLUSTER\""
        echo "export WORKER_SERVICE=\"$SERVICE_NAME\""
        echo "export WORKER_TASK_FAMILY=\"$TASK_FAMILY\""
        echo "export WORKER_EXEC_ROLE_ARN=\"$EXEC_ROLE_ARN\""
        echo "export ECR_REPO_URI=\"$ECR_REPO_URI\""
    } >> "$STATE_FILE"

    echo "State appended to $STATE_FILE"
}

# same shape in all three manage_ecs_*.sh scripts - one ECR repo per app, holding both the
# :latest runtime image and the :migrate build-stage image (which still has the `hydrate` CLI -
# the slim runtime image doesn't).
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

# create-if-missing, never deleted on teardown - an execution role is a permission grant, not
# compute, and every manage_ecs_*.sh script that reuses the same name expects it to still be
# there. Scoped to exactly what this service needs (ECR pull, logs, this one SSM parameter) -
# not shared with tunnel's role, which additionally needs the Cloudflare tunnel token.
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

        local db_param_arn="arn:aws:ssm:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):parameter${DATABASE_URL_PARAM}"
        local secrets_policy
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

# registers $1 as the task family, $2 as the container command (JSON array), $3 as optional
# extra container JSON (healthCheck, portMappings, ...) merged into the container definition
register_task_def() {
    local family="$1" image="$2" command="$3" extra="$4"

    cat > /tmp/${family}-taskdef.json <<EOF
{
  "family": "${family}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "app",
      "image": "${image}",
      "essential": true,
      "command": ${command},
      "environment": [
        {"name": "NODE_ENV", "value": "production"}
      ],
      "secrets": [
        {"name": "DATABASE_URL", "valueFrom": "${DATABASE_URL_PARAM}"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "${family}"
        }
      }${extra}
    }
  ]
}
EOF

    aws ecs register-task-definition --region "$AWS_REGION" --cli-input-json "file:///tmp/${family}-taskdef.json" >/dev/null
    rm -f "/tmp/${family}-taskdef.json"
}

run_migration() {
    echo "=== Running migrations (bun hydrate db:migrate, ${ECR_REPO_URI}:${MIGRATE_TAG}) ==="

    register_task_def "$MIGRATE_FAMILY" "${ECR_REPO_URI}:${MIGRATE_TAG}" '["bun","hydrate","db:migrate"]' ""

    local task_arn
    task_arn=$(aws ecs run-task \
        --region "$AWS_REGION" \
        --cluster "$CLUSTER" \
        --task-definition "$MIGRATE_FAMILY" \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$APP_SUBNET_ID],securityGroups=[$APP_SG],assignPublicIp=DISABLED}" \
        --query 'tasks[0].taskArn' --output text)

    echo "waiting for migration task to finish: $task_arn"
    aws ecs wait tasks-stopped --region "$AWS_REGION" --cluster "$CLUSTER" --tasks "$task_arn"

    local exit_code
    exit_code=$(aws ecs describe-tasks --region "$AWS_REGION" --cluster "$CLUSTER" --tasks "$task_arn" \
        --query 'tasks[0].containers[0].exitCode' --output text)

    if [[ "$exit_code" != "0" ]]; then
        echo "error: migration task exited $exit_code - check $LOG_GROUP/${MIGRATE_FAMILY} in CloudWatch" >&2
        exit 1
    fi

    echo "Migrations applied"
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
            --force-new-deployment \
            >/dev/null
    else
        echo "Creating service $SERVICE_NAME"
        aws ecs create-service \
            --region "$AWS_REGION" \
            --cluster "$CLUSTER" \
            --service-name "$SERVICE_NAME" \
            --task-definition "$TASK_FAMILY" \
            --desired-count 1 \
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

    run_migration

    register_task_def "$TASK_FAMILY" "${ECR_REPO_URI}:${IMAGE_TAG}" '["bun","dist/worker.js"]' \
        ',"environment":[{"name":"NODE_ENV","value":"production"},{"name":"WORKER_PORT","value":"3100"}],"healthCheck":{"command":["CMD-SHELL","wget -q -O - http://localhost:3100/health || exit 1"],"interval":30,"timeout":5,"retries":3,"startPeriod":10}'
    # note: the environment array above duplicates NODE_ENV from register_task_def's own -
    # ECS takes the last one, so this just makes sure WORKER_PORT is set without having to
    # thread a 5th parameter through register_task_def for one variable.

    create_or_update_service

    echo
    echo "========================================"
    echo "Worker service deployed"
    echo "========================================"
    echo "Cluster: $CLUSTER"
    echo "Service: $SERVICE_NAME"
    echo "========================================"

    statefile
}

delete() {
    echo "=== Deleting worker service $SERVICE_NAME ==="

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
    echo "note: the cluster, ECR repo, execution role, and log group are left in place - the"
    echo "cluster may still hold the web service, and the rest are persistent across redeploys"
}

case "$3" in
    create)
        create
        ;;
    delete)
        delete
        ;;
    *)
        echo "Usage run.sh worker <name> {create|delete}"
        exit 1
        ;;
esac
