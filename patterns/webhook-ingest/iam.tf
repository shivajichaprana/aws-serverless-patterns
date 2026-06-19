##############################################################################
# IAM
#
# Two roles: one that lets API Gateway hand messages to the ingest queue, and a
# least-privilege consumer execution role that can read the queue, fetch the
# signing secret, write logs, and emit X-Ray segments.
##############################################################################

# ---------------------------------------------------------------------------
# API Gateway -> SQS integration role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "apigw_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_to_sqs" {
  name               = "${var.name_prefix}-apigw-sqs"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
}

data "aws_iam_policy_document" "apigw_send" {
  statement {
    sid       = "SendToIngestQueue"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.ingest.arn]
  }
}

resource "aws_iam_role_policy" "apigw_send" {
  name   = "send-message"
  role   = aws_iam_role.apigw_to_sqs.id
  policy = data.aws_iam_policy_document.apigw_send.json
}

# ---------------------------------------------------------------------------
# Account-level API Gateway CloudWatch Logs role (singleton, optional)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "apigw_cloudwatch" {
  count              = var.manage_account_cloudwatch_role ? 1 : 0
  name               = "${var.name_prefix}-apigw-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  count      = var.manage_account_cloudwatch_role ? 1 : 0
  role       = aws_iam_role.apigw_cloudwatch[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

# ---------------------------------------------------------------------------
# Consumer Lambda execution role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "consumer_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "consumer_exec" {
  name               = "${var.name_prefix}-consumer-exec"
  assume_role_policy = data.aws_iam_policy_document.consumer_assume.json
}

data "aws_iam_policy_document" "consumer" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.consumer.arn}:*"]
  }

  statement {
    sid    = "ConsumeQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.ingest.arn]
  }

  statement {
    sid       = "ReadSigningSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.secret_arn]
  }
}

resource "aws_iam_role_policy" "consumer" {
  name   = "consumer"
  role   = aws_iam_role.consumer_exec.id
  policy = data.aws_iam_policy_document.consumer.json
}

resource "aws_iam_role_policy_attachment" "consumer_xray" {
  count      = var.enable_xray_tracing ? 1 : 0
  role       = aws_iam_role.consumer_exec.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}
