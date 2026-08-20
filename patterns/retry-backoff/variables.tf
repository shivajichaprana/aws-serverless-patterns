variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module. Keep it short; it is combined with per-resource suffixes."
  type        = string
  default     = "retry-backoff"

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

variable "backoff_base_seconds" {
  description = <<-EOT
    Base interval (seconds) for the exponential backoff. The Nth redelivery is
    delayed by a random value in [0, min(backoff_max_seconds, base * 2^(N-1))]
    (full jitter). Keep it small relative to backoff_max_seconds so early retries
    are quick and later ones spread out.
  EOT
  type        = number
  default     = 5

  validation {
    condition     = var.backoff_base_seconds >= 1 && var.backoff_base_seconds <= 900
    error_message = "backoff_base_seconds must be between 1 and 900."
  }
}

variable "backoff_max_seconds" {
  description = "Upper bound (seconds) on a single backoff delay. Capped at the SQS maximum visibility timeout of 43200 (12h)."
  type        = number
  default     = 900

  validation {
    condition     = var.backoff_max_seconds >= 1 && var.backoff_max_seconds <= 43200
    error_message = "backoff_max_seconds must be between 1 and 43200 (the SQS visibility-timeout maximum)."
  }
}

variable "max_receive_count" {
  description = "Number of times a message may be received (i.e. retried) before SQS redrives it to the dead-letter queue."
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 1 && var.max_receive_count <= 1000
    error_message = "max_receive_count must be between 1 and 1000."
  }
}

variable "message_retention_seconds" {
  description = "How long (seconds) a message is retained in the main work queue before SQS drops it."
  type        = number
  default     = 345600

  validation {
    condition     = var.message_retention_seconds >= 60 && var.message_retention_seconds <= 1209600
    error_message = "message_retention_seconds must be between 60 and 1209600 (14 days)."
  }
}

variable "lambda_runtime" {
  description = "Python runtime for the processor Lambda."
  type        = string
  default     = "python3.12"

  validation {
    condition     = contains(["python3.11", "python3.12"], var.lambda_runtime)
    error_message = "lambda_runtime must be one of: python3.11, python3.12."
  }
}

variable "lambda_memory_mb" {
  description = "Memory (MB) allocated to the processor Lambda."
  type        = number
  default     = 256

  validation {
    condition     = var.lambda_memory_mb >= 128 && var.lambda_memory_mb <= 3008
    error_message = "lambda_memory_mb must be between 128 and 3008."
  }
}

variable "lambda_timeout_s" {
  description = "Timeout (seconds) for the processor Lambda. Should be <= 1/6 of the queue visibility timeout."
  type        = number
  default     = 30

  validation {
    condition     = var.lambda_timeout_s >= 3 && var.lambda_timeout_s <= 900
    error_message = "lambda_timeout_s must be between 3 and 900."
  }
}

variable "batch_size" {
  description = "Number of SQS records delivered to the processor Lambda per invocation."
  type        = number
  default     = 10

  validation {
    condition     = var.batch_size >= 1 && var.batch_size <= 10
    error_message = "batch_size must be between 1 and 10 (SQS standard-queue Lambda batch limit)."
  }
}

variable "log_level" {
  description = "Log level passed to the processor handler via the LOG_LEVEL environment variable."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of: DEBUG, INFO, WARNING, ERROR."
  }
}

variable "log_retention_days" {
  description = "Retention in days for the processor Lambda CloudWatch log group."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value accepted by CloudWatch Logs."
  }
}

variable "enable_xray_tracing" {
  description = "Enable AWS X-Ray active tracing on the processor Lambda."
  type        = bool
  default     = true
}
