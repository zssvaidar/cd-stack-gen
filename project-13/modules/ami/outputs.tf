output "ami_id" {
  value = data.aws_ami.built.id
}

output "ami_name" {
  value = data.aws_ami.built.name
}

output "base_ami_id" {
  description = "The image this one was built on top of."
  value       = local.base_ami_id
}

output "build_id" {
  description = "BuildId tag on the AMI and its snapshot."
  value       = terraform_data.build.id
}
