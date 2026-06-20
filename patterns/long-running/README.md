# Long-running workflow pattern (Step Functions wait states + task tokens)

Orchestrate an asynchronous job that runs for minutes, hours, or days without
holding any compute, then gate completion on a human (or external system)
sign-off using a Step Functions **task token**.

## Architecture

```
        ┌──────────────────────────── Step Functions (STANDARD) ───────────────────────────┐
        │                                                                                   │
 start ─▶ SubmitJob ─▶ WaitForJob ─▶ PollJob ─▶ EvaluateJob ──(running)── back to WaitForJob │
        │   (Task)      (Wait,        (Task)      (Choice)                                    │
        │               SecondsPath)                 │                                        │
        │                                  (succeeded)│                                       │
        │                                             ▼                                        │
        │                                       RequestSignoff ─(SendTaskSuccess)─▶ Finalize ──▶ end
        │                                    (.waitForTaskToken)                               │
        └───────────────────────────────────────────────────────────────────────────────────┘
            SubmitJob / PollJob / RequestSignoff / Finalize = Lambda • job state = DynamoDB
```

1. **`SubmitJob`** starts the asynchronous job and writes its initial state to
   DynamoDB.
2. **`WaitForJob`** is a `Wait` state driven by `SecondsPath`. The poller returns
   an exponential-backoff interval (base → cap), so the execution idles between
   checks **without consuming Lambda time** — this is what lets a Standard
   workflow span up to a year.
3. **`PollJob`** checks status, advances progress, and recomputes the next wait.
4. **`EvaluateJob`** (`Choice`) routes on the polled status: `SUCCEEDED` → the
   sign-off gate, `FAILED` → `Fail`, poll budget exhausted → `Fail`, otherwise
   loop back to `WaitForJob`.
5. **`RequestSignoff`** uses `arn:aws:states:::lambda:invoke.waitForTaskToken`.
   The Lambda records the task token (a real build would also notify an operator
   with a resume link) and the execution **pauses indefinitely** until
   `SendTaskSuccess` / `SendTaskFailure` is called with that token.
6. **`Finalize`** marks the job `COMPLETED`.

### Why wait-and-poll instead of a single long Lambda?

A Lambda caps at 15 minutes and bills for every second it runs — useless for a
job that takes hours. The Wait state costs nothing while idle, the Standard
workflow keeps a durable, inspectable history, and the task-token gate adds a
human checkpoint without busy-waiting.

## Resources created

| Resource | Purpose |
|---|---|
| `aws_sfn_state_machine.long_running` | Standard workflow: submit → (wait → poll)* → sign-off → finalize. |
| `aws_lambda_function.job[*]` | `submit_job`, `poll_job`, `request_signoff`, `finalize`. |
| `aws_dynamodb_table.jobs` | Per-job state, attempt counter, progress, and captured task token (TTL + PITR + SSE). |
| `aws_iam_role.{lambda_exec,sfn_exec}` | Least-privilege execution roles. |
| `aws_cloudwatch_log_group.*` | Lambda + state-machine execution logs. |

## Usage

```hcl
module "long_running" {
  source                     = "./patterns/long-running"
  name_prefix                = "report-builder"
  poll_interval_base_seconds = 30
  poll_interval_max_seconds  = 900
  max_poll_attempts          = 40
}
```

Start an execution (the job is simulated to succeed on the 3rd poll):

```bash
aws stepfunctions start-execution \
  --state-machine-arn "$(terraform output -raw state_machine_arn)" \
  --input '{"job_id":"report-987","succeed_after_attempts":3,"fail_job":false}'
```

Resume the paused sign-off gate once the job has been reviewed:

```bash
# Read the stored token, then approve:
TOKEN=$(aws dynamodb get-item \
  --table-name "$(terraform output -raw dynamodb_table_name)" \
  --key '{"job_id":{"S":"report-987"}}' \
  --query 'Item.task_token.S' --output text)

aws stepfunctions send-task-success \
  --task-token "$TOKEN" \
  --task-output '{"approved_by":"ops@example.invalid"}'
```

Reject instead with `send-task-failure --error JobRejected --cause "..."`.

## Execution input

| Field | Type | Default | Meaning |
|---|---|---|---|
| `job_id` | string | generated | Idempotency / lookup key for the job record. |
| `succeed_after_attempts` | number | `3` | Poll attempt on which the simulated job reports `SUCCEEDED`. |
| `fail_job` | bool | `false` | When true the first poll reports `FAILED` (exercises the failure branch). |
| `payload` | object | `{}` | Opaque job metadata persisted with the record. |

## Notes

- The job simulation lives entirely in `poll_job`; point it at a real backend
  (Batch, EMR, a third-party API) by replacing the status computation while
  keeping the same return shape.
- `RequestSignoff` has a `TimeoutSeconds` so an abandoned approval fails cleanly
  as `SignoffTimedOut` rather than pausing forever.
