# Webhook ingest pattern (API Gateway → SQS → Lambda)

Accept third-party webhooks at a public HTTPS endpoint, buffer them durably, and
verify each signature before processing — without putting a Lambda on the
synchronous request path.

## Architecture

```
                           ┌──────────────────────────────────────┐
  provider ──POST /webhooks/{source}──▶  API Gateway (REST)         │
  (GitHub,                 │   • request validation                 │
   Stripe, …)              │   • throttling + access logs           │
                           │   • direct AWS integration ──────┐     │
                           └──────────────────────────────────┼─────┘
                                                              ▼
                                                   ┌────────────────────┐
                                                   │  SQS: ingest queue  │
                                                   └─────────┬──────────┘
                                                             │ redrive (maxReceiveCount)
                                                   ┌─────────▼──────────┐
                                                   │  SQS: dead-letter   │
                                                   └────────────────────┘
                                                             │ (main queue)
                                                   ┌─────────▼──────────┐      ┌───────────────────┐
                                                   │ Lambda: consumer    │◀────▶│ Secrets Manager    │
                                                   │  • HMAC verify      │      │  signing key       │
                                                   │  • process_event    │      └───────────────────┘
                                                   └────────────────────┘
```

The endpoint uses an **API Gateway → SQS direct service integration**: there is
no "ingest Lambda" in the hot path. API Gateway url-encodes the raw body into the
SQS message and forwards the signature header and the `{source}` path part as
**message attributes**. A consumer Lambda then drains the queue, re-computes the
HMAC over the raw body, compares it in constant time, and processes verified
events using the **partial-batch-response** contract.

### Why verify *after* buffering instead of at the edge?

Keeping the synchronous path to "API Gateway → SQS" only means a slow downstream
or a webhook storm can never make the provider see timeouts and retry-storm us —
SQS absorbs the burst and the provider gets a fast `202 Accepted`. The trade-off
is that a forged/invalid request is accepted and dropped *asynchronously* rather
than rejected at the edge. That is the right call for most webhooks (idempotent,
replayable, provider-retried). If you need synchronous `401` rejection, move
verification into a Lambda authorizer or a request-validating proxy integration —
at the cost of a Lambda on every request.

### Signature verification

`verify_signature.py` recomputes `HMAC(secret, raw_body)` and compares it to the
provided digest with `hmac.compare_digest` (constant-time). It supports the
common provider conventions:

| Provider style | `signature_header`     | `signature_algorithm` | `signature_prefix` |
|----------------|------------------------|-----------------------|--------------------|
| GitHub         | `x-hub-signature-256`  | `sha256`              | `sha256=`          |
| Shopify        | `x-shopify-hmac-sha256`| `sha256`              | *(empty, base64)*¹ |
| Generic HMAC   | `x-signature-256`      | `sha256`              | `sha256=`          |

¹ Base64-digest providers need a one-line tweak in `compute_signature`; the
default path handles hex digests.

## Inputs

| Variable | Default | Purpose |
|----------|---------|---------|
| `name_prefix` | `webhook-ingest` | Resource name prefix |
| `signature_header` | `x-signature-256` | Header carrying the HMAC (lowercase) |
| `signature_algorithm` | `sha256` | `sha1` / `sha256` / `sha512` |
| `signature_prefix` | `sha256=` | Prefix stripped before comparison |
| `webhook_secret_arn` | `null` | Reuse an existing secret; else one is created |
| `max_receive_count` | `5` | Receives before redrive to DLQ |
| `batch_size` | `10` | SQS records per consumer invocation |
| `enable_xray_tracing` | `true` | Active tracing on Lambda + stage |

See `variables.tf` for the full set with validation rules.

## Outputs

`invoke_url`, `webhook_path_template`, `ingest_queue_url`, `dlq_url`,
`consumer_function_name`, and `signing_secret_arn`.

## Quick start

```bash
terraform init
terraform apply

# Put the signing key the provider will use into the created secret:
aws secretsmanager put-secret-value \
  --secret-id "$(terraform output -raw signing_secret_arn)" \
  --secret-string 'super-secret-signing-key'

# Point the provider's webhook at:
terraform output -raw webhook_path_template   # .../webhooks/{source}
```

## Operations

- **Replay poison events**: inspect the DLQ, then redrive with the SQS console's
  *Start DLQ redrive* or `aws sqs start-message-move-task`.
- **Rotate the signing key**: publish a new secret version; cold starts pick it
  up (the consumer caches the key per execution environment).
- **Tune burst handling**: raise `throttling_burst_limit` and the queue's
  `visibility_timeout` is auto-sized to `lambda_timeout_s * 6`.
