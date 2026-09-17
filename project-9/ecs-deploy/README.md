# ecs-deploy

Jenkins pipeline that builds one of the `../containers/*` apps, pushes it to ECR, and rolls it
out on ECS Fargate: register a new task definition revision, update the service, wait for it to
stabilize. Uses the same Vault flow as the rest of this stack — the agent calls
`vault read aws/creds/jenkins` and gets back short-lived STS credentials, no long-lived AWS keys
stored in Jenkins.

## Prerequisites

- Vault reachable from the agent with the `jenkins` AppRole/token able to `read`
  `aws/creds/jenkins` (see `project-8/vault-cmd` + `project-8/aws-perm-generator`), and the
  underlying `jenkins-role` IAM role granted ECR push + ECS deploy permissions.
- An ECR repository for the app you're deploying.
- The `docker deployment` Jenkins agent from `project-8/jenkins-api-server-agent`.

## Bootstrap (one-time)

1. Run the pipeline once with just the "Register task definition" stage relevant (or run
   `aws ecs register-task-definition` by hand using `task-def.json.template` filled in), so the
   task family exists.
2. Create the cluster/service:

```bash
export AWS_REGION=ap-northeast-1
export ECS_CLUSTER=cd-stack-cluster
export ECS_SERVICE=python-app-service
export TASK_FAMILY=python-app
export SUBNET_IDS=subnet-aaa,subnet-bbb
export SECURITY_GROUP_ID=sg-xxxxxxxx
./bootstrap/create-cluster-and-service.sh
```

## Running the pipeline

Create a Jenkins pipeline job pointing at this `Jenkinsfile` and set:

| parameter             | example                                                              |
|------------------------|-----------------------------------------------------------------------|
| `APP_DIR`               | `project-9/containers/python-app`                                     |
| `ECR_REPO`              | `123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/python-app`        |
| `ECS_CLUSTER` / `ECS_SERVICE` / `TASK_FAMILY` | must match what `bootstrap/` created            |
| `CONTAINER_NAME` / `CONTAINER_PORT`           | must match the app's Dockerfile             |
| `EXECUTION_ROLE_ARN`    | ARN of an `ecsTaskExecutionRole`                                       |

`task-def.json.template` is rendered with `envsubst` each run (new image tag = build number) and
registered as a fresh task definition revision; the service is then updated with
`--force-new-deployment` and the pipeline blocks on `aws ecs wait services-stable`.
