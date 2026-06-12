output "cluster_id" {
  value = aws_ecs_cluster.this.id
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "execution_role_arn" {
  # ECS execution role created here if needed
  # For simplicity, create a default role using AWS managed policy
  value = aws_iam_role.ecs_execution_role.arn
}