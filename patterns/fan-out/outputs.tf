output "topic_arn" {
  description = "ARN of the SNS fan-out topic that producers publish to."
  value       = aws_sns_topic.fanout.arn
}

output "topic_name" {
  description = "Name of the SNS fan-out topic."
  value       = aws_sns_topic.fanout.name
}

output "consumer_queue_urls" {
  description = "Map of consumer key to its main SQS queue URL."
  value       = { for k, q in aws_sqs_queue.consumer : k => q.url }
}

output "consumer_queue_arns" {
  description = "Map of consumer key to its main SQS queue ARN."
  value       = { for k, q in aws_sqs_queue.consumer : k => q.arn }
}

output "consumer_dlq_urls" {
  description = "Map of consumer key to its dead-letter queue URL."
  value       = { for k, q in aws_sqs_queue.consumer_dlq : k => q.url }
}

output "worker_function_names" {
  description = "Map of consumer key to its worker Lambda function name."
  value       = { for k, fn in aws_lambda_function.worker : k => fn.function_name }
}

output "worker_exec_role_arn" {
  description = "ARN of the shared worker Lambda execution role."
  value       = aws_iam_role.worker_exec.arn
}
