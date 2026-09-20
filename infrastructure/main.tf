# ---------------------------------------------------------------------------
# Provider + shared data sources.
# Networking lives in vpc.tf, compute in ecs.tf, the load balancer in alb.tf,
# the database in rds.tf, container registries in ecr.tf.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Pinning to the *available* AZ list and indexing with count.index is what keeps
# the ALB, the subnets and the DB subnet group in the same two AZs - hardcoding
# us-east-1a/us-east-1b is how "ALB and target in different AZ" errors happen.
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}
