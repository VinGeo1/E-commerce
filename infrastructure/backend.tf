# Remote state: S3 + DynamoDB lock, shared by local runs and the Terraform
# GitHub Actions workflow so both operate on one state file.
#
# One-time bootstrap (see README "Terraform state"): create the bucket and the
# lock table, then `terraform init -migrate-state` to move any local state in.
terraform {
  backend "s3" {
    bucket         = "ecommerce-tfstate-414100287492"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "ecommerce-tfstate-lock"
    encrypt        = true
  }
}
