variable "cluster_id" {
  type        = string
  description = "ECS Cluster ID where the service will run"
}

variable "service_name" {
  type        = string
  description = "Name of the ECS service"
}

variable "container_name" {
  type        = string
  description = "Name of the container in the task definition"
}

variable "image" {
  type        = string
  description = "Docker image to use for the container"
}

variable "container_port" {
  type        = number
  description = "Port on the container to map"
}

variable "cpu" {
  type        = string
  default     = "256"
  description = "CPU units for the task definition"
}

variable "memory" {
  type        = string
  default     = "512"
  description = "Memory for the task definition"
}

variable "desired_count" {
  type        = number
  default     = 1
  description = "Number of ECS tasks to run"
}

variable "environment" {
  type        = list(object({ name = string, value = string }))
  default     = []
  description = "List of environment variables for the container"
}

variable "execution_role_arn" {
  type        = string
  description = "IAM role ARN for ECS task execution"
}

variable "subnet_ids" {
  type        = list(string)
  description = "List of subnet IDs for ECS service"
}

variable "security_group_id" {
  type        = string
  description = "Security group ID to attach to the ECS service"
}

variable "target_group_arn" {
  type        = string
  description = "Target group ARN for ALB integration"
}

variable "task_family" {
  type        = string
  description = "Task definition family name"
}