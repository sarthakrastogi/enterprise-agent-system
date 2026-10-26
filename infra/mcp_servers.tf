# Python MCP servers hosted on AgentCore Runtime (protocol MCP).
# They use IAM (SigV4) inbound auth and a resource policy, so only the Gateway
# can call them; users reach them through the gateway, never directly.

resource "aws_iam_role" "mcp_knowledge" {
  name               = "${var.project}-mcp-knowledge"
  assume_role_policy = data.aws_iam_policy_document.agentcore_assume.json
}

resource "aws_iam_role_policy" "mcp_knowledge" {
  role   = aws_iam_role.mcp_knowledge.id
  policy = data.aws_iam_policy_document.runtime_base.json
}

resource "aws_bedrockagentcore_agent_runtime" "mcp_knowledge" {
  agent_runtime_name = "${var.project}_mcp_knowledge"
  description        = "Company knowledge base MCP server"
  role_arn           = aws_iam_role.mcp_knowledge.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.mcp_knowledge.repository_url}:${var.mcp_image_tag}"
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  protocol_configuration {
    server_protocol = "MCP"
  }

  lifecycle_configuration {
    idle_runtime_session_timeout = 900
    max_lifetime                 = 28800
  }

  depends_on = [aws_iam_role_policy.mcp_knowledge]
}

# Only the gateway's role may invoke the MCP server.
resource "aws_bedrockagentcore_resource_policy" "mcp_knowledge" {
  resource_arn = aws_bedrockagentcore_agent_runtime.mcp_knowledge.agent_runtime_arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowGateway"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.gateway.arn }
        Action    = "bedrock-agentcore:InvokeAgentRuntime"
        Resource  = aws_bedrockagentcore_agent_runtime.mcp_knowledge.agent_runtime_arn
      },
      {
        Sid       = "DenyEveryoneElse"
        Effect    = "Deny"
        Principal = "*"
        Action    = "bedrock-agentcore:InvokeAgentRuntime"
        Resource  = aws_bedrockagentcore_agent_runtime.mcp_knowledge.agent_runtime_arn
        Condition = { ArnNotEquals = { "aws:PrincipalArn" = aws_iam_role.gateway.arn } }
      },
    ]
  })
}

locals {
  mcp_knowledge_url = "https://bedrock-agentcore.${local.region}.amazonaws.com/runtimes/${urlencode(aws_bedrockagentcore_agent_runtime.mcp_knowledge.agent_runtime_arn)}/invocations?qualifier=DEFAULT"
}
