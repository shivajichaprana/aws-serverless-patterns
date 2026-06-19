output "invoke_url" {
  description = "Base invoke URL of the webhook stage. POST payloads to {invoke_url}/webhooks/{source}."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "webhook_path_template" {
  description = "Full path template providers should POST to."
  value       = "${aws_api_gateway_stage.this.invoke_url}/webhooks/{source}"
}

output "ingest_queue_url" {
  description = "URL of the SQS ingest buffer queue."
  value       = aws_sqs_queue.ingest.url
}

output "ingest_queue_arn" {
  description = "ARN of the SQS ingest buffer queue."
  value       = aws_sqs_queue.ingest.arn
}

output "dlq_url" {
  description = "URL of the dead-letter queue holding poison webhook events."
  value       = aws_sqs_queue.ingest_dlq.url
}

output "consumer_function_name" {
  description = "Name of the consumer Lambda that verifies and processes events."
  value       = aws_lambda_function.consumer.function_name
}

output "signing_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the webhook signing key (created or supplied)."
  value       = local.secret_arn
}
