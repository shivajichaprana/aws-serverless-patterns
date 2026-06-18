# Scheduled-batch pattern (EventBridge Scheduler → Step Functions → Lambda)

Run a partitioned batch job on a fixed cadence with durable orchestration,
bounded concurrency, retries, and partial-failure isolation.

## Architecture

```
 EventBridge Scheduler                Step Functions (STANDARD)
  rate()/cron()/at()      ┌───────────────────────────────────────────────┐
        │   StartExecution│  Split ──▶ Map(MaxConcurrency) ──▶ Reduce        │
        └────────────────▶│           ├─ ProcessShard (retry+catch)         │
                          │           ├─ ProcessShard                       │
                          │           └─ ProcessShard ...                    │
                          └───────────────────────────────────────────────┘
                                 split / process / reduce = Lambda
```

1. **EventBridge Scheduler** fires the workflow on a `rate()`, `cron()`, or
   `at()` schedule, in a configurable timezone, with an optional flexible time
   window to spread load.
2. **`Split`** Lambda partitions the run into `batch_shards` work units.
3. **`Map`** state runs the **`process`** Lambda per shard with `MaxConcurrency`
   capping parallelism, exponential-backoff `Retry`, and a per-shard `Catch` so
   a single failing shard yields a partial run instead of failing everything.
4. **`Reduce`** Lambda aggregates the shard results into a run summary.

### Why Step Functions instead of a single scheduled Lambda?

A scheduled Lambda hits the 15-minute wall, has no built-in fan-out/concurrency
control, and gives you nothing to inspect when a run half-fails. The Standard
workflow adds durable state, a visual run history, native retry/backoff, a
concurrency cap that protects downstream systems, and graceful partial-failure
handling.

## Resources created

| Resource | Purpose |
|---|---|
| `aws_scheduler_schedule.batch` | EventBridge Scheduler trigger (rate/cron/at). |
| `aws_sfn_state_machine.batch` | Standard workflow: split → map(process) → reduce. |
| `aws_lambda_function.batch[*]` | `split`, `process`, `reduce` stage functions. |
| `aws_iam_role.{lambda_exec,sfn_exec,scheduler_exec}` | Least-privilege roles. |
| `aws_cloudwatch_log_group.*` | Lambda + state-machine execution logs. |

## Usage

```hcl
module "scheduled_batch" {
  source              = "./patterns/scheduled-batch"
  name_prefix         = "nightly-recon"
  schedule_expression = "cron(0 2 * * ? *)"   # 02:00 daily
  schedule_timezone   = "Asia/Kolkata"
  batch_shards        = 8
  max_concurrency     = 4
}
```

Trigger a run manually (outside the schedule):

```bash
aws stepfunctions start-execution \
  --state-machine-arn "$(terraform output -raw state_machine_arn)" \
  --input '{"run_source":"manual"}'
```

## Operating notes

- **Flexible time window**: `flexible_time_window_minutes > 0` lets Scheduler
  delay the start by up to that many minutes to smooth thundering-herd load; set
  `0` for an exact start.
- **Partial success**: the Map `Catch` routes a shard that exhausts its retries
  to a `ShardFailed` Pass state, so `reduce` reports `status = PARTIAL` with the
  failed shard count rather than aborting the run.
- **Concurrency**: tune `max_concurrency` to the rate your downstream can absorb;
  it caps simultaneous `process` invocations independently of `batch_shards`.
- **Confused-deputy protection**: the Scheduler role trust policy is locked to
  this account via `aws:SourceAccount`.

## Inputs / outputs

See `variables.tf` and `outputs.tf`. Key outputs: `state_machine_arn`,
`schedule_name`, `lambda_function_names`.
