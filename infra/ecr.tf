resource "aws_ecr_repository" "agent_runtime" {
  name                 = "${var.project}/agent-runtime"
  image_tag_mutability = "IMMUTABLE" # a tag always means the same code
  force_delete         = true        # lets `make destroy` clean up; remove for production

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "mcp_knowledge" {
  name                 = "${var.project}/mcp-knowledge"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "keep_recent" {
  for_each   = { runtime = aws_ecr_repository.agent_runtime.name, mcp = aws_ecr_repository.mcp_knowledge.name }
  repository = each.value
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 20 most recent images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}
