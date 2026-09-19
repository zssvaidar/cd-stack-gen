# project-10 — security groups

Continuation of the CD stack from
[awscli-vault-jenkins-cd-stack](https://github.com/zssvaidar/awscli-vault-jenkins-cd-stack).
Theme: AWS EC2 security groups — creating them correctly, wiring them together across tiers
with references instead of IP lists, attaching/detaching them from running instances, and
auditing them for the two mistakes that actually matter in practice (open to the internet, or
attached to nothing).

See [`security-groups/README.md`](security-groups/) for the full write-up, the scripts, and a
worked bastion → app → db example.
