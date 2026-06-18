##############################################################################
# Scheduled-batch pattern — EventBridge Scheduler -> Step Functions -> Lambda
#
# An EventBridge Scheduler rule triggers a Standard Step Functions workflow on a
# fixed cadence. The workflow:
#   1. "split"   — a Lambda partitions the work into N shards,
#   2. Map state — runs a "process" Lambda per shard, with bounded concurrency,
#                  retries, and per-shard catch so one bad shard cannot fail the run,
#   3. "reduce"  — a Lambda aggregates the per-shard results into a run summary.
#
# Step Functions (not raw Lambda) gives the batch durable state, visual run
# history, built-in retry/backoff, and a concurrency cap to protect downstreams.
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(
    {
      Project = "aws-serverless-patterns"
      Pattern = "scheduled-batch"
      Module  = "patterns/scheduled-batch"
    },
    var.tags,
  )

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  # The three batch stages. All share one deployment package and execution role;
  # each maps to a distinct handler entry point.
  batch_functions = {
    split   = { handler = "handlers.split", description = "Partition the batch into shards." }
    process = { handler = "handlers.process", description = "Process a single shard of work." }
    reduce  = { handler = "handlers.reduce", description = "Aggregate shard results into a run summary." }
  }
}

##############################################################################
# Lambda deployment package + functions
##############################################################################

data "archive_file" "batch_src" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/batch_src.zip"
  excludes    = ["__pycache__", "requirements.txt", "*.pyc"]
}

resource "aws_cloudwatch_log_group" "batch" {
  for_each = local.batch_functions

  name              = "/aws/lambda/${var.name_prefix}-${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "batch" {
  for_each = local.batch_functions

  function_name = "${var.name_prefix}-${each.key}"
  description   = each.value.description
  role          = aws_iam_role.lambda_exec.arn
  runtime       = var.lambda_runtime
  handler       = each.value.handler
  memory_size   = var.lambda_memory_mb
  timeout       = var.lambda_timeout_s

  filename         = data.archive_file.batch_src.output_path
  source_code_hash = data.archive_file.batch_src.output_base64sha256

  environment {
    variables = {
      LOG_LEVEL    = var.log_level
      BATCH_SHARDS = tostring(var.batch_shards)
    }
  }

  tracing_config {
    mode = var.enable_xray_tracing ? "Active" : "PassThrough"
  }

  depends_on = [aws_cloudwatch_log_group.batch]
}
