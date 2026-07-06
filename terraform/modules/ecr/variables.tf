variable "project_name" {
  type    = string
  default = "ticketops"
}

variable "environment" {
  type = string
}

variable "repository_names" {
  description = "List of service names to create ECR repos for"
  type        = list(string)
  default     = ["events-api", "admin-api", "bookings-worker", "dashboard"]
}