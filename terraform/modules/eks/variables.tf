variable "project_name" {
  type    = string
  default = "ticketops"
}

variable "environment" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "eks_cluster_role_arn" {
  type = string
}

variable "eks_node_role_arn" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "desired_size" {
  type    = number
  default = 2
}

variable "min_size" {
  type    = number
  default = 1
}

variable "max_size" {
  type    = number
  default = 3
}

variable "loki_logs_bucket_arn" {
  description = "ARN of the S3 bucket Loki writes chunks/index to — used to scope the Loki IRSA policy"
  type        = string
}

variable "tempo_traces_bucket_arn" {
  description = "ARN of the S3 bucket Tempo writes trace blocks to — used to scope the Tempo IRSA policy"
  type        = string
}