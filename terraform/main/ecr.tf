# Container registries for the two images. Pushed by scripts/push_images.sh,
# tagged with the git short SHA (tags are immutable; there is no "latest").

locals {
  images = toset(["api", "worker"])
}

resource "aws_ecr_repository" "this" {
  for_each = local.images

  name = "reelops-${each.key}"
  # A tag always means exactly one image: deploys are traceable to a commit
  # and a deployed image can't be silently replaced.
  image_tag_mutability = "IMMUTABLE"
  # Dev only: lets terraform destroy remove repos that still hold images. In
  # production keep false; running services and rollbacks need those images.
  force_delete = true

  # Basic scanning (free): CVEs in OS packages, on every push.
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
