output "state_machine_arn" {
  description = "ARN of the saga Step Functions state machine."
  value       = aws_sfn_state_machine.saga.arn
}

output "state_machine_name" {
  description = "Name of the saga Step Functions state machine."
  value       = aws_sfn_state_machine.saga.name
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB saga-state table."
  value       = aws_dynamodb_table.saga_state.name
}

output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB saga-state table."
  value       = aws_dynamodb_table.saga_state.arn
}

output "lambda_function_names" {
  description = "Map of saga step key to deployed Lambda function name."
  value       = { for k, fn in aws_lambda_function.saga : k => fn.function_name }
}

output "lambda_exec_role_arn" {
  description = "ARN of the shared Lambda execution role."
  value       = aws_iam_role.lambda_exec.arn
}

output "sfn_role_arn" {
  description = "ARN of the Step Functions execution role."
  value       = aws_iam_role.sfn_exec.arn
}
