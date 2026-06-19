##############################################################################
# IAM — processor execution role
#
# Least privilege: write logs, emit X-Ray segments, read/ack the work queue, and
# read+write only the idempotency DynamoDB table (the items Powertools manages).
##############################################################################

data "aws_iam_policy_document" "processor_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "processor_exec" {
  name               = "${var.name_prefix}-processor-exec"
  assume_role_policy = data.aws_iam_policy_document.processor_assume.json
}

data "aws_iam_policy_document" "processor" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.processor.arn}:*"]
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
    resources = [aws_sqs_queue.work.arn]
  }

  # Exactly the actions Powertools' DynamoDB persistence layer performs.
  statement {
    sid    = "IdempotencyStore"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
    ]
    resources = [aws_dynamodb_table.idempotency.arn]
  }
}

resource "aws_iam_role_policy" "processor" {
  name   = "processor"
  role   = aws_iam_role.processor_exec.id
  policy = data.aws_iam_policy_document.processor.json
}

resource "aws_iam_role_policy_attachment" "processor_xray" {
  count      = var.enable_xray_tracing ? 1 : 0
  role       = aws_iam_role.processor_exec.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}
