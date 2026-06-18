output "state_machine_arn" {
  description = "ARN of the batch Step Functions state machine."
  value       = aws_sfn_state_machine.batch.arn
}

output "state_machine_name" {
  description = "Name of the batch Step Functions state machine."
  value       = aws_sfn_state_machine.batch.name
}

output "schedule_name" {
  description = "Name of the EventBridge Scheduler schedule that triggers the batch."
  value       = aws_scheduler_schedule.batch.name
}

output "schedule_expression" {
  description = "The effective schedule expression."
  value       = aws_scheduler_schedule.batch.schedule_expression
}

output "lambda_function_names" {
  description = "Map of batch stage (split/process/reduce) to deployed Lambda function name."
  value       = { for k, fn in aws_lambda_function.batch : k => fn.function_name }
}

output "lambda_exec_role_arn" {
  description = "ARN of the shared Lambda execution role."
  value       = aws_iam_role.lambda_exec.arn
}
