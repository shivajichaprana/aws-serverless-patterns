##############################################################################
# Step Functions — saga state machine
##############################################################################

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-saga"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_sfn_state_machine" "saga" {
  name     = "${var.name_prefix}-saga"
  role_arn = aws_iam_role.sfn_exec.arn
  type     = "STANDARD"

  # Render the ASL template, injecting each Lambda ARN.
  definition = templatefile("${path.module}/statemachine.asl.json", {
    create_order_arn      = aws_lambda_function.saga["create_order"].arn
    charge_payment_arn    = aws_lambda_function.saga["charge_payment"].arn
    reserve_inventory_arn = aws_lambda_function.saga["reserve_inventory"].arn
    schedule_shipment_arn = aws_lambda_function.saga["schedule_shipment"].arn
    complete_saga_arn     = aws_lambda_function.saga["complete_saga"].arn
    cancel_order_arn      = aws_lambda_function.saga["cancel_order"].arn
    refund_payment_arn    = aws_lambda_function.saga["refund_payment"].arn
    release_inventory_arn = aws_lambda_function.saga["release_inventory"].arn
    mark_failed_arn       = aws_lambda_function.saga["mark_failed"].arn
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
