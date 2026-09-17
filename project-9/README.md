# project-9 — Jenkins deploy to EC2 + ECS, multi-language containers, Telegram status notifier

Continuation of the CD stack from
[awscli-vault-jenkins-cd-stack](https://github.com/zssvaidar/awscli-vault-jenkins-cd-stack)
(`project-1` … `project-8`). Picks up three items from that repo's TODO list:

- [x] division of jenkins pipeline into deployment scripts — `ec2-deploy/`, `ecs-deploy/`
- [x] configuring ec2, ecs instance — `ec2-deploy/bootstrap/`, `ecs-deploy/bootstrap/`
- [x] service management, alert service down — `status-notifier/`

## Layout

- **`containers/`** — minimal HTTP apps in Node.js, Python, Go and Java, each exposing `/` and
  `/health`. Used as the deploy targets for the two pipelines below.
- **`ec2-deploy/`** — Jenkinsfile that builds an image on the agent and ships it straight to an
  EC2 host over SSH (`docker save | ssh | docker load`, then `docker run`). `bootstrap/`
  provisions the EC2 host itself (Docker installed via user-data).
- **`ecs-deploy/`** — Jenkinsfile that builds + pushes to ECR, renders and registers a new Fargate
  task definition, then updates the ECS service. Pulls short-lived AWS credentials from Vault
  (`aws/creds/jenkins`), same as the rest of this stack — no long-lived keys on the agent.
  `bootstrap/` creates the cluster/service once.
- **`status-notifier/`** — polls the deployed services (plain HTTP health checks, or ECS
  `desiredCount`/`runningCount`) and posts a Telegram message whenever one flips between up and
  down.

## How it fits together

1. Provision infra once: `ec2-deploy/bootstrap/provision-ec2.sh` and/or
   `ecs-deploy/bootstrap/create-cluster-and-service.sh`.
2. Add the two Jenkinsfiles as pipeline jobs on the controller from
   `project-8/jenkins-api-server-agent` (same controller/agent, same Vault-issued creds).
3. Point `status-notifier/config/services.yml` at whatever got deployed, fill in a Telegram bot
   token, and run it (`docker compose up -d`) — it messages the configured chat on every
   down/up transition.

See each subfolder's README for prerequisites, parameters and required Jenkins credentials.
