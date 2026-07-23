locals {
  lambda_enabled = var.lambda_image_uri != null
}

resource "aws_cloudwatch_event_bus" "application" {
  name = "${var.name_prefix}-application"
}

resource "aws_cloudwatch_event_archive" "application" {
  name             = "${var.name_prefix}-application"
  event_source_arn = aws_cloudwatch_event_bus.application.arn
  retention_days   = 7
  description      = "Short replay window for ticket events"
}

resource "aws_sqs_queue" "dead_letter" {
  name                      = "${var.name_prefix}-ticket-automation-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "automation" {
  name                       = "${var.name_prefix}-ticket-automation"
  visibility_timeout_seconds = 180
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dead_letter" {
  queue_url = aws_sqs_queue.dead_letter.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.automation.arn]
  })
}

resource "aws_cloudwatch_event_rule" "ticket_automation" {
  name           = "${var.name_prefix}-ticket-automation"
  description    = "Route ticket automation requests to a durable queue"
  event_bus_name = aws_cloudwatch_event_bus.application.name
  state          = "ENABLED"

  event_pattern = jsonencode({
    source      = ["helios.ticket"]
    detail-type = ["helios.ticket.created.v1", "helios.automation.requested.v1"]
  })
}

resource "aws_cloudwatch_event_target" "automation_queue" {
  rule           = aws_cloudwatch_event_rule.ticket_automation.name
  event_bus_name = aws_cloudwatch_event_bus.application.name
  target_id      = "ticket-automation-queue"
  arn            = aws_sqs_queue.automation.arn

  dead_letter_config {
    arn = aws_sqs_queue.dead_letter.arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }
}

data "aws_iam_policy_document" "automation_queue" {
  statement {
    sid    = "AllowEventBridgeDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.automation.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.ticket_automation.arn]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.automation.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "automation" {
  queue_url = aws_sqs_queue.automation.id
  policy    = data.aws_iam_policy_document.automation_queue.json
}

data "aws_iam_policy_document" "dead_letter_queue" {
  statement {
    sid    = "AllowEventBridgeDeadLetterDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dead_letter.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.ticket_automation.arn]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.dead_letter.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "dead_letter" {
  queue_url = aws_sqs_queue.dead_letter.id
  policy    = data.aws_iam_policy_document.dead_letter_queue.json
}

resource "aws_cloudwatch_log_group" "lambda" {
  count = local.lambda_enabled ? 1 : 0

  name              = "/aws/lambda/${var.name_prefix}-ticket-automation"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "lambda" {
  count = local.lambda_enabled ? 1 : 0

  name = "${var.name_prefix}-ticket-automation-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  count = local.lambda_enabled ? 1 : 0

  name = "ticket-automation-runtime"
  role = aws_iam_role.lambda[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConsumeAutomationQueue"
        Effect = "Allow"
        Action = [
          "sqs:ChangeMessageVisibility",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage",
        ]
        Resource = aws_sqs_queue.automation.arn
      },
      {
        Sid    = "ReadApplicationSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
        ]
        Resource = var.application_secret_arns
      },
      {
        Sid    = "WriteFunctionLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.lambda[0].arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "automation" {
  count = local.lambda_enabled ? 1 : 0

  function_name = "${var.name_prefix}-ticket-automation"
  role          = aws_iam_role.lambda[0].arn
  package_type  = "Image"
  image_uri     = var.lambda_image_uri
  architectures = [var.lambda_architecture]

  memory_size                    = 256
  timeout                        = 30
  reserved_concurrent_executions = 2

  environment {
    variables = {
      APPLICATION_CONFIG_SECRET_ARN   = var.application_secret_arns[0]
      APPLICATION_DATABASE_SECRET_ARN = var.application_secret_arns[1]
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
  ]
}

resource "aws_lambda_event_source_mapping" "automation" {
  count = local.lambda_enabled ? 1 : 0

  event_source_arn                   = aws_sqs_queue.automation.arn
  function_name                      = aws_lambda_function.automation[0].arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
  enabled                            = true

  scaling_config {
    maximum_concurrency = 2
  }
}
