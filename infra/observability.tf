# CloudWatch observability:
#  - Transaction Search (account-wide) so OTEL spans are stored and searchable;
#    the GenAI Observability console and Evaluations depend on it.
#  - Gateway and Memory application logs + traces (runtimes log automatically).
#  - Runtime usage logs (per-session vCPU/GB-hours) for cost showback.
#  - A dashboard, alarms on the platform's own metrics, and a feedback log group.

# --- Transaction Search ------------------------------------------------------------

resource "aws_cloudwatch_log_resource_policy" "xray_spans" {
  count       = var.enable_transaction_search ? 1 : 0
  policy_name = "${var.project}-TransactionSearchXRayAccess"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TransactionSearchXRayAccess"
      Effect    = "Allow"
      Principal = { Service = "xray.amazonaws.com" }
      Action    = "logs:PutLogEvents"
      Resource = [
        "arn:aws:logs:${local.region}:${local.account}:log-group:aws/spans:*",
        "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/application-signals/data:*",
        # agents deliver spans to their own log groups (unified trace destination)
        "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/bedrock-agentcore/runtimes/*:*",
      ]
      Condition = {
        ArnLike      = { "aws:SourceArn" = "arn:aws:xray:${local.region}:${local.account}:*" }
        StringEquals = { "aws:SourceAccount" = local.account }
      }
    }]
  })
}

resource "aws_xray_trace_segment_destination" "this" {
  count       = var.enable_transaction_search ? 1 : 0
  destination = "CloudWatchLogs"
  depends_on  = [aws_cloudwatch_log_resource_policy.xray_spans]
}

resource "aws_xray_indexing_rule" "default" {
  count = var.enable_transaction_search ? 1 : 0
  name  = "Default"
  rule {
    probabilistic {
      desired_sampling_percentage = var.trace_indexing_percentage
    }
  }
  depends_on = [aws_xray_trace_segment_destination.this]
}

# --- vended logs and traces for gateway, memory and runtimes -----------------

locals {
  vended = merge(
    {
      gateway = { arn = aws_bedrockagentcore_gateway.this.gateway_arn, kind = "gateway", types = ["APPLICATION_LOGS", "TRACES"] }
      memory  = { arn = aws_bedrockagentcore_memory.this.arn, kind = "memory", types = ["APPLICATION_LOGS", "TRACES"] }
    },
    { for k, r in aws_bedrockagentcore_agent_runtime.agent :
      "agent-${k}" => { arn = r.agent_runtime_arn, kind = "runtime", types = ["USAGE_LOGS"] }
    },
  )

  vended_sources = merge([
    for k, v in local.vended : {
      for t in v.types : "${k}-${lower(t)}" => { resource = k, arn = v.arn, kind = v.kind, type = t }
    }
  ]...)
}

resource "aws_cloudwatch_log_group" "vended" {
  for_each          = local.vended
  name              = "/aws/vendedlogs/bedrock-agentcore/${var.project}/${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_delivery_source" "vended" {
  for_each     = local.vended_sources
  name         = "${var.project}-${each.key}"
  log_type     = each.value.type
  resource_arn = each.value.arn
}

resource "aws_cloudwatch_log_delivery_destination" "logs" {
  for_each = local.vended
  name     = "${var.project}-${each.key}-cwl"
  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.vended[each.key].arn
  }
}

resource "aws_cloudwatch_log_delivery_destination" "xray" {
  name                      = "${var.project}-xray"
  delivery_destination_type = "XRAY"
}

resource "aws_cloudwatch_log_delivery" "vended" {
  for_each             = local.vended_sources
  delivery_source_name = aws_cloudwatch_log_delivery_source.vended[each.key].name
  delivery_destination_arn = (
    each.value.type == "TRACES"
    ? aws_cloudwatch_log_delivery_destination.xray.arn
    : aws_cloudwatch_log_delivery_destination.logs[each.value.resource].arn
  )
  depends_on = [aws_xray_trace_segment_destination.this]
}

