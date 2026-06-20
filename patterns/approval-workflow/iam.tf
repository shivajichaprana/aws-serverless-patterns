##############################################################################
# IAM — Lambda execution role and Step Functions role
#
# Resource ARNs are derived from the caller identity / partition / region data
# sources rather than wildcards wherever the action supports resource scoping.
##############################################################################

#############################
# Lambda execution role (shared by all five functions)
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
  name               = "${var.name_prefix}-lambda"
  description        = "Execution role for the approval-workflow Lambda functions."
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

  # Read/write the single approval record per request.
  statement {
    sid    = "ApprovalTable"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
    ]
    resources = [
      aws_dynamodb_table.approvals.arn,
    ]
  }

  # send_approval_email sends through SES, scoped to the verified sender identity.
  statement {
    sid    = "SendApprovalEmail"
    effect = "Allow"
    actions = [
      "ses:SendEmail",
      "ses:SendRawEmail",
    ]
    resources = [local.from_identity_arn]

    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.from_address]
    }
  }

  # decision_handler resumes paused executions. SendTask* are authorized by the
  # opaque task token, not by resource ARN, so they cannot be resource-scoped.
  statement {
    sid    = "ResumeExecution"
    effect = "Allow"
    actions = [
      "states:SendTaskSuccess",
      "states:SendTaskFailure",
      "states:SendTaskHeartbeat",
    ]
    resources = ["*"]
  }

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
  name   = "${var.name_prefix}-lambda"
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

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "sfn_exec" {
  name               = "${var.name_prefix}-sfn"
  description        = "Execution role for the approval-workflow state machine."
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "sfn_exec" {
  # Invoke only the four functions the state machine drives. decision_handler is
  # invoked by API Gateway, not Step Functions, so it is deliberately excluded.
  statement {
    sid    = "InvokeWorkflowFunctions"
    effect = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [
      aws_lambda_function.approval["prepare_request"].arn,
      aws_lambda_function.approval["send_approval_email"].arn,
      aws_lambda_function.approval["on_approved"].arn,
      aws_lambda_function.approval["on_rejected"].arn,
    ]
  }

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
  name   = "${var.name_prefix}-sfn"
  role   = aws_iam_role.sfn_exec.id
  policy = data.aws_iam_policy_document.sfn_exec.json
}
