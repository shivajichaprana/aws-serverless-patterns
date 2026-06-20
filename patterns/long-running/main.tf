##############################################################################
# Long-running workflow pattern — core resources
#
# Orchestrates an asynchronous job that may take minutes to days. The state
# machine (step_functions.tf) submits the job, then loops over a Wait state and
# a poll Task with exponential backoff so the execution consumes no compute while
# the job runs. On success it pauses on a task-token Task for human-in-the-loop
# sign-off, resuming only when SendTaskSuccess is called with the token.
#
# IAM is in iam.tf; the state machine is in step_functions.tf.
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(
    {
      Project = "aws-serverless-patterns"
      Pattern = "long-running"
      Module  = "patterns/long-running"
    },
    var.tags,
  )

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  # Every entry becomes a Lambda function (all sharing one deployment package and
  # execution role) plus a dedicated CloudWatch log group. The state machine
  # wires them together: submit -> (wait -> poll)* -> request_signoff -> finalize.
  job_functions = {
    submit_job      = { handler = "handlers.submit_job", description = "Kick off the asynchronous job and persist its initial state." }
    poll_job        = { handler = "handlers.poll_job", description = "Poll the job's status and compute the next backed-off wait interval." }
    request_signoff = { handler = "handlers.request_signoff", description = "Record the Step Functions task token and request human sign-off (paused until callback)." }
    finalize        = { handler = "handlers.finalize", description = "Mark the job COMPLETED after sign-off." }
  }
}

##############################################################################
# Lambda deployment package
##############################################################################

data "archive_file" "job_src" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/job_src.zip"
  excludes    = ["__pycache__", "requirements.txt", "*.pyc"]
}

##############################################################################
# DynamoDB — job state store
##############################################################################

resource "aws_dynamodb_table" "jobs" {
  name         = "${var.name_prefix}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }

  dynamic "ttl" {
    for_each = var.job_state_ttl_days > 0 ? [1] : []
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

resource "aws_cloudwatch_log_group" "job_lambda" {
  for_each = local.job_functions

  name              = "/aws/lambda/${var.name_prefix}-${replace(each.key, "_", "-")}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

##############################################################################
# Lambda functions — submit, poll, request sign-off, finalize
##############################################################################

resource "aws_lambda_function" "job" {
  for_each = local.job_functions

  function_name = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  description   = each.value.description
  role          = aws_iam_role.lambda_exec.arn
  handler       = each.value.handler
  runtime       = var.lambda_runtime
  memory_size   = var.lambda_memory_mb
  timeout       = var.lambda_timeout_s

  filename         = data.archive_file.job_src.output_path
  source_code_hash = data.archive_file.job_src.output_base64sha256

  environment {
    variables = {
      TABLE_NAME                 = aws_dynamodb_table.jobs.name
      LOG_LEVEL                  = var.log_level
      POLL_INTERVAL_BASE_SECONDS = tostring(var.poll_interval_base_seconds)
      POLL_INTERVAL_MAX_SECONDS  = tostring(var.poll_interval_max_seconds)
      MAX_POLL_ATTEMPTS          = tostring(var.max_poll_attempts)
      JOB_STATE_TTL_DAYS         = tostring(var.job_state_ttl_days)
    }
  }

  tracing_config {
    mode = var.enable_xray_tracing ? "Active" : "PassThrough"
  }

  depends_on = [
    aws_cloudwatch_log_group.job_lambda,
    aws_iam_role_policy.lambda_exec,
  ]

  tags = local.tags
}
