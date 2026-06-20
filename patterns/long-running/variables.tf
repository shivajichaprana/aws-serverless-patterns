variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module. Keep it short; it is combined with per-resource suffixes."
  type        = string
  default     = "longrun"

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
  description = "Python runtime for the long-running pattern Lambda functions."
  type        = string
  default     = "python3.12"

  validation {
    condition     = contains(["python3.11", "python3.12"], var.lambda_runtime)
    error_message = "lambda_runtime must be one of: python3.11, python3.12."
  }
}

variable "lambda_memory_mb" {
  description = "Memory (MB) allocated to each Lambda function."
  type        = number
  default     = 256

  validation {
    condition     = var.lambda_memory_mb >= 128 && var.lambda_memory_mb <= 3008
    error_message = "lambda_memory_mb must be between 128 and 3008."
  }
}

variable "lambda_timeout_s" {
  description = "Timeout (seconds) for each Lambda function. Keep it below the matching Task TimeoutSeconds in the state machine."
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

variable "job_state_ttl_days" {
  description = "Number of days after which terminal job records expire from DynamoDB via TTL. Set to 0 to disable expiry."
  type        = number
  default     = 30

  validation {
    condition     = var.job_state_ttl_days >= 0 && var.job_state_ttl_days <= 3650
    error_message = "job_state_ttl_days must be between 0 and 3650."
  }
}

variable "poll_interval_base_seconds" {
  description = "Base wait (seconds) between status polls. The poller multiplies this by an exponential backoff factor up to poll_interval_max_seconds, so the Wait state idles without consuming compute."
  type        = number
  default     = 30

  validation {
    condition     = var.poll_interval_base_seconds >= 1 && var.poll_interval_base_seconds <= 3600
    error_message = "poll_interval_base_seconds must be between 1 and 3600."
  }
}

variable "poll_interval_max_seconds" {
  description = "Upper bound (seconds) on the backed-off wait between polls. A long-running job can therefore idle for minutes to hours between checks."
  type        = number
  default     = 900

  validation {
    condition     = var.poll_interval_max_seconds >= 1 && var.poll_interval_max_seconds <= 86400
    error_message = "poll_interval_max_seconds must be between 1 and 86400 (1 day)."
  }
}

variable "max_poll_attempts" {
  description = "Maximum number of status polls before the execution gives up with a JobPollBudgetExhausted failure."
  type        = number
  default     = 20

  validation {
    condition     = var.max_poll_attempts >= 1 && var.max_poll_attempts <= 1000
    error_message = "max_poll_attempts must be between 1 and 1000."
  }
}

variable "enable_xray_tracing" {
  description = "Enable AWS X-Ray active tracing on the state machine and Lambda functions."
  type        = bool
  default     = true
}
