# One AgentCore Runtime per agent in agents/*.py, all running the same image.
# AGENT_NAME tells the image which AgentSpec to load.

data "aws_iam_policy_document" "agent" {
  for_each = local.agents

  source_policy_documents = [data.aws_iam_policy_document.runtime_base.json]

  statement {
    sid = "InvokeModels"
    actions = [
      "bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream",
    ]
    # Cross-region inference profiles route to foundation models in other
    # regions, so the model resources are not region-scoped.
    resources = [
      "arn:aws:bedrock:*::foundation-model/*",
      "arn:aws:bedrock:*:${local.account}:inference-profile/*",
      "arn:aws:bedrock:*:*:inference-profile/*",
    ]
  }

  statement {
    sid       = "Guardrail"
    actions   = ["bedrock:ApplyGuardrail"]
    resources = [aws_bedrock_guardrail.default.guardrail_arn]
  }

  dynamic "statement" {
    for_each = each.value.memory ? [1] : []
    content {
      sid = "Memory"
      actions = [
        "bedrock-agentcore:CreateEvent", "bedrock-agentcore:ListEvents", "bedrock-agentcore:GetEvent",
        "bedrock-agentcore:RetrieveMemoryRecords", "bedrock-agentcore:ListMemoryRecords", "bedrock-agentcore:GetMemoryRecord",
      ]
      resources = [aws_bedrockagentcore_memory.this.arn]
    }
  }

  dynamic "statement" {
    for_each = each.value.code_interpreter ? [1] : []
    content {
      sid = "CodeInterpreter"
      actions = [
        "bedrock-agentcore:StartCodeInterpreterSession", "bedrock-agentcore:InvokeCodeInterpreter",
        "bedrock-agentcore:StopCodeInterpreterSession", "bedrock-agentcore:GetCodeInterpreterSession",
      ]
      resources = [
        "arn:aws:bedrock-agentcore:${local.region}:aws:code-interpreter/aws.codeinterpreter.v1",
        "arn:aws:bedrock-agentcore:${local.region}:${local.account}:code-interpreter/*",
      ]
    }
  }
}

# memory/code_interpreter in the manifest already include sub-agents' needs,
# because sub-agents run inside the parent's runtime (eap/manifest.py).
resource "aws_iam_role" "agent" {
  for_each           = local.agents
  name               = "${var.project}-agent-${replace(each.key, "_", "-")}"
  assume_role_policy = data.aws_iam_policy_document.agentcore_assume.json
}

resource "aws_iam_role_policy" "agent" {
  for_each = local.agents
  role     = aws_iam_role.agent[each.key].id
  policy   = data.aws_iam_policy_document.agent[each.key].json
}

resource "aws_bedrockagentcore_agent_runtime" "agent" {
  for_each = local.agents

  agent_runtime_name = "${var.project}_${each.key}"
  description        = substr(each.value.description, 0, 1200)
  role_arn           = aws_iam_role.agent[each.key].arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.agent_runtime.repository_url}:${var.agent_image_tag}"
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  protocol_configuration {
    server_protocol = "HTTP"
  }

  # Callers must present a Cognito access token from the chat UI client, and
  # belong to one of the agent's allowed groups if it declares any.
  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = local.cognito_discovery_url
      allowed_clients = [aws_cognito_user_pool_client.ui.id]

      dynamic "custom_claim" {
        for_each = length(each.value.allowed_groups) > 0 ? [1] : []
        content {
          inbound_token_claim_name       = "cognito:groups"
          inbound_token_claim_value_type = "STRING_ARRAY"
          authorizing_claim_match_value {
            claim_match_operator = "CONTAINS_ANY"
            claim_match_value {
              match_value_string_list = each.value.allowed_groups
            }
          }
        }
      }
    }
  }

  # Pass the user's token to the code so it can be forwarded to the gateway.
  request_header_configuration {
    request_header_allowlist = ["Authorization"]
  }

  lifecycle_configuration {
    idle_runtime_session_timeout = 900   # 15 min
    max_lifetime                 = 28800 # 8 h
  }

  environment_variables = {
    AGENT_NAME        = each.key
    GATEWAY_URL       = aws_bedrockagentcore_gateway.this.gateway_url
    MEMORY_ID         = each.value.memory ? aws_bedrockagentcore_memory.this.id : ""
    GUARDRAIL_ID      = aws_bedrock_guardrail.default.guardrail_id
    GUARDRAIL_VERSION = aws_bedrock_guardrail_version.default.version
  }

  tags = {
    agent         = each.key
    agent-version = each.value.version
  }

  depends_on = [aws_iam_role_policy.agent]
}

locals {
  # Where AgentCore writes each agent's logs and spans (DEFAULT endpoint).
  agent_log_groups = {
    for k, r in aws_bedrockagentcore_agent_runtime.agent :
    k => "/aws/bedrock-agentcore/runtimes/${r.agent_runtime_id}-DEFAULT"
  }
}
