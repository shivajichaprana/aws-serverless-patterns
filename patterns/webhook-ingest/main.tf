##############################################################################
# Webhook ingest pattern — API Gateway -> SQS (buffer + DLQ) -> Lambda
#
# A public REST endpoint accepts provider webhooks and hands the raw body
# straight to SQS via a direct AWS service integration (no "ingest Lambda" in
# the hot path). SQS absorbs bursts and provides retries + a dead-letter queue;
# a consumer Lambda then drains the queue, re-verifies the HMAC signature
# against a Secrets Manager key, and processes each event.
#
# Verifying *after* buffering keeps the synchronous request path tiny (API GW ->
# SQS only), so a slow downstream or a thundering herd of webhooks never causes
# the provider to see timeouts and retry-storm us. The trade-off is that an
# invalid-signature request is still accepted (202) and dropped asynchronously
# rather than rejected at the edge; flip enable_edge_signature_check notes in the
# README if you need synchronous rejection.
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(
    {
      Project = "aws-serverless-patterns"
      Pattern = "webhook-ingest"
      Module  = "patterns/webhook-ingest"
    },
    var.tags,
  )

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  # Visibility timeout must comfortably exceed the Lambda timeout so an in-flight
  # message is not redelivered while the consumer is still processing it.
  visibility_timeout_s = var.lambda_timeout_s * 6

  create_secret = var.webhook_secret_arn == null
  secret_arn    = local.create_secret ? aws_secretsmanager_secret.webhook[0].arn : var.webhook_secret_arn
}

##############################################################################
# SQS — ingest buffer + dead-letter queue
##############################################################################

resource "aws_sqs_queue" "ingest_dlq" {
  name                      = "${var.name_prefix}-dlq"
  message_retention_seconds = 1209600 # 14 days — max, so poison events can be inspected
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "ingest" {
  name                       = "${var.name_prefix}-queue"
  visibility_timeout_seconds = local.visibility_timeout_s
  message_retention_seconds  = var.message_retention_seconds
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingest_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

# Allow the DLQ to be a redrive target only from the ingest queue.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.ingest_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.ingest.arn]
  })
}

##############################################################################
# Secrets Manager — webhook signing key (created only when not supplied)
##############################################################################

resource "aws_secretsmanager_secret" "webhook" {
  count       = local.create_secret ? 1 : 0
  name        = "${var.name_prefix}/signing-key"
  description = "HMAC signing key used to verify inbound webhook signatures. Populate the value out-of-band."
}

##############################################################################
# REST API -> SQS direct integration
##############################################################################

resource "aws_api_gateway_rest_api" "this" {
  name        = var.name_prefix
  description = "Webhook ingest endpoint that forwards raw payloads to SQS."

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  # Reject oversized bodies before they reach the integration (SQS caps at 256 KB).
  minimum_compression_size = -1
}

resource "aws_api_gateway_request_validator" "body" {
  name                        = "validate-body"
  rest_api_id                 = aws_api_gateway_rest_api.this.id
  validate_request_body       = true
  validate_request_parameters = true
}

# /webhooks
resource "aws_api_gateway_resource" "webhooks" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "webhooks"
}

# /webhooks/{source}
resource "aws_api_gateway_resource" "source" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.webhooks.id
  path_part   = "{source}"
}

resource "aws_api_gateway_method" "post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.source.id
  http_method   = "POST"
  authorization = "NONE" # provider authenticity is established by HMAC signature, not IAM
  api_key_required = false

  request_parameters = {
    "method.request.path.source"                          = true
    "method.request.header.${var.signature_header}"       = true
  }

  request_validator_id = aws_api_gateway_request_validator.body.id
}

# Direct AWS service integration: API Gateway -> SQS SendMessage. The raw body is
# url-encoded into MessageBody; the signature header and {source} path part ride
# along as SQS message attributes so the consumer can verify without re-reading
# HTTP headers.
resource "aws_api_gateway_integration" "sqs" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.source.id
  http_method             = aws_api_gateway_method.post.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  credentials             = aws_iam_role.apigw_to_sqs.arn
  uri                     = "arn:${local.partition}:apigateway:${local.region}:sqs:path/${local.account_id}/${aws_sqs_queue.ingest.name}"

  passthrough_behavior = "NEVER"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  request_templates = {
    "application/json" = <<-EOT
      Action=SendMessage&MessageBody=$util.urlEncode($input.body)&MessageAttribute.1.Name=signature&MessageAttribute.1.Value.StringValue=$util.urlEncode($input.params().header.get('${var.signature_header}'))&MessageAttribute.1.Value.DataType=String&MessageAttribute.2.Name=source&MessageAttribute.2.Value.StringValue=$util.urlEncode($input.params('source'))&MessageAttribute.2.Value.DataType=String&MessageAttribute.3.Name=received_at&MessageAttribute.3.Value.StringValue=$context.requestTimeEpoch&MessageAttribute.3.Value.DataType=Number
    EOT
  }
}

