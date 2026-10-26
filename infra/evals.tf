# Online evaluation: AgentCore scores a sample of real sessions with built-in
# LLM judges and writes results to CloudWatch (/aws/bedrock-agentcore/evaluations/...).

resource "aws_iam_role" "evaluation" {
  name = "${var.project}-evaluation"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account, "aws:ResourceAccount" = local.account }
        ArnLike = { "aws:SourceArn" = [
          "arn:aws:bedrock-agentcore:${local.region}:${local.account}:evaluator/*",
          "arn:aws:bedrock-agentcore:${local.region}:${local.account}:online-evaluation-config/*",
        ] }
      }
    }]
  })
}

resource "aws_iam_role_policy" "evaluation" {
  role = aws_iam_role.evaluation.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadTraces"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups", "logs:GetQueryResults", "logs:StartQuery"]
        Resource = "*"
      },
      {
        Sid      = "WriteResults"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/bedrock-agentcore/evaluations/*"
      },
      {
        Sid    = "IndexSpans"
        Effect = "Allow"
        Action = ["logs:DescribeIndexPolicies", "logs:PutIndexPolicy"]
        Resource = [
          "arn:aws:logs:${local.region}:${local.account}:log-group:aws/spans",
          "arn:aws:logs:${local.region}:${local.account}:log-group:aws/spans:*",
          "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/bedrock-agentcore/runtimes/*",
        ]
      },
      {
        Sid    = "JudgeModels"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:*:${local.account}:inference-profile/*",
        ]
      },
    ]
  })
}

resource "aws_bedrockagentcore_online_evaluation_config" "agent" {
  for_each = local.agents

  online_evaluation_config_name = "${var.project}_${each.key}"
  description                   = "Live quality scoring for ${each.key}"
  enable_on_create              = true
  evaluation_execution_role_arn = aws_iam_role.evaluation.arn

  data_source_config {
    cloudwatch_logs {
      log_group_names = [local.agent_log_groups[each.key]]
      # For Runtime-hosted agents the OTEL service name is <runtime-name>.<endpoint>.
      service_names = ["${aws_bedrockagentcore_agent_runtime.agent[each.key].agent_runtime_name}.DEFAULT"]
    }
  }

  evaluator { evaluator_id = "Builtin.GoalSuccessRate" }
  evaluator { evaluator_id = "Builtin.Helpfulness" }
  evaluator { evaluator_id = "Builtin.Correctness" }
  evaluator { evaluator_id = "Builtin.ToolSelectionAccuracy" }

  rule {
    sampling_config {
      sampling_percentage = var.eval_sampling_percentage
    }
    session_config {
      session_timeout_minutes = 15
    }
  }

  depends_on = [aws_iam_role_policy.evaluation, aws_xray_indexing_rule.default]
}
