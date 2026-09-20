# ec2-deploy

Jenkins pipeline that deploys one of the `../containers/*` apps straight to an EC2 instance —
no image registry involved. It builds on the Jenkins agent, streams the image to the host over
SSH (`docker save | ssh | docker load`), runs it, and health-checks it.

## Prerequisites

1. A keypair from `../agent-keys/generate-and-store.sh <name>` — it prints a `date_name`
   (e.g. `2026-09-17_web-host`), imports the public key into AWS, and stores both halves in
   Vault. See `../agent-keys/README.md`.
2. An EC2 host launched with that keypair and Docker installed, reachable over SSH from the
   Jenkins agent (`bootstrap/provision-ec2.sh` launches one, with `bootstrap/cloud-init-docker.sh`
   as its user-data). Security group needs inbound SSH (22) and whatever `HOST_PORT` you deploy on.
3. The Jenkins agent's Vault token/AppRole has `jenkins-ec2-agents-policy.hcl` from
   `../agent-keys` applied, so it can read `secret/ec2-agents/<date_name>`.
4. The `docker deployment` agent from `project-8/jenkins-api-server-agent` — it already has
   Docker, SSH and the `vault` CLI available.

## Bootstrap (one-time)

```bash
# 1. generate + register + store the keypair
../agent-keys/generate-and-store.sh web-host
# -> 2026-09-17_web-host

# 2. launch the host with that keypair
export AMI_ID=ami-xxxxxxxx        # Amazon Linux 2023 for your region
export KEY_NAME=2026-09-17_web-host
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
| `DATE_NAME`        | `2026-09-17_web-host`             |
| `CONTAINER_PORT`   | `8080`                            |
| `HOST_PORT`        | `8080`                            |
| `DATA_DIR`         | `/data` (optional)                |
| `LOG_DIR`          | `/var/log/app` (optional)         |

The pipeline fetches the `DATE_NAME` keypair's private key from Vault (deleted again at the end
of the run, in `post { always { ... } }`), builds `IMAGE_NAME:BUILD_NUMBER`, ships it over SSH,
replaces any existing container with the same name, and polls `HEALTH_PATH` on the host until it
responds (or fails after ~30s).

## Persisting data and logs across updates

`docker rm -f` (run before every deploy, to replace the old container with the new image) only
removes the container — it never touches the host filesystem. If your app writes anything under
`DATA_DIR` / `LOG_DIR` inside the container, set those parameters and the pipeline bind-mounts
`/opt/<IMAGE_NAME>/data` and `/opt/<IMAGE_NAME>/logs` on the EC2 host into the same paths in the
new container, so a version update keeps everything that was written there. Leave a parameter
blank to skip its mount (e.g. a stateless app with no `DATA_DIR`).

This protects you against redeploys and container crashes/restarts, not against losing the EC2
instance itself — for durability across an instance replacement, ship logs to a central collector
(e.g. Loki) and back real data with something outside the instance (EBS snapshot, S3, RDS, etc.)
rather than relying solely on the host's local disk.
