# One shared memory for the platform. Records are namespaced per user (actorId),
# so agents with `memory=True` share what they learn about a user.
# Namespaces must match eap/runtime/memory.py.

resource "aws_iam_role" "memory" {
  name               = "${var.project}-memory"
  assume_role_policy = data.aws_iam_policy_document.agentcore_assume.json
}

resource "aws_iam_role_policy_attachment" "memory" {
  role       = aws_iam_role.memory.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockAgentCoreMemoryBedrockModelInferenceExecutionRolePolicy"
}

resource "aws_bedrockagentcore_memory" "this" {
  name                      = "${var.project}_memory"
  description               = "Conversation history and long-term user memory for platform agents"
  event_expiry_duration     = 90
  memory_execution_role_arn = aws_iam_role.memory.arn
}

resource "aws_bedrockagentcore_memory_strategy" "facts" {
  name                = "facts"
  memory_id           = aws_bedrockagentcore_memory.this.id
  type                = "SEMANTIC"
  description         = "Durable facts users mention (team, systems they use, ongoing issues)"
  namespace_templates = ["/users/{actorId}/facts/"]
}

resource "aws_bedrockagentcore_memory_strategy" "preferences" {
  name                = "preferences"
  memory_id           = aws_bedrockagentcore_memory.this.id
  type                = "USER_PREFERENCE"
  description         = "How each user likes answers (format, detail, tools)"
  namespace_templates = ["/users/{actorId}/preferences/"]

  # Strategy changes on one memory are applied one at a time.
  depends_on = [aws_bedrockagentcore_memory_strategy.facts]
}
