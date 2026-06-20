##############################################################################
# Step Functions — human-approval state machine
#
# Standard workflow so the execution can stay paused on the approval gate for as
# long as the configured task TimeoutSeconds (up to the one-year execution cap).
##############################################################################

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-approval"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_sfn_state_machine" "approval" {
  name     = "${var.name_prefix}-approval"
  role_arn = aws_iam_role.sfn_exec.arn
  type     = "STANDARD"

  definition = templatefile("${path.module}/statemachine.asl.json", {
    partition               = local.partition
    prepare_request_arn     = aws_lambda_function.approval["prepare_request"].arn
    send_approval_email_arn = aws_lambda_function.approval["send_approval_email"].arn
    on_approved_arn         = aws_lambda_function.approval["on_approved"].arn
    on_rejected_arn         = aws_lambda_function.approval["on_rejected"].arn
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
