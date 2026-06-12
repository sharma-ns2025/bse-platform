variable "service_name" { type = string }
variable "cluster_id" { type = string }

variable "desired_count" { type = number }
variable "cpu" { type = number }
variable "memory" { type = number }

variable "environment" {
  type    = list(object({ name = string, value = string }))
  default = []
}

variable "container_name" { type = string }
variable "container_port" { type = number }
variable "image" { type = string }

variable "task_family" { type = string }

variable "execution_role_arn" { type = string }

variable "security_group_id" { type = string }

variable "target_group_arn" { type = string }

variable "subnet_ids" {
  type = list(string)
}