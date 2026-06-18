variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module. Keep it short; it is combined with per-resource suffixes."
  type        = string
  default     = "fanout"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name_prefix))
    error_message = "name_prefix must be 2-31 chars, lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
}

variable "tags" {
  description = "Additional tags merged into the provider default_tags and applied to all resources."
  type        = map(string)
  default     = {}
}

variable "consumers" {
  description = <<-EOT
    Map of fan-out consumers. Each key becomes one SQS queue (plus a redrive DLQ)
    subscribed to the shared SNS topic, and one Lambda worker reading from that
    queue. The optional filter_policy is applied to the SNS subscription so a
    consumer can receive only the message subset it cares about (content-based
    filtering on message attributes).
  EOT
  type = map(object({
    handler       = optional(string, "worker.handle")
    batch_size    = optional(number, 10)
    filter_policy = optional(string)
  }))

  default = {
    analytics = {
      handler    = "worker.handle"
      batch_size = 10
    }
    notifications = {
      handler       = "worker.handle"
      batch_size    = 5
      filter_policy = "{\"event_type\":[\"order_created\",\"order_shipped\"]}"
    }
    audit = {
      handler    = "worker.handle"
      batch_size = 10
    }
  }

  validation {
    condition     = length(var.consumers) > 0
    error_message = "At least one consumer must be defined."
  }

  validation {
    condition     = alltrue([for k, c in var.consumers : c.batch_size >= 1 && c.batch_size <= 10])
    error_message = "Each consumer batch_size must be between 1 and 10 (SQS standard-queue Lambda batch limit)."
  }
}

variable "fifo_topic" {
  description = "Create the SNS topic and consumer queues as FIFO (ordered, exactly-once) instead of standard. FIFO trades throughput for ordering."
  type        = bool
  default     = false
}

variable "lambda_runtime" {
  description = "Python runtime for the worker Lambda functions."
  type        = string
  default     = "python3.12"

  validation {
    condition     = contains(["python3.11", "python3.12"], var.lambda_runtime)
    error_message = "lambda_runtime must be one of: python3.11, python3.12."
  }
}

variable "lambda_memory_mb" {
  description = "Memory (MB) allocated to each worker Lambda."
  type        = number
  default     = 256

  validation {
    condition     = var.lambda_memory_mb >= 128 && var.lambda_memory_mb <= 3008
    error_message = "lambda_memory_mb must be between 128 and 3008."
  }
}

variable "lambda_timeout_s" {
  description = "Timeout (seconds) for each worker Lambda. Should be <= 1/6 of the queue visibility timeout."
  type        = number
  default     = 30

  validation {
    condition     = var.lambda_timeout_s >= 3 && var.lambda_timeout_s <= 900
    error_message = "lambda_timeout_s must be between 3 and 900."
  }
}

variable "max_receive_count" {
  description = "Number of times a message may be received before SQS redrives it to the consumer's dead-letter queue."
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 1 && var.max_receive_count <= 1000
    error_message = "max_receive_count must be between 1 and 1000."
  }
}

variable "message_retention_seconds" {
  description = "How long (seconds) a message is retained in the main consumer queues."
  type        = number
  default     = 345600

  validation {
    condition     = var.message_retention_seconds >= 60 && var.message_retention_seconds <= 1209600
    error_message = "message_retention_seconds must be between 60 and 1209600 (14 days)."
  }
}

variable "log_level" {
  description = "Log level passed to the worker handlers via the LOG_LEVEL environment variable."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of: DEBUG, INFO, WARNING, ERROR."
  }
}

variable "log_retention_days" {
  description = "Retention in days for the worker Lambda CloudWatch log groups."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value accepted by CloudWatch Logs."
  }
}

variable "enable_xray_tracing" {
  description = "Enable AWS X-Ray active tracing on the worker Lambda functions."
  type        = bool
  default     = true
}
