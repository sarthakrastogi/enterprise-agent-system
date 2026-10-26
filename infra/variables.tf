variable "project" {
  description = "Prefix for every resource name. Lowercase letters and digits only."
  type        = string
  default     = "eap"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,11}$", var.project))
    error_message = "project must be 2-12 lowercase letters/digits, starting with a letter."
  }
}

variable "region" {
  description = "AWS region. Must offer AgentCore Runtime, Gateway, Memory, Policy and Evaluations."
  type        = string
  default     = "us-west-2"
}

variable "agent_image_tag" {
  description = "Tag of the shared agent runtime image in ECR (content hash). Set by scripts/deploy.sh."
  type        = string
}

variable "mcp_image_tag" {
  description = "Tag of the knowledge MCP server image in ECR (content hash). Set by scripts/deploy.sh."
  type        = string
}

variable "ui_callback_urls" {
  description = "OIDC redirect URIs for the chat UI (Streamlit uses <base>/oauth2callback)."
  type        = list(string)
  default     = ["http://localhost:8501/oauth2callback"]
}

variable "ui_logout_urls" {
  description = "Where Cognito may send users after sign-out."
  type        = list(string)
  default     = ["http://localhost:8501"]
}

variable "policy_mode" {
  description = "Gateway Cedar policy mode. LOG_ONLY records decisions without blocking; switch to ENFORCE once the decision logs look right."
  type        = string
  default     = "LOG_ONLY"

  validation {
    condition     = contains(["LOG_ONLY", "ENFORCE"], var.policy_mode)
    error_message = "policy_mode must be LOG_ONLY or ENFORCE."
  }
}

variable "enable_transaction_search" {
  description = "Turn on CloudWatch Transaction Search (account+region wide, needed for traces and evaluations). Set false if it's already managed elsewhere."
  type        = bool
  default     = true
}

variable "trace_indexing_percentage" {
  description = "Percentage of traces indexed by Transaction Search."
  type        = number
  default     = 10
}

variable "eval_sampling_percentage" {
  description = "Percentage of agent sessions scored by online evaluation."
  type        = number
  default     = 10
}

variable "alarm_email" {
  description = "Email for CloudWatch alarm notifications. Empty disables the subscription."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Retention for log groups this stack creates."
  type        = number
  default     = 30
}
