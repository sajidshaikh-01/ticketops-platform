terraform {
  backend "s3" {
    bucket         = "ticketops-terraform-state"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "ticketops-terraform-locks"
    encrypt        = true
  }
}