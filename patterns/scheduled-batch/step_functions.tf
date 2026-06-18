##############################################################################
# Step Functions state machine + EventBridge Scheduler trigger
##############################################################################

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-batch"
  retention_in_days = var.log_retention_days
}

# Standard workflow: durable, full execution history, suited to scheduled batch
# jobs that may run for seconds to hours.
resource "aws_sfn_state_machine" "batch" {
  name     = "${var.name_prefix}-batch"
  type     = "STANDARD"
  role_arn = aws_iam_role.sfn_exec.arn

  definition = jsonencode({
    Comment = "Scheduled batch: split -> map(process) -> reduce"
    StartAt = "Split"
    States = {
      Split = {
        Type       = "Task"
        Resource   = "arn:${local.partition}:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.batch["split"].arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "shards.$" = "$.Payload.shards" }
        ResultPath     = "$.split"
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException", "Lambda.Unknown"]
          IntervalSeconds = 2
          MaxAttempts     = 4
          BackoffRate     = 2.0
        }]
        Next = "ProcessShards"
      }

      ProcessShards = {
        Type           = "Map"
        ItemsPath      = "$.split.shards"
        MaxConcurrency = var.max_concurrency
        ResultPath     = "$.results"
        Iterator = {
          StartAt = "ProcessShard"
          States = {
            ProcessShard = {
              Type       = "Task"
              Resource   = "arn:${local.partition}:states:::lambda:invoke"
              Parameters = {
                FunctionName = aws_lambda_function.batch["process"].arn
                "Payload.$"  = "$"
              }
              OutputPath = "$.Payload"
              Retry = [{
                ErrorEquals     = ["States.TaskFailed", "Lambda.ServiceException", "Lambda.TooManyRequestsException"]
                IntervalSeconds = 3
                MaxAttempts     = 3
                BackoffRate     = 2.0
              }]
              # A shard that exhausts retries is captured (not fatal) so the
              # reduce step can still summarise the partial run.
              Catch = [{
                ErrorEquals = ["States.ALL"]
                ResultPath  = "$.error"
                Next        = "ShardFailed"
              }]
              End = true
            }
            ShardFailed = {
              Type = "Pass"
              Parameters = {
                "shard_id.$" = "$.shard_id"
                status       = "FAILED"
                "error.$"    = "$.error"
              }
              End = true
            }
          }
        }
        Next = "Reduce"
      }

      Reduce = {
        Type       = "Task"
        Resource   = "arn:${local.partition}:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.batch["reduce"].arn
          "Payload.$"  = "$"
        }
        OutputPath = "$.Payload"
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException", "Lambda.Unknown"]
          IntervalSeconds = 2
          MaxAttempts     = 4
          BackoffRate     = 2.0
        }]
        End = true
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = var.enable_xray_tracing
  }

  depends_on = [aws_cloudwatch_log_group.sfn]
}

##############################################################################
# EventBridge Scheduler — fires the state machine on a cadence
##############################################################################

resource "aws_scheduler_schedule" "batch" {
  name       = "${var.name_prefix}-batch-schedule"
  group_name = "default"

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode                      = var.flexible_time_window_minutes > 0 ? "FLEXIBLE" : "OFF"
    maximum_window_in_minutes = var.flexible_time_window_minutes > 0 ? var.flexible_time_window_minutes : null
  }

  target {
    arn      = aws_sfn_state_machine.batch.arn
    role_arn = aws_iam_role.scheduler_exec.arn

    # Static input handed to the state machine on each fire; the split Lambda
    # uses run_source for traceability.
    input = jsonencode({ run_source = "eventbridge-scheduler" })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 3
    }
  }
}
