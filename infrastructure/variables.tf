variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "backend_image" {
  type    = string
  default = "123456789012.dkr.ecr.us-east-1.amazonaws.com/backend:latest"
}

variable "frontend_image" {
  type    = string
  default = "123456789012.dkr.ecr.us-east-1.amazonaws.com/frontend:latest"
}
