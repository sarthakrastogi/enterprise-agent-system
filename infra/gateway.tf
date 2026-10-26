# AgentCore Gateway: one MCP endpoint in front of every tool.
#   inbound : the signed-in user's Cognito access token (forwarded by the agent)
#   request : interceptor stamps the real user onto identity-sensitive tool calls
#   policy  : Cedar decides per user which tools are listed and callable (policy.tf)
#   outbound: SigV4 with the gateway role to Lambda and Runtime-hosted MCP servers

resource "aws_iam_role" "gateway" {
  name               = "${var.project}-gateway"
  assume_role_policy = data.aws_iam_policy_document.agentcore_assume.json
}

resource "aws_iam_role_policy" "gateway" {
  role = aws_iam_role.gateway.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeLambdaTargetsAndInterceptor"
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = [aws_lambda_function.tickets.arn, aws_lambda_function.interceptor.arn]
      },
      {
        Sid      = "InvokeMcpServers"
        Effect   = "Allow"
        Action   = "bedrock-agentcore:InvokeAgentRuntime"
        Resource = [aws_bedrockagentcore_agent_runtime.mcp_knowledge.agent_runtime_arn, "${aws_bedrockagentcore_agent_runtime.mcp_knowledge.agent_runtime_arn}/*"]
      },
      {
        Sid      = "EvaluateCedarPolicy"
        Effect   = "Allow"
        Action   = ["bedrock-agentcore:AuthorizeAction", "bedrock-agentcore:PartiallyAuthorizeActions", "bedrock-agentcore:GetPolicyEngine"]
        Resource = [aws_bedrockagentcore_policy_engine.this.policy_engine_arn, "${aws_bedrockagentcore_policy_engine.this.policy_engine_arn}/*"]
      },
    ]
  })
}

resource "aws_bedrockagentcore_gateway" "this" {
  name        = "${var.project}-tools"
  description = "Platform tool gateway"
  role_arn    = aws_iam_role.gateway.arn

  authorizer_type = "CUSTOM_JWT"
  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = local.cognito_discovery_url
      allowed_clients = [aws_cognito_user_pool_client.ui.id]
    }
  }

  protocol_type = "MCP"
  protocol_configuration {
    mcp {
      instructions = "Company tools. Tool names are <target>___<tool>."
      search_type  = "SEMANTIC" # adds x_amz_bedrock_agentcore_search for large tool catalogues
    }
  }

  interceptor_configuration {
    interception_points = ["REQUEST"]
    interceptor {
      lambda {
        arn = aws_lambda_function.interceptor.arn
      }
    }
    input_configuration {
      pass_request_headers = true # the interceptor needs the Authorization header
    }
  }

  policy_engine_configuration {
    arn  = aws_bedrockagentcore_policy_engine.this.policy_engine_arn
    mode = var.policy_mode
  }

  depends_on = [aws_iam_role_policy.gateway]
}

# --- target: knowledge base MCP server on AgentCore Runtime ------------------

resource "aws_bedrockagentcore_gateway_target" "knowledge" {
  name               = "knowledge"
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  description        = "Company IT policy knowledge base"

  credential_provider_configuration {
    gateway_iam_role {
      service = "bedrock-agentcore"
    }
  }

  target_configuration {
    mcp {
      mcp_server {
        endpoint = local.mcp_knowledge_url
      }
    }
  }

  depends_on = [aws_bedrockagentcore_resource_policy.mcp_knowledge]
}

# --- target: tickets Lambda ------------------------------------------------------

locals {
  requester_property = {
    name        = "requester"
    type        = "string"
    description = "Set by the platform to the signed-in user. Leave empty."
  }

  ticket_tools = {
    create_ticket = {
      description = "Create a support ticket for the signed-in user. Confirm the summary and priority with the user first. Returns the new ticket."
      properties = [
        { name = "summary", type = "string", description = "One-line summary of the problem (max 200 chars)", required = true },
        { name = "details", type = "string", description = "Steps tried, error messages, device", required = false },
        { name = "priority", type = "string", description = "low, normal or high. Use high only if the user cannot work.", required = false },
      ]
    }
    get_ticket = {
      description = "Get one of the signed-in user's tickets by ticket_id (e.g. TCK-1A2B3C4D)."
      properties  = [{ name = "ticket_id", type = "string", description = "Ticket id", required = true }]
    }
    list_my_tickets = {
      description = "List the signed-in user's 20 most recent tickets, newest first."
      properties  = []
    }
    close_ticket = {
      description = "Close a ticket with a resolution note. Restricted to platform admins by policy."
      properties = [
        { name = "ticket_id", type = "string", description = "Ticket id", required = true },
        { name = "resolution", type = "string", description = "How it was resolved", required = false },
      ]
    }
  }
}

resource "aws_bedrockagentcore_gateway_target" "tickets" {
  name               = "tickets"
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  description        = "Support ticket tools"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.tickets.arn
        tool_schema {
          dynamic "inline_payload" {
            for_each = local.ticket_tools
            content {
              name        = inline_payload.key
              description = inline_payload.value.description
              input_schema {
                type = "object"
                dynamic "property" {
                  for_each = concat(inline_payload.value.properties, [merge(local.requester_property, { required = false })])
                  content {
                    name        = property.value.name
                    type        = property.value.type
                    description = property.value.description
                    required    = property.value.required
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
