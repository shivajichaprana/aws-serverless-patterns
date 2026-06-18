##############################################################################
# IAM — shared worker execution role
#
# One execution role is shared by every consumer worker. It can write logs,
# emit X-Ray segments, and consume from / acknowledge only the fan-out queues
# created by this module (least privilege scoped by resource ARN).
##############################################################################

data "aws_iam_policy_document" "worker_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "worker_exec" {
  name               = "${var.name_prefix}-worker-exec"
  assume_role_policy = data.aws_iam_policy_document.worker_assume.json
}

# Basic execution: write to the worker log groups created in main.tf.
data "aws_iam_policy_document" "worker_logs" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [for lg in aws_cloudwatch_log_group.worker : "${lg.arn}:*"]
  }
}

resource "aws_iam_role_policy" "worker_logs" {
  name   = "logs"
  role   = aws_iam_role.worker_exec.id
  policy = data.aws_iam_policy_document.worker_logs.json
}

# SQS consume permissions, scoped to the consumer queues only.
data "aws_iam_policy_document" "worker_sqs" {
  statement {
    sid    = "ConsumeQueues"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [for q in aws_sqs_queue.consumer : q.arn]
  }
}

resource "aws_iam_role_policy" "worker_sqs" {
  name   = "sqs-consume"
  role   = aws_iam_role.worker_exec.id
  policy = data.aws_iam_policy_document.worker_sqs.json
}

# X-Ray write access (only attached when tracing is enabled).
resource "aws_iam_role_policy_attachment" "worker_xray" {
  count      = var.enable_xray_tracing ? 1 : 0
  role       = aws_iam_role.worker_exec.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}
