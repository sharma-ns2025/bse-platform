variable "vpc_id" {}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {}

variable "private_route_table_ids" {
  description = "List of private route table IDs for S3 Gateway Endpoint"
  type        = list(string)
}