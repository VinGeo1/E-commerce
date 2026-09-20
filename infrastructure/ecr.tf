# ---------------------------------------------------------------------------
# The two ECR repositories the CI workflow pushes to.
# Terraform owns them, so do NOT also run `aws ecr create-repository` by hand -
# the apply would fail with RepositoryAlreadyExistsException.
# ---------------------------------------------------------------------------

locals {
  ecr_repositories = ["ecommerce-backend", "ecommerce-frontend"]
}

resource "aws_ecr_repository" "main" {
  for_each             = toset(local.ecr_repositories)
  # MUTABLE because CI re-pushes :latest on every build; force_delete so that
  # `terraform destroy` is not blocked by the retained images.
  name                 = each.key
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  # trivy/clair scanning is out of scope (and billed per image).
  image_scanning_configuration {
    scan_on_push = false
  }
}

# Keep the last 10 images per repository; anything older is expired.
resource "aws_ecr_lifecycle_policy" "main" {
  for_each   = aws_ecr_repository.main
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 10 images"
      action       = { type = "expire" }
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
    }]
  })
}