# Return a terse 202 to the provider once the message is safely on the queue.
resource "aws_api_gateway_method_response" "accepted" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.source.id
  http_method = aws_api_gateway_method.post.http_method
  status_code = "202"

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_integration_response" "accepted" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.source.id
  http_method = aws_api_gateway_method.post.http_method
  status_code = aws_api_gateway_method_response.accepted.status_code

  # Hide the raw SQS SendMessage XML from the caller.
  response_templates = {
    "application/json" = jsonencode({ status = "accepted" })
  }

  depends_on = [aws_api_gateway_integration.sqs]
}

# Surface SQS throttling / errors as 5xx to the caller so they retry.
resource "aws_api_gateway_method_response" "server_error" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.source.id
  http_method = aws_api_gateway_method.post.http_method
  status_code = "500"
}

resource "aws_api_gateway_integration_response" "server_error" {
  rest_api_id       = aws_api_gateway_rest_api.this.id
  resource_id       = aws_api_gateway_resource.source.id
  http_method       = aws_api_gateway_method.post.http_method
  status_code       = aws_api_gateway_method_response.server_error.status_code
  selection_pattern = "5\\d{2}"

  response_templates = {
    "application/json" = jsonencode({ status = "error" })
  }

  depends_on = [aws_api_gateway_integration.sqs]
}

##############################################################################
# Deployment + stage (with access logging, throttling, optional tracing)
##############################################################################

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/${var.name_prefix}-access"
  retention_in_days = var.log_retention_days
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # Force a new deployment whenever the routing/integration surface changes.
  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.source.id,
      aws_api_gateway_method.post.id,
      aws_api_gateway_integration.sqs.id,
      aws_api_gateway_integration_response.accepted.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id           = aws_api_gateway_rest_api.this.id
  deployment_id         = aws_api_gateway_deployment.this.id
  stage_name            = "live"
  xray_tracing_enabled  = var.enable_xray_tracing
  cache_cluster_enabled = false

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      integrationErr = "$context.integration.error"
      responseLength = "$context.responseLength"
    })
  }

  depends_on = [aws_api_gateway_account.this]
}

resource "aws_api_gateway_method_settings" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = var.throttling_rate_limit
    throttling_burst_limit = var.throttling_burst_limit
    metrics_enabled        = true
    logging_level          = "INFO"
    data_trace_enabled     = false
  }
}

# API Gateway needs an account-level role to push access logs to CloudWatch.
# This is an account/region singleton — set manage_account_cloudwatch_role=false
# if another stack already owns it.
resource "aws_api_gateway_account" "this" {
  count               = var.manage_account_cloudwatch_role ? 1 : 0
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch[0].arn
}

##############################################################################
# Consumer Lambda — drains the queue, verifies signatures, processes events
##############################################################################

data "archive_file" "consumer_src" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/consumer_src.zip"
  excludes    = ["__pycache__", "requirements.txt", "*.pyc"]
}

resource "aws_cloudwatch_log_group" "consumer" {
  name              = "/aws/lambda/${var.name_prefix}-consumer"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "consumer" {
  function_name = "${var.name_prefix}-consumer"
  description   = "Verifies inbound webhook HMAC signatures and processes the payload."
  role          = aws_iam_role.consumer_exec.arn
  runtime       = var.lambda_runtime
  handler       = "handler.handle"
  memory_size   = var.lambda_memory_mb
  timeout       = var.lambda_timeout_s

  filename         = data.archive_file.consumer_src.output_path
  source_code_hash = data.archive_file.consumer_src.output_base64sha256

  environment {
    variables = {
      LOG_LEVEL           = var.log_level
      SIGNATURE_ALGORITHM = var.signature_algorithm
      SIGNATURE_PREFIX    = var.signature_prefix
      SECRET_ARN          = local.secret_arn
    }
  }

  tracing_config {
    mode = var.enable_xray_tracing ? "Active" : "PassThrough"
  }

  depends_on = [aws_cloudwatch_log_group.consumer]
}

# SQS -> Lambda with partial batch responses so one bad record does not re-drive
# (and re-verify) the entire batch.
resource "aws_lambda_event_source_mapping" "consumer" {
  event_source_arn                   = aws_sqs_queue.ingest.arn
  function_name                      = aws_lambda_function.consumer.arn
  batch_size                         = var.batch_size
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}
