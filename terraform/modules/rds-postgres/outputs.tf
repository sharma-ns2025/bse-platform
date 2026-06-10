output "db_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "db_port" {
  value = aws_db_instance.postgres.port
}

output "db_identifier" {
  value = aws_db_instance.postgres.id
}

output "db_arn" {
  value = aws_db_instance.postgres.arn
}

output "db_name" {
  description = "The logical name of the RDS instance"
  value       = aws_db_instance.postgres.identifier
}