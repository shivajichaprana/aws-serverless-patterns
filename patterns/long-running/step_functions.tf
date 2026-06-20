##############################################################################
# Step Functions — long-running async-job state machine
#
# Standard workflow: STANDARD type supports executions up to one year, which is
# what makes the Wait + poll loop and the task-token sign-off gate viable for
# jobs that run for minutes to days.
##############################################################################

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-long-running"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_sfn_state_machine" "long_running" {
  name     = "${var.name_prefix}-long-running"
  role_arn = aws_iam_role.sfn_exec.arn
  type     = "STANDARD"

  definition = templatefile("${path.module}/statemachine.asl.json", {
    partition           = local.partition
    submit_job_arn      = aws_lambda_function.job["submit_job"].arn
    poll_job_arn        = aws_lambda_function.job["poll_job"].arn
    request_signoff_arn = aws_lambda_function.job["request_signoff"].arn
    finalize_arn        = aws_lambda_function.job["finalize"].arn
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = var.enable_xray_tracing
  }

  tags = local.tags

  depends_on = [aws_iam_role_policy.sfn_exec]
}
