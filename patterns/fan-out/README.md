# Fan-out pattern (SNS → SQS → Lambda, per-consumer DLQs)

Broadcast a single message to many independent consumers, each processing at its
own pace and isolated from the others' failures.

## Architecture

```
                              ┌────────────────┐   ┌──────────────────┐
                      ┌──────▶│ SQS: analytics  │──▶│ Lambda: analytics │
                      │       └──────┬─────────┘   └──────────────────┘
                      │              │ redrive
                      │          ┌───▼────────────┐
 producer ─▶ SNS topic├──────▶  │ SQS: notif (filtered) │──▶ Lambda: notifications
            (fan-out) │          └───┬────────────┘
                      │              │ redrive
                      │       ┌──────▼─────────┐   ┌──────────────────┐
                      └──────▶│ SQS: audit      │──▶│ Lambda: audit     │
                              └──────┬─────────┘   └──────────────────┘
                                     │ redrive (maxReceiveCount)
                                  ┌──▼───────────┐
                                  │ per-consumer  │
                                  │ dead-letter Q │
                                  └──────────────┘
```

One **SNS topic** receives every publish. Each consumer in `var.consumers` gets:

- its own **SQS queue** subscribed to the topic (raw message delivery),
- an optional **SNS filter policy** so it only receives the message subset it cares about,
- a dedicated **dead-letter queue** that captures poison messages after `max_receive_count` failed receives,
- a **Lambda worker** drained by an event source mapping using **partial batch responses**.

### Why buffer with SQS instead of subscribing Lambda directly to SNS?

The intermediate queue decouples producers from consumers. A slow or failing
consumer backs up only *its own* queue while SNS keeps accepting publishes and
the other consumers are unaffected. SQS also gives you retries, visibility
timeouts, DLQ redrive, and replay — none of which SNS→Lambda provides on its own.

## Resources created

| Resource | Purpose |
|---|---|
| `aws_sns_topic.fanout` | The broadcast topic (KMS-encrypted; FIFO optional). |
| `aws_sqs_queue.consumer[*]` | One main queue per consumer, with redrive to its DLQ. |
| `aws_sqs_queue.consumer_dlq[*]` | One DLQ per consumer (14-day retention). |
| `aws_sns_topic_subscription.consumer[*]` | SNS→SQS subscription, optional filter policy. |
| `aws_lambda_function.worker[*]` | One worker per consumer. |
| `aws_lambda_event_source_mapping.worker[*]` | SQS→Lambda with `ReportBatchItemFailures`. |
| `aws_iam_role.worker_exec` | Shared least-privilege execution role. |

## Usage

```hcl
module "fan_out" {
  source      = "./patterns/fan-out"
  name_prefix = "orders"

  consumers = {
    analytics     = { batch_size = 10 }
    notifications = { batch_size = 5, filter_policy = "{\"event_type\":[\"order_created\"]}" }
    audit         = { batch_size = 10 }
  }
}
```

Publish an event (message attributes drive filtering):

```bash
aws sns publish \
  --topic-arn "$(terraform output -raw topic_arn)" \
  --message '{"event_type":"order_created","order_id":"o-123"}' \
  --message-attributes '{"event_type":{"DataType":"String","StringValue":"order_created"}}'
```

## Operating notes

- **Visibility timeout** is set to 6× the Lambda timeout so an in-flight message
  is never re-delivered while the worker is still running.
- **Partial batch failures**: the worker returns `batchItemFailures`, so only the
  records that raised are retried — successful records in the same batch are deleted.
- **Replaying a DLQ**: use SQS *Start DMR* (redrive) from the console/CLI to move
  messages from a consumer DLQ back to its source queue after a fix.
- **FIFO**: set `fifo_topic = true` for ordered, exactly-once delivery (lower
  throughput); the topic, queues, and DLQs all become FIFO together.

## Inputs / outputs

See `variables.tf` and `outputs.tf`. Key outputs: `topic_arn`,
`consumer_queue_urls`, `consumer_dlq_urls`, `worker_function_names`.
