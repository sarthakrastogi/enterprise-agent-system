data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.region

  # Generated from agents/*.py by `python -m eap.manifest` (scripts/deploy.sh does this).
  agents = jsondecode(file("${path.module}/../build/agents.json"))

  any_memory           = anytrue([for a in values(local.agents) : a.memory])
  any_code_interpreter = anytrue([for a in values(local.agents) : a.code_interpreter])

  cognito_discovery_url = "https://cognito-idp.${local.region}.amazonaws.com/${aws_cognito_user_pool.this.id}/.well-known/openid-configuration"

  agentcore_trust_conditions = {
    account = local.account
    arn     = "arn:aws:bedrock-agentcore:${local.region}:${local.account}:*"
  }
}

# Every AgentCore execution role trusts the service, scoped to this account
# (confused-deputy protection).
data "aws_iam_policy_document" "agentcore_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.agentcore_trust_conditions.arn]
    }
  }
}

# Shared by every runtime (agents and MCP servers): pull image, write logs,
# traces and metrics.
data "aws_iam_policy_document" "runtime_base" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.agent_runtime.arn, aws_ecr_repository.mcp_knowledge.arn]
  }
  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
      "logs:DescribeLogGroups", "logs:DescribeLogStreams",
    ]
    resources = ["arn:aws:logs:${local.region}:${local.account}:log-group:/aws/bedrock-agentcore/runtimes/*"]
  }
  statement {
    sid       = "UnifiedTraceDestination"
    actions   = ["logs:PutResourcePolicy", "logs:DescribeResourcePolicies"]
    resources = ["*"]
  }
  statement {
    sid = "Traces"
    actions = [
      "xray:PutTraceSegments", "xray:PutTelemetryRecords",
      "xray:GetSamplingRules", "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["bedrock-agentcore", "EAP/Agents"] # EAP/Agents: eap/runtime/metrics.py
    }
  }
}
