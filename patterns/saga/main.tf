##############################################################################
# Saga pattern — core resources
#
# Creates the DynamoDB saga-state table, the nine Lambda functions that make up
# the forward and compensation steps, and their log groups. IAM is in iam.tf and
# the state machine is in step_functions.tf.
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(
    {
      Project = "aws-serverless-patterns"
      Pattern = "saga"
      Module  = "patterns/saga"
    },
    var.tags,
  )

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  # Single source of truth for the saga step functions. Every entry becomes a
  # Lambda function (all sharing one deployment package and execution role) and a
  # dedicated CloudWatch log group. The state machine wires them together.
  saga_functions = {
    create_order      = { handler = "handlers.create_order", description = "Forward: create the order record (PENDING)." }
    charge_payment    = { handler = "handlers.charge_payment", description = "Forward: charge the customer's payment method." }
    reserve_inventory = { handler = "handlers.reserve_inventory", description = "Forward: reserve inventory for the order." }
    schedule_shipment = { handler = "handlers.schedule_shipment", description = "Forward: schedule the outbound shipment." }
    complete_saga     = { handler = "handlers.complete_saga", description = "Terminal: mark the saga COMPLETED on success." }
    cancel_order      = { handler = "handlers.cancel_order", description = "Compensation for create_order." }
    refund_payment    = { handler = "handlers.refund_payment", description = "Compensation for charge_payment." }
    release_inventory = { handler = "handlers.release_inventory", description = "Compensation for reserve_inventory." }
    mark_failed       = { handler = "handlers.mark_failed", description = "Terminal: mark the saga FAILED after rollback." }
  }
}

##############################################################################
# Lambda deployment package
##############################################################################

data "archive_file" "saga_src" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/saga_src.zip"
  excludes    = ["__pycache__", "requirements.txt", "*.pyc"]
}

##############################################################################
# DynamoDB — saga state store
##############################################################################

resource "aws_dynamodb_table" "saga_state" {
  name         = "${var.name_prefix}-saga-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }

  dynamic "ttl" {
    for_each = var.saga_state_ttl_days > 0 ? [1] : []
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

  lifecycle {
    prevent_destroy = false
  }
}

##############################################################################
# CloudWatch log groups — one per Lambda, created ahead of the function so the
# retention policy is enforced from the first invocation.
##############################################################################

resource "aws_cloudwatch_log_group" "saga_lambda" {
  for_each = local.saga_functions

  name              = "/aws/lambda/${var.name_prefix}-${replace(each.key, "_", "-")}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

##############################################################################
# Lambda functions — forward steps, compensations, and terminal bookkeeping
##############################################################################

resource "aws_lambda_function" "saga" {
  for_each = local.saga_functions

  function_name = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  description   = each.value.description
  role          = aws_iam_role.lambda_exec.arn
  handler       = each.value.handler
  runtime       = var.lambda_runtime
  memory_size   = var.lambda_memory_mb
  timeout       = var.lambda_timeout_s

  filename         = data.archive_file.saga_src.output_path
  source_code_hash = data.archive_file.saga_src.output_base64sha256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.saga_state.name
      LOG_LEVEL  = var.log_level
    }
  }

  tracing_config {
    mode = var.enable_xray_tracing ? "Active" : "PassThrough"
  }

  # Ensure the log group exists (with retention) before the function can write.
  depends_on = [
    aws_cloudwatch_log_group.saga_lambda,
    aws_iam_role_policy.lambda_exec,
  ]

  tags = local.tags
}
