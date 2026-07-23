locals {
  namespace        = "helios-desk"
  oidc_hostpath    = replace(var.oidc_issuer_url, "https://", "")
  service_accounts = {
    bff        = "helios-bff"
    ticket     = "helios-ticket-service"
    automation = "helios-automation-service"
    backup     = "helios-postgres-backup"
  }
}

data "aws_iam_policy_document" "trust" {
  for_each = local.service_accounts

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_hostpath}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_hostpath}:sub"
      values   = ["system:serviceaccount:${local.namespace}:${each.value}"]
    }
  }
}

resource "aws_iam_role" "workload" {
  for_each = local.service_accounts

  name               = "${var.name_prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.trust[each.key].json

  tags = {
    KubernetesNamespace      = local.namespace
    KubernetesServiceAccount = each.value
  }
}

resource "aws_iam_role_policy" "bff" {
  name = "application-secrets"
  role = aws_iam_role.workload["bff"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadBffRuntimeSecrets"
      Effect = "Allow"
      Action = [
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue",
      ]
      Resource = [
        var.application_config_secret_arn,
        var.application_database_secret_arn,
      ]
    }]
  })
}

resource "aws_iam_role_policy" "ticket" {
  name = "database-and-event-publishing"
  role = aws_iam_role.workload["ticket"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadTicketRuntimeSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
        ]
        Resource = [
          var.application_config_secret_arn,
          var.application_database_secret_arn,
        ]
      },
      {
        Sid      = "PublishTicketEvents"
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = var.event_bus_arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "automation" {
  name = "secrets-and-queue-consumer"
  role = aws_iam_role.workload["automation"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "ReadAutomationRuntimeSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
        ]
        Resource = [
          var.application_config_secret_arn,
          var.application_database_secret_arn,
        ]
      },
      {
        Sid    = "ConsumeAutomationQueue"
        Effect = "Allow"
        Action = [
          "sqs:ChangeMessageVisibility",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage",
        ]
        Resource = var.automation_queue_arn
      },
    ], var.automation_lambda_function_arn == null ? [] : [{
      Sid      = "InvokeTicketAutomationLambda"
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = var.automation_lambda_function_arn
    }])
  })
}

resource "aws_iam_role_policy" "backup" {
  name = "database-secret-and-backup-prefix"
  role = aws_iam_role.workload["backup"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadDatabaseSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
        ]
        Resource = var.application_database_secret_arn
      },
      {
        Sid      = "ListBackupPrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:ListBucketMultipartUploads"]
        Resource = var.backup_bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = ["postgres", "postgres/*"]
          }
        }
      },
      {
        Sid    = "ReadWriteBackupObjects"
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
        ]
        Resource = "${var.backup_bucket_arn}/postgres/*"
      },
    ]
  })
}
