output "instance_id" {
  value = aws_instance.bastion_ssm.id
}

output "instance_arn" {
  value = aws_instance.bastion_ssm.arn
}