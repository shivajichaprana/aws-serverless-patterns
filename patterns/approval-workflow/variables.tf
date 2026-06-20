variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module. Keep it short; it is combined with per-resource suffixes."
  type        = string
  default     = "approval"

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

variable "from_address" {
  description = "Verified SES sender address used as the From on approval emails. Must be a verified SES identity (or in a verified domain) before emails can be sent."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.from_address))
    error_message = "from_address must be a valid email address."
  }
}

variable "approver_addresses" {
  description = "One or more recipient addresses that receive the approval email. While SES is in the sandbox these must also be verified identities (see verify_approver_identities)."
  type        = list(string)

  validation {
    condition     = length(var.approver_addresses) > 0
    error_message = "Provide at least one approver address."
  }

  validation {
    condition     = alltrue([for a in var.approver_addresses : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", a))])
    error_message = "Every approver address must be a valid email address."
  }
}

variable "verify_approver_identities" {
  description = "Create SES email identities for each approver address. Required while the account is in the SES sandbox (recipients must be verified); set false once SES production access is granted."
  type        = bool
  default     = true
}

variable "email_subject_prefix" {
  description = "Prefix prepended to the approval email subject line."
  type        = string
  default     = "[Approval Required]"
}

variable "api_stage_name" {
  description = "Stage name for the HTTP API that serves the approve/reject callback links. Part of the public invoke URL embedded in the email."
  type        = string
  default     = "live"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,32}$", var.api_stage_name))
    error_message = "api_stage_name must be 1-32 chars of letters, digits, hyphens, or underscores."
  }
}

variable "api_throttle_rate_limit" {
  description = "Steady-state request-per-second throttle applied to the approval callback API."
  type        = number
  default     = 20

  validation {
    condition     = var.api_throttle_rate_limit >= 1 && var.api_throttle_rate_limit <= 10000
    error_message = "api_throttle_rate_limit must be between 1 and 10000."
  }
}

variable "api_throttle_burst_limit" {
  description = "Burst request throttle applied to the approval callback API."
  type        = number
  default     = 40

  validation {
    condition     = var.api_throttle_burst_limit >= 1 && var.api_throttle_burst_limit <= 10000
    error_message = "api_throttle_burst_limit must be between 1 and 10000."
  }
}

variable "lambda_runtime" {
  description = "Python runtime for the approval-workflow Lambda functions."
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
  description = "Timeout (seconds) for each Lambda function."
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
  description = "Retention in days for the Lambda, API, and Step Functions CloudWatch log groups."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value accepted by CloudWatch Logs (e.g., 1, 7, 14, 30, 90, 365)."
  }
}

variable "approval_ttl_days" {
  description = "Number of days after which decided approval records expire from DynamoDB via TTL. Set to 0 to disable expiry."
  type        = number
  default     = 90

  validation {
    condition     = var.approval_ttl_days >= 0 && var.approval_ttl_days <= 3650
    error_message = "approval_ttl_days must be between 0 and 3650."
  }
}

variable "enable_xray_tracing" {
  description = "Enable AWS X-Ray active tracing on the state machine and Lambda functions."
  type        = bool
  default     = true
}
