variable "subnet_ids" {
  type        = list(string)
  description = "List of private subnet IDs for ElastiCache"
}

variable "security_group_ids" {
  type        = list(string)
  description = "Security groups for Redis cluster"
}

variable "cluster_id" {
  type        = string
  default     = "app-redis-cluster"
}

variable "subnet_group_name" {
  type        = string
  default     = "redis-subnet-group"
}

variable "node_type" {
  type        = string
  default     = "cache.t4g.micro"
}

variable "num_cache_nodes" {
  type        = number
  default     = 1
}

variable "port" {
  type        = number
  default     = 6379
}

variable "availability_zone" {
  type        = string
  default     = "eu-central-1a"
}