variable "secret_name" {
  type        = string
  description = "Name of the secret"
  default     = "app-secret"
}

variable "secret_values" {
  type        = map(string)
  description = "Key-value pairs to store in Secrets Manager"
  default     = {
    username = "postgres"
    password = "CHANGE_ME"
  }
}