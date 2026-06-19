##############################################################################
# Idempotent processor pattern — SQS -> Lambda (Powertools Idempotency + DynamoDB)
#
# SQS delivers at-least-once: the same message can arrive more than once (on
# visibility-timeout expiry, redrive, or producer retry). Without protection a
# "charge the card" or "send the email" side effect would run twice.
#
# This pattern wraps the processing function with AWS Lambda Powertools'
# @idempotent decorator backed by a DynamoDB persistence layer. The first time a
# given idempotency key is seen, Powertools records an INPROGRESS item, runs the
# function, and stores the result; any later invocation with the same key short-
# circuits and returns the stored result instead of re-running the side effect.
# A DynamoDB TTL expires records after idempotency_ttl_seconds.
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(
    {
      Project = "aws-serverless-patterns"
      Pattern = "idempotent-processor"
      Module  = "patterns/idempotent-processor"
    },
    var.tags,
  )

  partition = data.aws_partition.current.partition
  region    = data.aws_region.current.name

  visibility_timeout_s = var.lambda_timeout_s * 6

  powertools_layer_arn = coalesce(
    var.powertools_layer_arn_override,
    "arn:${local.partition}:lambda:${local.region}:${var.powertools_layer_account}:layer:${var.powertools_layer_name}:${var.powertools_layer_version}",
  )
}

##############################################################################
# DynamoDB — Powertools idempotency persistence store
##############################################################################

resource "aws_dynamodb_table" "idempotency" {
  name         = "${var.name_prefix}-store"
  billing_mode = "PAY_PER_REQUEST" # spiky, key-value access — on-demand fits best
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  # Powertools writes its TTL into the "expiration" attribute (epoch seconds).
  ttl {
    attribute_name = "expiration"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  server_side_encryption {
    enabled = true
  }
}

##############################################################################
# SQS — work queue + dead-letter queue
##############################################################################

resource "aws_sqs_queue" "work_dlq" {
  name                      = "${var.name_prefix}-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "work" {
  name                       = "${var.name_prefix}-queue"
  visibility_timeout_seconds = local.visibility_timeout_s
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.work_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

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
  description   = "Exactly-once SQS processor using Powertools idempotency over DynamoDB."
  role          = aws_iam_role.processor_exec.arn
  runtime       = var.lambda_runtime
  handler       = "handler.handle"
  memory_size   = var.lambda_memory_mb
  timeout       = var.lambda_timeout_s

  filename         = data.archive_file.processor_src.output_path
  source_code_hash = data.archive_file.processor_src.output_base64sha256

  layers = [local.powertools_layer_arn]

  environment {
    variables = {
      IDEMPOTENCY_TABLE      = aws_dynamodb_table.idempotency.name
      LOG_LEVEL              = var.log_level
      POWERTOOLS_LOG_LEVEL   = var.log_level
      POWERTOOLS_SERVICE_NAME = var.name_prefix
    }
  }

  tracing_config {
    mode = var.enable_xray_tracing ? "Active" : "PassThrough"
  }

  depends_on = [aws_cloudwatch_log_group.processor]
}

# SQS -> Lambda with partial batch responses. Idempotency guards against the
# duplicate deliveries this mapping can produce (visibility-timeout expiry,
# redrive, etc.).
resource "aws_lambda_event_source_mapping" "processor" {
  event_source_arn                   = aws_sqs_queue.work.arn
  function_name                      = aws_lambda_function.processor.arn
  batch_size                         = var.batch_size
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}
