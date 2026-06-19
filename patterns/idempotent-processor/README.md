# Idempotent processor pattern (SQS → Lambda + Powertools Idempotency)

Process each message **exactly once**, even though SQS delivers *at-least-once*
and producers retry.

## Architecture

```
                        ┌────────────────────┐
   producer ──────────▶ │  SQS: work queue    │
   (may send the same   └─────────┬──────────┘
    message twice)                │ redrive (maxReceiveCount)
                        ┌─────────▼──────────┐
                        │  SQS: dead-letter   │
                        └────────────────────┘
                                  │ (work queue)
                        ┌─────────▼──────────────────┐      ┌───────────────────────┐
                        │ Lambda: processor           │◀────▶│ DynamoDB: idempotency  │
                        │  • BatchProcessor (partial) │      │  (id PK + TTL)         │
                        │  • @idempotent_function     │      └───────────────────────┘
                        └────────────────────────────┘
```

A standard SQS work queue feeds a Lambda. The processing function is wrapped with
**AWS Lambda Powertools** `@idempotent_function`, backed by a **DynamoDB**
persistence layer. The first invocation for a given idempotency key writes an
`INPROGRESS` item, runs the side effect, and stores the result; any duplicate
invocation with the same key returns the **stored result** without re-running the
side effect. A DynamoDB **TTL** expires records after `idempotency_ttl_seconds`.

### Why this instead of "just dedupe in SQS"?

SQS FIFO content-based dedup only covers a 5-minute window and only within one
queue. Idempotency at the *application* layer covers producer retries, redrives,
cross-queue replays, and reprocessing — anything that re-presents the same
logical work — and it returns the original result rather than silently dropping
the duplicate.

### Idempotency key selection

`record_handler` picks the key in priority order:

1. `idempotency_key` field in the message body (preferred — a true business key),
2. `id` field in the message body,
3. a SHA-256 of the raw body (so identical payloads collapse to one execution).

`raise_on_no_idempotency_key=True` is moot here because the handler always
guarantees a key; flip the logic if you want to *require* a producer-supplied key
and fail loudly otherwise.

## Inputs

| Variable | Default | Purpose |
|----------|---------|---------|
| `name_prefix` | `idempotent` | Resource name prefix |
| `idempotency_ttl_seconds` | `3600` | DynamoDB TTL on completed records |
| `powertools_layer_version` | `4` | Public Powertools layer version |
| `powertools_layer_arn_override` | `null` | Use a specific layer ARN instead |
| `batch_size` | `10` | SQS records per invocation |
| `max_receive_count` | `5` | Receives before redrive to DLQ |
| `enable_point_in_time_recovery` | `true` | PITR on the idempotency table |
| `enable_xray_tracing` | `true` | Active tracing on the Lambda |

See `variables.tf` for the full set with validation rules.

## Outputs

`work_queue_url`, `dlq_url`, `idempotency_table_name`, `processor_function_name`,
and `powertools_layer_arn`.

## Quick start

```bash
terraform init
terraform apply

# Send the same logical message twice — it is processed once:
QURL=$(terraform output -raw work_queue_url)
aws sqs send-message --queue-url "$QURL" \
  --message-body '{"idempotency_key":"order-42","amount":1999}'
aws sqs send-message --queue-url "$QURL" \
  --message-body '{"idempotency_key":"order-42","amount":1999}'
# The processor's side effect runs exactly once; the second call replays the
# stored result.
```

## Operations

- **Tune the dedupe window**: raise `idempotency_ttl_seconds` to cover the longest
  plausible retry gap; lower it to reclaim DynamoDB storage sooner.
- **Inspect duplicates**: DynamoDB items are keyed by the idempotency key with a
  `status` (`INPROGRESS` / `COMPLETED`) and `expiration` epoch.
- **Poison messages**: anything that keeps failing lands in the DLQ after
  `max_receive_count` receives.