# --- user feedback from the chat UI ------------------------------------------------

resource "aws_cloudwatch_log_group" "feedback" {
  name              = "/${var.project}/feedback"
  retention_in_days = 365
}

resource "aws_cloudwatch_log_stream" "feedback_ui" {
  name           = "ui"
  log_group_name = aws_cloudwatch_log_group.feedback.name
}

# --- alarms --------------------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  name = "${var.project}-alarms"
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "agent_failures" {
  for_each            = local.agents
  alarm_name          = "${var.project}-${each.key}-failed-turns"
  alarm_description   = "Agent ${each.key}: 3+ failed turns in 5 minutes. Check the runtime log group for 'agent run failed'."
  namespace           = "EAP/Agents"
  metric_name         = "FailedTurns"
  dimensions          = { Agent = each.key }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "agent_latency" {
  for_each            = local.agents
  alarm_name          = "${var.project}-${each.key}-slow-turns"
  alarm_description   = "Agent ${each.key}: p90 turn latency above 60s for 15 minutes."
  namespace           = "EAP/Agents"
  metric_name         = "TurnLatency"
  dimensions          = { Agent = each.key }
  extended_statistic  = "p90"
  period              = 300
  evaluation_periods  = 3
  threshold           = 60000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

# --- dashboard ---------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "platform" {
  dashboard_name = "${var.project}-agents"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "Turns per agent"
          region  = local.region
          stat    = "Sum"
          period  = 300
          metrics = [[{ expression = "SEARCH('{EAP/Agents,Agent} MetricName=\"Turns\"', 'Sum', 300)", id = "turns" }]]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "Failed turns per agent"
          region  = local.region
          stat    = "Sum"
          period  = 300
          metrics = [[{ expression = "SEARCH('{EAP/Agents,Agent} MetricName=\"FailedTurns\"', 'Sum', 300)", id = "failed" }]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title   = "Turn latency p90 (ms)"
          region  = local.region
          period  = 300
          metrics = [[{ expression = "SEARCH('{EAP/Agents,Agent} MetricName=\"TurnLatency\"', 'p90', 300)", id = "lat" }]]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title   = "Tool calls per agent"
          region  = local.region
          period  = 300
          metrics = [[{ expression = "SEARCH('{EAP/Agents,Agent} MetricName=\"ToolCalls\"', 'Sum', 300)", id = "tools" }]]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "AgentCore: invocations, errors, throttles"
          region = local.region
          period = 300
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock-AgentCore} MetricName=\"Invocations\"', 'Sum', 300)", id = "inv" }],
            [{ expression = "SEARCH('{AWS/Bedrock-AgentCore} MetricName=\"SystemErrors\"', 'Sum', 300)", id = "sys" }],
            [{ expression = "SEARCH('{AWS/Bedrock-AgentCore} MetricName=\"Throttles\"', 'Sum', 300)", id = "thr" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title   = "AgentCore: compute used (vCPU-hours)"
          region  = local.region
          period  = 3600
          metrics = [[{ expression = "SEARCH('{AWS/Bedrock-AgentCore,Name,Resource,Service} MetricName=\"CPUUsed-vCPUHours\"', 'Sum', 3600)", id = "cpu" }]]
        }
      },
      {
        type = "log", x = 0, y = 18, width = 24, height = 6
        properties = {
          title  = "Recent agent failures"
          region = local.region
          query  = "SOURCE ${join(" | SOURCE ", [for g in values(local.agent_log_groups) : "'${g}'"])} | fields @timestamp, @log, @message | filter @message like /agent run failed/ | sort @timestamp desc | limit 50"
          view   = "table"
        }
      },
      {
        type = "log", x = 0, y = 24, width = 24, height = 6
        properties = {
          title  = "User feedback"
          region = local.region
          query  = "SOURCE '${aws_cloudwatch_log_group.feedback.name}' | fields @timestamp, agent, rating, session_id | sort @timestamp desc | limit 50"
          view   = "table"
        }
      },
    ]
  })
}
