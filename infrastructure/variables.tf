variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "db_password" {
  type      = string
  sensitive = true
}

# Defaults point at the two repositories this stack creates (ecr.tf), tagged
# :latest by the CI workflow on every main build - so a fresh `terraform apply`
# starts tasks that can actually pull an image.
variable "backend_image" {
  type    = string
  default = "414100287492.dkr.ecr.us-east-1.amazonaws.com/ecommerce-backend:latest"
}

variable "frontend_image" {
  type    = string
  default = "414100287492.dkr.ecr.us-east-1.amazonaws.com/ecommerce-frontend:latest"
}
