##############################################################################
# IAM — Lambda execution role and Step Functions role
#
# Both roles are scoped with concrete ARNs derived from the caller identity /
# partition / region data sources rather than wildcards on resources.
##############################################################################

#############################
# Lambda execution role
#############################

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    sid     = "LambdaAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.name_prefix}-saga-lambda"
  description        = "Execution role for the saga Lambda functions."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "lambda_exec" {
  # Scoped CloudWatch Logs access for this module's functions only.
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${var.name_prefix}-*:*",
    ]
  }

  # The handlers read and write a single saga record per execution.
  statement {
    sid    = "SagaStateTable"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
    ]
    resources = [
      aws_dynamodb_table.saga_state.arn,
    ]
  }

  # X-Ray segment publishing (used only when tracing is enabled, but harmless to grant).
  statement {
    sid    = "XRay"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_exec" {
  name   = "${var.name_prefix}-saga-lambda"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_exec.json
}

#############################
# Step Functions role
#############################

data "aws_iam_policy_document" "sfn_assume" {
  statement {
    sid     = "StatesAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    # Confused-deputy protection: only allow assumption on behalf of state
    # machines in this account.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "sfn_exec" {
  name               = "${var.name_prefix}-saga-sfn"
  description        = "Execution role for the saga Step Functions state machine."
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "sfn_exec" {
  # Invoke exactly the nine saga functions — no wildcards.
  statement {
    sid       = "InvokeSagaFunctions"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [for fn in aws_lambda_function.saga : fn.arn]
  }

  # CloudWatch Logs delivery for state-machine execution logging. These actions
  # do not support resource-level permissions and must be granted on "*".
  statement {
    sid    = "StateMachineLogDelivery"
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

resource "aws_iam_role_policy" "sfn_exec" {
  name   = "${var.name_prefix}-saga-sfn"
  role   = aws_iam_role.sfn_exec.id
  policy = data.aws_iam_policy_document.sfn_exec.json
}
