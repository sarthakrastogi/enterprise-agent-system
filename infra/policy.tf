# Cedar policy for the gateway. Default deny: a tool nobody permits is neither
# listed nor callable. Users' Cognito groups arrive as the `cognito:groups` tag,
# serialised as JSON text (e.g. ["employees","platform-admins"]), hence `like`.
#
# Start in LOG_ONLY (var.policy_mode), check decisions in the gateway logs,
# then switch to ENFORCE.

resource "aws_bedrockagentcore_policy_engine" "this" {
  name        = "${var.project}_tools_policy"
  description = "Who may use which gateway tool"
}

locals {
  gateway_ref = "AgentCore::Gateway::\"${aws_bedrockagentcore_gateway.this.gateway_arn}\""

  # Tools every employee may use. A new tool stays denied until it is added here.
  employee_tools = [
    "knowledge___search_policies",
    "knowledge___get_policy",
    "tickets___create_ticket",
    "tickets___get_ticket",
    "tickets___list_my_tickets",
  ]
}

resource "aws_bedrockagentcore_policy" "employee_tools" {
  name             = "employee_tools"
  policy_engine_id = aws_bedrockagentcore_policy_engine.this.policy_engine_id
  description      = "Employees may search policies and manage their own tickets"

  definition {
    cedar {
      statement = <<-EOT
        permit(
          principal is AgentCore::OAuthUser,
          action in [${join(", ", [for t in local.employee_tools : "AgentCore::Action::\"${t}\""])}],
          resource == ${local.gateway_ref}
        )
        when {
          principal.hasTag("cognito:groups") &&
          principal.getTag("cognito:groups") like "*\"employees\"*"
        };
      EOT
    }
  }

  # Cedar actions are generated from the targets' tool schemas.
  depends_on = [aws_bedrockagentcore_gateway_target.knowledge, aws_bedrockagentcore_gateway_target.tickets]
}

resource "aws_bedrockagentcore_policy" "admin_close_ticket" {
  name             = "admin_close_ticket"
  policy_engine_id = aws_bedrockagentcore_policy_engine.this.policy_engine_id
  description      = "Only platform admins may close tickets"

  definition {
    cedar {
      statement = <<-EOT
        permit(
          principal is AgentCore::OAuthUser,
          action == AgentCore::Action::"tickets___close_ticket",
          resource == ${local.gateway_ref}
        )
        when {
          principal.hasTag("cognito:groups") &&
          principal.getTag("cognito:groups") like "*\"platform-admins\"*"
        };
      EOT
    }
  }

  depends_on = [aws_bedrockagentcore_gateway_target.tickets]
}
