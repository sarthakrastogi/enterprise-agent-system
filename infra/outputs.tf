output "region" {
  value = local.region
}

output "agents" {
  description = "Agents for the chat UI (written to frontend/.streamlit/secrets.toml)."
  value = [
    for k, a in local.agents : {
      name         = k
      display_name = a.display_name
      description  = a.description
      arn          = aws_bedrockagentcore_agent_runtime.agent[k].agent_runtime_arn
    }
  ]
}

output "ecr_agent_runtime" {
  value = aws_ecr_repository.agent_runtime.repository_url
}

output "ecr_mcp_knowledge" {
  value = aws_ecr_repository.mcp_knowledge.repository_url
}

output "gateway_url" {
  value = aws_bedrockagentcore_gateway.this.gateway_url
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "cognito_ui_client_id" {
  value = aws_cognito_user_pool_client.ui.id
}

output "cognito_ui_client_secret" {
  value     = aws_cognito_user_pool_client.ui.client_secret
  sensitive = true
}

output "cognito_discovery_url" {
  value = local.cognito_discovery_url
}

output "cognito_hosted_ui" {
  value = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${local.region}.amazoncognito.com"
}

output "feedback_log_group" {
  value = aws_cloudwatch_log_group.feedback.name
}

output "dashboard_url" {
  value = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.platform.dashboard_name}"
}

output "genai_observability_url" {
  value = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#gen-ai-observability/agent-core"
}
