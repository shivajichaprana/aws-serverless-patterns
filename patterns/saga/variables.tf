variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module. Keep it short; it is combined with per-resource suffixes."
  type        = string
  default     = "saga"

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

variable "lambda_runtime" {
  description = "Python runtime for the saga Lambda functions."
  type        = string
  default     = "python3.12"

  validation {
    condition     = contains(["python3.11", "python3.12"], var.lambda_runtime)
    error_message = "lambda_runtime must be one of: python3.11, python3.12."
  }
}

variable "lambda_memory_mb" {
  description = "Memory (MB) allocated to each saga Lambda function."
  type        = number
  default     = 256

  validation {
    condition     = var.lambda_memory_mb >= 128 && var.lambda_memory_mb <= 3008
    error_message = "lambda_memory_mb must be between 128 and 3008."
  }
}

variable "lambda_timeout_s" {
  description = "Timeout (seconds) for each saga Lambda function. Keep it below the matching Task TimeoutSeconds in the state machine."
  type        = number
  default     = 15

  validation {
    condition     = var.lambda_timeout_s >= 3 && var.lambda_timeout_s <= 120
    error_message = "lambda_timeout_s must be between 3 and 120."
  }
}

variable "log_level" {
  description = "Log level passed to the Lambda handlers via the LOG_LEVEL environment variable."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of: DEBUG, INFO, WARNING, ERROR."
  }
}

variable "log_retention_days" {
  description = "Retention in days for the Lambda and Step Functions CloudWatch log groups."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value accepted by CloudWatch Logs (e.g., 1, 7, 14, 30, 90, 365)."
  }
}

variable "saga_state_ttl_days" {
  description = "Number of days after which completed saga records expire from DynamoDB via TTL. Set to 0 to disable expiry."
  type        = number
  default     = 90

  validation {
    condition     = var.saga_state_ttl_days >= 0 && var.saga_state_ttl_days <= 3650
    error_message = "saga_state_ttl_days must be between 0 and 3650."
  }
}

variable "enable_xray_tracing" {
  description = "Enable AWS X-Ray active tracing on the state machine and Lambda functions."
  type        = bool
  default     = true
}
