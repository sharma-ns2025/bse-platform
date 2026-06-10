output "postgres_sg_id" {
  value = aws_security_group.aurora.id
}

output "bastion_sg_id" {
  value = aws_security_group.bastion_sg.id
}