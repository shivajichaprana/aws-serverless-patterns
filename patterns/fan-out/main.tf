##############################################################################
# Fan-out pattern — SNS -> SQS (per consumer) -> Lambda worker, each with a DLQ
#
# A single SNS topic broadcasts every published message. Each consumer gets its
# own SQS queue subscribed to the topic (optionally with a filter policy), a
# dedicated dead-letter queue for poison messages, and a Lambda worker that
# drains the queue via an event source mapping with partial-batch responses.
#
# This buffering-on-fan-out design decouples producers from consumers: a slow or
# failing consumer backs up only its own queue, never the others, and the topic
# keeps accepting publishes.
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(
    {
      Project = "aws-serverless-patterns"
      Pattern = "fan-out"
      Module  = "patterns/fan-out"
    },
    var.tags,
  )

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  fifo_suffix = var.fifo_topic ? ".fifo" : ""

  # SQS visibility timeout must comfortably exceed the Lambda timeout so an
  # in-flight message is not redelivered while the worker is still processing it.
  visibility_timeout_s = var.lambda_timeout_s * 6
}

##############################################################################
# SNS — fan-out topic
##############################################################################

resource "aws_sns_topic" "fanout" {
  name                        = "${var.name_prefix}-topic${local.fifo_suffix}"
  fifo_topic                  = var.fifo_topic
  content_based_deduplication = var.fifo_topic ? true : null

  # Encrypt at rest with the AWS-managed SNS key. Swap for a customer-managed
  # CMK if you need key rotation control or cross-account grants.
  kms_master_key_id = "alias/aws/sns"
}

##############################################################################
# Per-consumer queues, DLQs, subscriptions, and workers
##############################################################################

# Main consumer queues.
resource "aws_sqs_queue" "consumer" {
  for_each = var.consumers

  name                        = "${var.name_prefix}-${each.key}${local.fifo_suffix}"
  fifo_queue                  = var.fifo_topic
  content_based_deduplication = var.fifo_topic ? true : null

  visibility_timeout_seconds = local.visibility_timeout_s
  message_retention_seconds  = var.message_retention_seconds
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.consumer_dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })
}

# Dead-letter queues — one per consumer, retained for the maximum 14 days so
# poison messages can be inspected and replayed.
resource "aws_sqs_queue" "consumer_dlq" {
  for_each = var.consumers

  name                        = "${var.name_prefix}-${each.key}-dlq${local.fifo_suffix}"
  fifo_queue                  = var.fifo_topic
  content_based_deduplication = var.fifo_topic ? true : null

  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

# Allow the redrive: the DLQ accepts redriven messages only from its source queue.
resource "aws_sqs_queue_redrive_allow_policy" "consumer_dlq" {
  for_each = var.consumers

  queue_url = aws_sqs_queue.consumer_dlq[each.key].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.consumer[each.key].arn]
  })
}

# Resource policy letting the SNS topic deliver to each consumer queue.
resource "aws_sqs_queue_policy" "consumer" {
  for_each = var.consumers

  queue_url = aws_sqs_queue.consumer[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSNSDelivery"
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.consumer[each.key].arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.fanout.arn }
      }
    }]
  })
}

# SNS -> SQS subscriptions. raw_message_delivery keeps the original payload (no
# SNS envelope) so workers parse the message body directly. Optional per-consumer
# filter policies restrict which messages reach the queue.
resource "aws_sns_topic_subscription" "consumer" {
  for_each = var.consumers

  topic_arn            = aws_sns_topic.fanout.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.consumer[each.key].arn
  raw_message_delivery = true

  filter_policy       = each.value.filter_policy
  filter_policy_scope = each.value.filter_policy == null ? null : "MessageAttributes"

  # Failed SNS deliveries (e.g. queue throttling) are redriven to the consumer DLQ.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.consumer_dlq[each.key].arn
  })

  depends_on = [aws_sqs_queue_policy.consumer]
}

##############################################################################
# Lambda workers
##############################################################################

data "archive_file" "worker_src" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/worker_src.zip"
  excludes    = ["__pycache__", "requirements.txt", "*.pyc"]
}

resource "aws_cloudwatch_log_group" "worker" {
  for_each = var.consumers

  name              = "/aws/lambda/${var.name_prefix}-${each.key}-worker"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "worker" {
  for_each = var.consumers

  function_name = "${var.name_prefix}-${each.key}-worker"
  description   = "Fan-out worker draining the ${each.key} queue."
  role          = aws_iam_role.worker_exec.arn
  runtime       = var.lambda_runtime
  handler       = each.value.handler
  memory_size   = var.lambda_memory_mb
  timeout       = var.lambda_timeout_s

  filename         = data.archive_file.worker_src.output_path
  source_code_hash = data.archive_file.worker_src.output_base64sha256

  environment {
    variables = {
      CONSUMER_NAME = each.key
      LOG_LEVEL     = var.log_level
    }
  }

  tracing_config {
    mode = var.enable_xray_tracing ? "Active" : "PassThrough"
  }

  depends_on = [aws_cloudwatch_log_group.worker]
}

# Event source mapping: SQS -> Lambda with partial batch responses so a single
# bad record does not fail (and re-deliver) the whole batch.
resource "aws_lambda_event_source_mapping" "worker" {
  for_each = var.consumers

  event_source_arn                   = aws_sqs_queue.consumer[each.key].arn
  function_name                      = aws_lambda_function.worker[each.key].arn
  batch_size                         = each.value.batch_size
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}
