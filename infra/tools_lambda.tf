# Lambda-backed tools ("tickets" gateway target) and the gateway request interceptor.

resource "aws_dynamodb_table" "tickets" {
  name         = "${var.project}-tickets"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ticket_id"

  attribute {
    name = "ticket_id"
    type = "S"
  }
  attribute {
    name = "requester"
    type = "S"
  }
  attribute {
    name = "created_at"
    type = "S"
  }

  global_secondary_index {
    name            = "by_requester"
    projection_type = "ALL"
    key_schema {
      attribute_name = "requester"
      key_type       = "HASH"
    }
    key_schema {
      attribute_name = "created_at"
      key_type       = "RANGE"
    }
  }

  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled = true
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- tickets tool --------------------------------------------------------------

data "archive_file" "tickets" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/tickets"
  output_path = "${path.module}/.build/tickets.zip"
  excludes    = ["__pycache__"]
}

resource "aws_iam_role" "tickets" {
  name               = "${var.project}-tickets-tool"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "tickets_logs" {
  role       = aws_iam_role.tickets.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "tickets" {
  role = aws_iam_role.tickets.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
      Resource = [aws_dynamodb_table.tickets.arn, "${aws_dynamodb_table.tickets.arn}/index/*"]
    }]
  })
}

resource "aws_cloudwatch_log_group" "tickets" {
  name              = "/aws/lambda/${var.project}-tickets-tool"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "tickets" {
  function_name    = "${var.project}-tickets-tool"
  role             = aws_iam_role.tickets.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.tickets.output_path
  source_code_hash = data.archive_file.tickets.output_base64sha256
  timeout          = 15
  memory_size      = 256

  environment {
    variables = { TICKETS_TABLE = aws_dynamodb_table.tickets.name }
  }
  tracing_config {
    mode = "Active"
  }
  depends_on = [aws_cloudwatch_log_group.tickets]
}

# --- gateway request interceptor --------------------------------------------

data "archive_file" "interceptor" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/interceptor"
  output_path = "${path.module}/.build/interceptor.zip"
  excludes    = ["__pycache__"]
}

resource "aws_iam_role" "interceptor" {
  name               = "${var.project}-gateway-interceptor"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "interceptor_logs" {
  role       = aws_iam_role.interceptor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "interceptor" {
  name              = "/aws/lambda/${var.project}-gateway-interceptor"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "interceptor" {
  function_name    = "${var.project}-gateway-interceptor"
  role             = aws_iam_role.interceptor.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.interceptor.output_path
  source_code_hash = data.archive_file.interceptor.output_base64sha256
  timeout          = 5
  memory_size      = 128

  environment {
    variables = { IDENTITY_TARGETS = "tickets" }
  }
  depends_on = [aws_cloudwatch_log_group.interceptor]
}
