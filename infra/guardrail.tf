# Bedrock Guardrail applied to every agent's model calls (see eap/runtime/builder.py).
# Note: model-level guardrails do not inspect tool results. Untrusted tool output
# (web pages, documents) needs checks at the gateway too.

resource "aws_bedrock_guardrail" "default" {
  name                      = "${var.project}-default"
  description               = "Baseline safety filters for all platform agents"
  blocked_input_messaging   = "Sorry, I can't help with that request."
  blocked_outputs_messaging = "Sorry, I can't share that response."

  content_policy_config {
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
    }
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "INSULTS"
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
    filters_config {
      type            = "MISCONDUCT"
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
  }

  sensitive_information_policy_config {
    # Card numbers never belong in a chat; block both ways.
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "BLOCK"
    }
    # Mask credentials and secrets the model might echo back.
    pii_entities_config {
      type   = "PASSWORD"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "AWS_SECRET_KEY"
      action = "BLOCK"
    }
  }
}

resource "aws_bedrock_guardrail_version" "default" {
  guardrail_arn = aws_bedrock_guardrail.default.guardrail_arn
  description   = "Managed by Terraform"

  lifecycle {
    replace_triggered_by = [aws_bedrock_guardrail.default]
  }
}
