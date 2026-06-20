output "state_machine_arn" {
  description = "ARN of the approval-workflow state machine."
  value       = aws_sfn_state_machine.approval.arn
}

output "state_machine_name" {
  description = "Name of the approval-workflow state machine."
  value       = aws_sfn_state_machine.approval.name
}

output "approval_api_endpoint" {
  description = "Base invoke URL of the approve/reject callback API (embedded in the emails)."
  value       = local.api_base_url
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB approval-request table."
  value       = aws_dynamodb_table.approvals.name
}

output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB approval-request table."
  value       = aws_dynamodb_table.approvals.arn
}

output "lambda_function_names" {
  description = "Map of function key to deployed Lambda function name."
  value       = { for k, fn in aws_lambda_function.approval : k => fn.function_name }
}

output "lambda_exec_role_arn" {
  description = "ARN of the shared Lambda execution role."
  value       = aws_iam_role.lambda_exec.arn
}

output "sfn_role_arn" {
  description = "ARN of the Step Functions execution role."
  value       = aws_iam_role.sfn_exec.arn
}
