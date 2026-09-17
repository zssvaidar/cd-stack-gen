# ec2-deploy

Jenkins pipeline that deploys one of the `../containers/*` apps straight to an EC2 instance —
no image registry involved. It builds on the Jenkins agent, streams the image to the host over
SSH (`docker save | ssh | docker load`), runs it, and health-checks it.

## Prerequisites

1. An EC2 host with Docker installed and reachable over SSH from the Jenkins agent
   (`bootstrap/provision-ec2.sh` launches one, with `bootstrap/cloud-init-docker.sh` as its
   user-data). Security group needs inbound SSH (22) and whatever `HOST_PORT` you deploy on.
2. An SSH key credential in Jenkins (Manage Jenkins → Credentials) that can log into that host,
   with the credential ID matching the `SSH_CREDENTIALS_ID` parameter (defaults to
   `ec2-deploy-key`).
3. The `docker deployment` agent from `project-8/jenkins-api-server-agent` — it already has
   Docker and SSH available.

## Bootstrap the host (one-time)

```bash
export AMI_ID=ami-xxxxxxxx        # Amazon Linux 2023 for your region
export KEY_NAME=my-keypair
export SECURITY_GROUP_ID=sg-xxxxxxxx
export SUBNET_ID=subnet-xxxxxxxx
./bootstrap/provision-ec2.sh
```

## Running the pipeline

Create a Jenkins pipeline job pointing at this `Jenkinsfile` and set:

| parameter        | example                          |
|-------------------|-----------------------------------|
| `APP_DIR`         | `project-9/containers/go-app`     |
| `IMAGE_NAME`       | `go-app`                          |
| `SSH_TARGET`       | `ec2-user@203.0.113.10`           |
| `CONTAINER_PORT`   | `8080`                            |
| `HOST_PORT`        | `8080`                            |

The pipeline builds `IMAGE_NAME:BUILD_NUMBER`, ships it, replaces any existing container with the
same name, and polls `HEALTH_PATH` on the host until it responds (or fails after ~30s).
