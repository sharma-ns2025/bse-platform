output "postgres_endpoint" {
  value = module.rds.db_endpoint
}

output "postgres_port" {
  value = module.rds.db_port
}

output "postgres_identifier" {
  value = module.rds.db_identifier
}

output "postgres_arn" {
  value = module.rds.db_arn
}