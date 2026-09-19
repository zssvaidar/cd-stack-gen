## agent generated docs for understanding internals) project itself is written by me
## purpose of this repo is continuing the CD stack from awscli-vault-jenkins-cd-stack

# CD Stack Gen

Continuation of the learning project at
[awscli-vault-jenkins-cd-stack](https://github.com/zssvaidar/awscli-vault-jenkins-cd-stack)
(`project-1` … `project-8`: Jenkins controller/agent, Vault-issued short-lived AWS creds,
IAM role/policy generation). That repo's README lists the remaining TODOs:

- division of jenkins pipeline into deployment scripts
- configuring ec2, ecs instance
- service management, alert service down
- log collector like loki
- running k8s,k3s on ec2

This repo picks up where it left off, numbered the same way (`project-9`, …), without touching
anything in the original repo.

## Projects

- **[project-9](project-9/)** — Jenkins deploy pipelines for EC2 and ECS, sample deploy targets in
  four languages, and a Telegram bot that reports when a service goes up or down.
- **[project-10](project-10/)** — AWS security groups: least-privilege rules, SG-to-SG
  references across a bastion → app → db tier, attaching/detaching them from running
  instances safely, and auditing for internet-exposed or unused groups.
