##############################################################################
# Retry-with-backoff pattern — SQS -> Lambda with exponential backoff + jitter
#
# SQS already redelivers a message whose visibility timeout expires before it is
# deleted, and redrives it to a dead-letter queue after maxReceiveCount receives.
# What plain SQS does NOT give you is a *growing* delay between attempts: every
# retry uses the same fixed visibility timeout, so a struggling downstream gets
# hammered at a constant rate.
#
# This pattern keeps the durable SQS + DLQ substrate but makes the processor
# Lambda compute a per-message backoff from the SQS ApproximateReceiveCount and
# extend that message's visibility via ChangeMessageVisibility before reporting
# it as a batch-item failure. The delay grows exponentially (base * 2^(n-1)),
# is capped at backoff_max_seconds, and uses *full jitter* so a thundering herd
# of simultaneously-failed messages spreads its retries out instead of
# synchronising. After max_receive_count attempts SQS redrives the message to the
# DLQ for inspection or replay.
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(
    {
      Project = "aws-serverless-patterns"
      Pattern = "retry-backoff"
      Module  = "patterns/retry-backoff"
    },
    var.tags,
  )

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  # SQS visibility timeout must comfortably exceed the Lambda timeout so an
  # in-flight message is not redelivered while the worker is still processing it.
  # The handler overrides this per message with the computed backoff on failure.
  visibility_timeout_s = var.lambda_timeout_s * 6
}

##############################################################################
# SQS — work queue + dead-letter queue
##############################################################################

# Poison messages land here after max_receive_count failed attempts. Retained
# for the maximum 14 days so they can be inspected and replayed.
resource "aws_sqs_queue" "work_dlq" {
  name                      = "${var.name_prefix}-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "work" {
  name                       = "${var.name_prefix}-queue"
  visibility_timeout_seconds = local.visibility_timeout_s
  message_retention_seconds  = var.message_retention_seconds
  sqs_managed_sse_enabled    = true

  # Redrive to the DLQ once a message has been received max_receive_count times.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.work_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

# The DLQ only accepts redriven messages from its own source queue.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.work_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.work.arn]
  })
}

##############################################################################
# Processor Lambda
##############################################################################

data "archive_file" "processor_src" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/processor_src.zip"
  excludes    = ["__pycache__", "requirements.txt", "*.pyc"]
}

resource "aws_cloudwatch_log_group" "processor" {
  name              = "/aws/lambda/${var.name_prefix}-processor"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "processor" {
  function_name = "${var.name_prefix}-processor"
  description   = "SQS processor applying exponential backoff with full jitter before redrive to the DLQ."
  role          = aws_iam_role.processor_exec.arn
  runtime       = var.lambda_runtime
  handler       = "handler.handle"
  memory_size   = var.lambda_memory_mb
  timeout       = var.lambda_timeout_s

  filename         = data.archive_file.processor_src.output_path
  source_code_hash = data.archive_file.processor_src.output_base64sha256

  environment {
    variables = {
      QUEUE_URL            = aws_sqs_queue.work.url
      BACKOFF_BASE_SECONDS = tostring(var.backoff_base_seconds)
      BACKOFF_MAX_SECONDS  = tostring(var.backoff_max_seconds)
      MAX_RECEIVE_COUNT    = tostring(var.max_receive_count)
      LOG_LEVEL            = var.log_level
    }
  }

  tracing_config {
    mode = var.enable_xray_tracing ? "Active" : "PassThrough"
  }

  depends_on = [aws_cloudwatch_log_group.processor]
}

# SQS -> Lambda with partial batch responses. Successful records in a batch are
# deleted; the handler extends the visibility timeout of each failed record (the
# backoff) before returning it in batchItemFailures, so only failures are
# redelivered and they come back on a growing, jittered schedule.
resource "aws_lambda_event_source_mapping" "processor" {
  event_source_arn                   = aws_sqs_queue.work.arn
  function_name                      = aws_lambda_function.processor.arn
  batch_size                         = var.batch_size
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}
