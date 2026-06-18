##############################################################################
# IAM — Lambda execution, Step Functions execution, and Scheduler roles
##############################################################################

# ---- Lambda execution role (shared by split/process/reduce) ----
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.name_prefix}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_logs" {
  statement {
    sid     = "Logs"
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [for lg in aws_cloudwatch_log_group.batch : "${lg.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda_logs" {
  name   = "logs"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_logs.json
}

resource "aws_iam_role_policy_attachment" "lambda_xray" {
  count      = var.enable_xray_tracing ? 1 : 0
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# ---- Step Functions execution role ----
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn_exec" {
  name               = "${var.name_prefix}-sfn-exec"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

data "aws_iam_policy_document" "sfn_policy" {
  # Invoke only the three batch Lambdas.
  statement {
    sid       = "InvokeBatchLambdas"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [for fn in aws_lambda_function.batch : fn.arn]
  }

  # Delivery of execution logs (CloudWatch Logs vended-logs requires these at *).
  statement {
    sid    = "LogDelivery"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }

  # X-Ray write for distributed tracing.
  statement {
    sid    = "XRay"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sfn_policy" {
  name   = "sfn-policy"
  role   = aws_iam_role.sfn_exec.id
  policy = data.aws_iam_policy_document.sfn_policy.json
}

# ---- EventBridge Scheduler role (starts the state machine) ----
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    # Confused-deputy protection: only this account's scheduler may assume.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler_exec" {
  name               = "${var.name_prefix}-scheduler-exec"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler_policy" {
  statement {
    sid       = "StartBatch"
    effect    = "Allow"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.batch.arn]
  }
}

resource "aws_iam_role_policy" "scheduler_policy" {
  name   = "scheduler-policy"
  role   = aws_iam_role.scheduler_exec.id
  policy = data.aws_iam_policy_document.scheduler_policy.json
}
