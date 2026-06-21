output "work_queue_url" {
  description = "URL of the SQS work queue that feeds the retry-backoff processor."
  value       = aws_sqs_queue.work.url
}

output "work_queue_arn" {
  description = "ARN of the SQS work queue."
  value       = aws_sqs_queue.work.arn
}

output "dlq_url" {
  description = "URL of the dead-letter queue for messages that exhaust their retries."
  value       = aws_sqs_queue.work_dlq.url
}

output "dlq_arn" {
  description = "ARN of the dead-letter queue."
  value       = aws_sqs_queue.work_dlq.arn
}

output "processor_function_name" {
  description = "Name of the retry-backoff processor Lambda."
  value       = aws_lambda_function.processor.function_name
}

output "processor_exec_role_arn" {
  description = "ARN of the processor Lambda execution role."
  value       = aws_iam_role.processor_exec.arn
}
