output "work_queue_url" {
  description = "URL of the SQS work queue that feeds the idempotent processor."
  value       = aws_sqs_queue.work.url
}

output "work_queue_arn" {
  description = "ARN of the SQS work queue."
  value       = aws_sqs_queue.work.arn
}

output "dlq_url" {
  description = "URL of the dead-letter queue for poison messages."
  value       = aws_sqs_queue.work_dlq.url
}

output "idempotency_table_name" {
  description = "Name of the DynamoDB table backing Powertools idempotency."
  value       = aws_dynamodb_table.idempotency.name
}

output "idempotency_table_arn" {
  description = "ARN of the DynamoDB idempotency table."
  value       = aws_dynamodb_table.idempotency.arn
}

output "processor_function_name" {
  description = "Name of the idempotent processor Lambda."
  value       = aws_lambda_function.processor.function_name
}

output "powertools_layer_arn" {
  description = "ARN of the AWS Lambda Powertools layer attached to the processor."
  value       = local.powertools_layer_arn
}
