variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module."
  type        = string
  default     = "schedbatch"

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

variable "schedule_expression" {
  description = "EventBridge Scheduler schedule. Accepts rate(), cron(), or at() expressions, e.g. \"rate(1 hour)\" or \"cron(0 2 * * ? *)\"."
  type        = string
  default     = "rate(1 hour)"

  validation {
    condition     = can(regex("^(rate\\(|cron\\(|at\\().+\\)$", var.schedule_expression))
    error_message = "schedule_expression must be a rate(), cron(), or at() expression."
  }
}

variable "schedule_timezone" {
  description = "IANA timezone the schedule is evaluated in (e.g. \"UTC\", \"Asia/Kolkata\")."
  type        = string
  default     = "UTC"
}

variable "flexible_time_window_minutes" {
  description = "Maximum minutes EventBridge Scheduler may delay an invocation to spread load. Set 0 for an exact (OFF) window."
  type        = number
  default     = 5

  validation {
    condition     = var.flexible_time_window_minutes >= 0 && var.flexible_time_window_minutes <= 1440
    error_message = "flexible_time_window_minutes must be between 0 and 1440."
  }
}

variable "batch_shards" {
  description = "Number of parallel shards the Map state fans the batch into. Higher = more concurrency per run."
  type        = number
  default     = 4

  validation {
    condition     = var.batch_shards >= 1 && var.batch_shards <= 40
    error_message = "batch_shards must be between 1 and 40 (Step Functions inline Map concurrency)."
  }
}

variable "max_concurrency" {
  description = "MaxConcurrency for the Map state — caps simultaneous shard processors to protect downstream systems."
  type        = number
  default     = 4

  validation {
    condition     = var.max_concurrency >= 1 && var.max_concurrency <= 40
    error_message = "max_concurrency must be between 1 and 40."
  }
}

variable "lambda_runtime" {
  description = "Python runtime for the batch Lambda functions."
  type        = string
  default     = "python3.12"

  validation {
    condition     = contains(["python3.11", "python3.12"], var.lambda_runtime)
    error_message = "lambda_runtime must be one of: python3.11, python3.12."
  }
}

variable "lambda_memory_mb" {
  description = "Memory (MB) allocated to each batch Lambda."
  type        = number
  default     = 512

  validation {
    condition     = var.lambda_memory_mb >= 128 && var.lambda_memory_mb <= 10240
    error_message = "lambda_memory_mb must be between 128 and 10240."
  }
}

variable "lambda_timeout_s" {
  description = "Timeout (seconds) for each batch Lambda."
  type        = number
  default     = 60

  validation {
    condition     = var.lambda_timeout_s >= 3 && var.lambda_timeout_s <= 900
    error_message = "lambda_timeout_s must be between 3 and 900."
  }
}

variable "log_level" {
  description = "Log level passed to the Lambda handlers via LOG_LEVEL."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of: DEBUG, INFO, WARNING, ERROR."
  }
}

variable "log_retention_days" {
  description = "Retention in days for the Lambda and Step Functions log groups."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value accepted by CloudWatch Logs."
  }
}

variable "enable_xray_tracing" {
  description = "Enable AWS X-Ray active tracing on the state machine and Lambda functions."
  type        = bool
  default     = true
}
