##############################################################################
# HTTP API — serves the Approve/Reject callback links embedded in the email
#
# Two GET routes (/approve and /reject) target a single Lambda (decision_handler)
# via AWS_PROXY. The Lambda reads the request_id + task token from the query
# string and resumes the paused Step Functions execution.
#
# Security note: GET links can be triggered by email link-prefetchers/scanners.
# This is mitigated by (a) single-use task tokens — Step Functions rejects a
# second SendTask* for the same token — and (b) a DynamoDB status guard that
# refuses a second decision. For stricter setups, front these links with a
# confirmation page that POSTs the decision.
##############################################################################

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-approval-api"
  protocol_type = "HTTP"
  description   = "Approve/Reject callback endpoints for the approval workflow."

  tags = local.tags
}

resource "aws_apigatewayv2_integration" "decision" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.approval["decision_handler"].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "approve" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /approve"
  target    = "integrations/${aws_apigatewayv2_integration.decision.id}"
}

resource "aws_apigatewayv2_route" "reject" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /reject"
  target    = "integrations/${aws_apigatewayv2_integration.decision.id}"
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${var.name_prefix}-approval-api"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = var.api_stage_name
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.api_throttle_rate_limit
    throttling_burst_limit = var.api_throttle_burst_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      integrationErr = "$context.integrationErrorMessage"
    })
  }

  tags = local.tags
}

# Allow API Gateway to invoke the decision handler.
resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.approval["decision_handler"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
