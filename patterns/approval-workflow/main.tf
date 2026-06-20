##############################################################################
# Approval-workflow pattern — core resources
#
# A Step Functions workflow that pauses on a human-approval gate using a task
# token. The send_approval_email Lambda emails the approver(s) via SES with
# Approve/Reject links; clicking a link hits the HTTP API (apigateway.tf), whose
# decision_handler Lambda resumes the execution with SendTaskSuccess (approved)
# or SendTaskFailure (rejected).
#
# IAM is in iam.tf, SES identities in ses.tf, the API in apigateway.tf, and the
# state machine in step_functions.tf.
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(
    {
      Project = "aws-serverless-patterns"
      Pattern = "approval-workflow"
      Module  = "patterns/approval-workflow"
    },
    var.tags,
  )

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  # Deterministic public invoke URL for the approve/reject links. Built from the
  # API id (not the stage resource) so the Lambda env does not create a
  # Lambda -> stage -> integration -> Lambda dependency cycle.
  api_base_url = "https://${aws_apigatewayv2_api.this.id}.execute-api.${local.region}.amazonaws.com/${var.api_stage_name}"

  # The SES identity ARN for the verified sender, used to scope ses:SendEmail.
  from_identity_arn = "arn:${local.partition}:ses:${local.region}:${local.account_id}:identity/${var.from_address}"

  # Every entry becomes a Lambda function (all sharing one deployment package and
  # execution role) plus a dedicated CloudWatch log group.
  #
  #   prepare_request     - validate + persist the request (SFN Task)
  #   send_approval_email - email approver with token links (SFN .waitForTaskToken)
  #   decision_handler    - API Gateway target; resumes the execution
  #   on_approved         - terminal bookkeeping on approval (SFN Task)
  #   on_rejected         - terminal bookkeeping on rejection (SFN Task)
  approval_functions = {
    prepare_request     = { handler = "handlers.prepare_request", description = "Validate the request and persist it in PENDING state." }
    send_approval_email = { handler = "handlers.send_approval_email", description = "Email approver(s) Approve/Reject links carrying the task token." }
    decision_handler    = { handler = "handlers.decision_handler", description = "API Gateway target: resume the paused execution via SendTaskSuccess/Failure." }
    on_approved         = { handler = "handlers.on_approved", description = "Record the approval and run the gated action." }
    on_rejected         = { handler = "handlers.on_rejected", description = "Record the rejection." }
  }

  base_env = {
    TABLE_NAME = aws_dynamodb_table.approvals.name
    LOG_LEVEL  = var.log_level
  }

  email_env = {
    FROM_ADDRESS         = var.from_address
    APPROVER_ADDRESSES   = join(",", var.approver_addresses)
    API_BASE_URL         = local.api_base_url
    EMAIL_SUBJECT_PREFIX = var.email_subject_prefix
  }
}

##############################################################################
# Lambda deployment package
##############################################################################

data "archive_file" "approval_src" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/approval_src.zip"
  excludes    = ["__pycache__", "requirements.txt", "*.pyc"]
}

##############################################################################
# DynamoDB — approval-request store
##############################################################################

resource "aws_dynamodb_table" "approvals" {
  name         = "${var.name_prefix}-requests"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"

  attribute {
    name = "request_id"
    type = "S"
  }

  dynamic "ttl" {
    for_each = var.approval_ttl_days > 0 ? [1] : []
    content {
      attribute_name = "expires_at"
      enabled        = true
    }
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = local.tags
}

##############################################################################
# CloudWatch log groups — one per Lambda, created ahead of the function so the
# retention policy is enforced from the first invocation.
##############################################################################

resource "aws_cloudwatch_log_group" "approval_lambda" {
  for_each = local.approval_functions

  name              = "/aws/lambda/${var.name_prefix}-${replace(each.key, "_", "-")}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

##############################################################################
# Lambda functions
##############################################################################

resource "aws_lambda_function" "approval" {
  for_each = local.approval_functions

  function_name = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  description   = each.value.description
  role          = aws_iam_role.lambda_exec.arn
  handler       = each.value.handler
  runtime       = var.lambda_runtime
  memory_size   = var.lambda_memory_mb
  timeout       = var.lambda_timeout_s

  filename         = data.archive_file.approval_src.output_path
  source_code_hash = data.archive_file.approval_src.output_base64sha256

  environment {
    # Only the emailer needs SES / API-URL configuration; the rest get the base env.
    variables = each.key == "send_approval_email" ? merge(local.base_env, local.email_env) : local.base_env
  }

  tracing_config {
    mode = var.enable_xray_tracing ? "Active" : "PassThrough"
  }

  depends_on = [
    aws_cloudwatch_log_group.approval_lambda,
    aws_iam_role_policy.lambda_exec,
  ]

  tags = local.tags
}
