# Retry-with-backoff pattern (SQS → Lambda, exponential backoff + jitter, DLQ)

Process an SQS queue where transient failures are retried on a **growing,
jittered schedule** instead of a fixed interval, and messages that exhaust their
attempts are parked in a dead-letter queue.

## Architecture

```
producer ─▶ ┌──────────────┐   ESM (ReportBatchItemFailures)   ┌────────────────┐
            │ SQS work queue│ ────────────────────────────────▶ │ Lambda processor│
            └──────┬───────┘                                    └───────┬────────┘
                   ▲   │  on failure:                                   │
                   │   │  ChangeMessageVisibility(backoff)              │
   backed-off      │   └────────────────────────────────────────────────┘
   redelivery ─────┘
                   │  after max_receive_count receives
                   ▼
            ┌──────────────┐
            │   SQS DLQ      │  (14-day retention, inspect + replay)
            └──────────────┘
```

Plain SQS already redelivers an unacknowledged message and redrives it to a DLQ
after `max_receive_count` receives — but every retry reuses the **same** fixed
visibility timeout. This pattern keeps that durable substrate and adds the
missing exponential, jittered delay.

## How the backoff works

On each failed record the processor:

1. reads the SQS `ApproximateReceiveCount` (the attempt number),
2. computes a ceiling of `base * 2^(attempt-1)`, capped at `backoff_max_seconds`
   (and the SQS 12-hour visibility maximum),
3. picks a uniform random delay in `[0, ceiling]` — **full jitter** — so a batch
   of messages that failed together do not all retry at the same instant, and
4. calls `ChangeMessageVisibility` on that message so SQS holds it for the delay
   before redelivering it.

The record is then returned in `batchItemFailures`, so the event source mapping
leaves it on the queue while deleting the batch's successful records. After
`max_receive_count` attempts SQS redrives the message to the DLQ.

> **Why full jitter?** AWS's *Exponential Backoff And Jitter* analysis shows that
> capped exponential backoff with full jitter minimises both contention and total
> completion time compared with no-jitter or equal-jitter strategies.

## Resources created

| Resource | Purpose |
|---|---|
| `aws_sqs_queue.work` | Main work queue; redrives to the DLQ after `max_receive_count`. |
| `aws_sqs_queue.work_dlq` | Dead-letter queue (14-day retention) for exhausted messages. |
| `aws_sqs_queue_redrive_allow_policy.dlq` | Restricts DLQ redrive to the work queue. |
| `aws_lambda_function.processor` | Processor applying the backoff. |
| `aws_lambda_event_source_mapping.processor` | SQS→Lambda with `ReportBatchItemFailures`. |
| `aws_iam_role.processor_exec` | Least-privilege execution role (includes `ChangeMessageVisibility`). |

## Usage

```hcl
module "retry_backoff" {
  source      = "./patterns/retry-backoff"
  name_prefix = "payments-retry"

  backoff_base_seconds = 5    # first retry within [0,5]s, then [0,10], [0,20]...
  backoff_max_seconds  = 900  # ceiling per retry
  max_receive_count    = 5    # attempts before the DLQ
}
```

Send a message to exercise it:

```bash
aws sqs send-message \
  --queue-url "$(terraform output -raw work_queue_url)" \
  --message-body '{"order_id":"o-123"}'
```

## Customising the work

Edit `src/handler.py` → `process_record`. Raise `RetryableError` (or let any
exception propagate) to trigger a backed-off retry of that record only; return
normally to acknowledge it. The pure `compute_backoff_seconds` helper is unit
tested and can be reused or tuned independently of the I/O.

## Operating notes

- **Visibility timeout** defaults to 6× the Lambda timeout; the handler overrides
  it per message with the computed backoff on failure.
- **Tuning the curve**: raise `backoff_base_seconds` to slow early retries, or
  lower `max_receive_count` to fail fast to the DLQ.
- **Replaying the DLQ**: use SQS *Start DMR* (redrive) from the console/CLI to
  move messages back to the work queue after a fix.
- **Poison payloads**: a body that is not valid JSON is non-retryable, so it is
  sent straight toward the DLQ rather than backed off indefinitely.

## Inputs / outputs

See `variables.tf` and `outputs.tf`. Key outputs: `work_queue_url`, `dlq_url`,
`processor_function_name`.
