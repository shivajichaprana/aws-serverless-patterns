variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module. Keep it short; it is combined with per-resource suffixes."
  type        = string
  default     = "webhook-ingest"

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

variable "signature_header" {
  description = <<-EOT
    Name of the HTTP header carrying the provider's HMAC signature (e.g.
    'X-Hub-Signature-256' for GitHub, 'Stripe-Signature' for Stripe). The header
    is captured at the API Gateway integration and re-verified in the consumer
    Lambda against the shared secret. Must be lowercase here because API Gateway
    normalises header names to lowercase in mapping templates.
  EOT
  type        = string
  default     = "x-signature-256"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.signature_header))
    error_message = "signature_header must be lowercase and contain only letters, digits, and hyphens."
  }
}

variable "signature_algorithm" {
  description = "HMAC digest algorithm used to verify the signature header."
  type        = string
  default     = "sha256"

  validation {
    condition     = contains(["sha1", "sha256", "sha512"], var.signature_algorithm)
    error_message = "signature_algorithm must be one of: sha1, sha256, sha512."
  }
}

variable "signature_prefix" {
  description = "Optional prefix the provider prepends to the hex digest in the signature header (e.g. 'sha256=' for GitHub). Leave empty for a bare hex digest."
  type        = string
  default     = "sha256="
}

variable "webhook_secret_arn" {
  description = <<-EOT
    ARN of an existing Secrets Manager secret holding the webhook signing key. If
    null, the module creates a secret (populated out-of-band) and grants the
    consumer read access to it. Provide an ARN to reuse a centrally-managed key.
  EOT
  type        = string
  default     = null
}

variable "max_body_bytes" {
  description = "Maximum accepted request body size in bytes. Requests larger than this are rejected at the API before reaching SQS (SQS hard limit is 256 KB)."
  type        = number
  default     = 262144

  validation {
    condition     = var.max_body_bytes >= 1024 && var.max_body_bytes <= 262144
    error_message = "max_body_bytes must be between 1024 and 262144 (SQS 256 KB message limit)."
  }
}

variable "throttling_rate_limit" {
  description = "API Gateway stage steady-state request rate limit (requests/second)."
  type        = number
  default     = 200
}

variable "throttling_burst_limit" {
  description = "API Gateway stage burst request limit."
  type        = number
  default     = 400
}

variable "lambda_runtime" {
  description = "Python runtime for the consumer Lambda."
  type        = string
  default     = "python3.12"

  validation {
    condition     = contains(["python3.11", "python3.12"], var.lambda_runtime)
    error_message = "lambda_runtime must be one of: python3.11, python3.12."
  }
}

variable "lambda_memory_mb" {
  description = "Memory (MB) allocated to the consumer Lambda."
  type        = number
  default     = 256

  validation {
    condition     = var.lambda_memory_mb >= 128 && var.lambda_memory_mb <= 3008
    error_message = "lambda_memory_mb must be between 128 and 3008."
  }
}

variable "lambda_timeout_s" {
  description = "Timeout (seconds) for the consumer Lambda. Should be <= 1/6 of the queue visibility timeout."
  type        = number
  default     = 30

  validation {
    condition     = var.lambda_timeout_s >= 3 && var.lambda_timeout_s <= 900
    error_message = "lambda_timeout_s must be between 3 and 900."
  }
}

variable "batch_size" {
  description = "Number of SQS records delivered to the consumer Lambda per invocation."
  type        = number
  default     = 10

  validation {
    condition     = var.batch_size >= 1 && var.batch_size <= 10
    error_message = "batch_size must be between 1 and 10 (SQS standard-queue Lambda batch limit)."
  }
}

variable "max_receive_count" {
  description = "Number of times a message may be received before SQS redrives it to the dead-letter queue."
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 1 && var.max_receive_count <= 1000
    error_message = "max_receive_count must be between 1 and 1000."
  }
}

variable "message_retention_seconds" {
  description = "How long (seconds) a message is retained in the main ingest queue."
  type        = number
  default     = 345600

  validation {
    condition     = var.message_retention_seconds >= 60 && var.message_retention_seconds <= 1209600
    error_message = "message_retention_seconds must be between 60 and 1209600 (14 days)."
  }
}

variable "log_level" {
  description = "Log level passed to the consumer handler via the LOG_LEVEL environment variable."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of: DEBUG, INFO, WARNING, ERROR."
  }
}

variable "log_retention_days" {
  description = "Retention in days for the consumer Lambda and API access-log CloudWatch log groups."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value accepted by CloudWatch Logs."
  }
}

variable "enable_xray_tracing" {
  description = "Enable AWS X-Ray active tracing on the consumer Lambda and the API stage."
  type        = bool
  default     = true
}

variable "manage_account_cloudwatch_role" {
  description = "Create and set the account/region-singleton API Gateway CloudWatch Logs role. Set false if another stack already manages aws_api_gateway_account."
  type        = bool
  default     = true
}
