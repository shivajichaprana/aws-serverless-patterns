# Saga pattern (compensating transactions)

A distributed transaction spread across several services has no global rollback.
The **saga pattern** solves this by giving every forward action a matching
*compensating* action and, on failure, undoing the completed steps in reverse
order. This module implements an **orchestration-based** saga with AWS Step
Functions: the state machine is the single coordinator that drives the forward
path and the compensation path.

The worked example is order fulfillment:

```
            forward path
  ┌────────────┐   ┌──────────────┐   ┌──────────────────┐   ┌──────────────────┐   ┌──────────────┐
  │ CreateOrder│──▶│ ChargePayment│──▶│ ReserveInventory │──▶│ ScheduleShipment │──▶│ CompleteSaga │──▶ success
  └────────────┘   └──────────────┘   └──────────────────┘   └──────────────────┘   └──────────────┘
        │ fail            │ fail              │ fail                  │ fail
        ▼                 ▼                   ▼                       ▼
   (nothing to       CancelOrder        RefundPayment          ReleaseInventory
    compensate)           ▲             then CancelOrder       then RefundPayment
        │                 │                   ▲                then CancelOrder
        ▼                 │                   │                       │
    MarkFailed ◀──────────┴───────────────────┴───────────────────────┘
        │
        ▼
    SagaFailed (Fail)
```

Each forward `Task` has a `Catch` that jumps to the correct entry point in the
compensation chain. Compensations are themselves chained in reverse
(`ReleaseInventory → RefundPayment → CancelOrder → MarkFailed`), so wherever a
failure occurs, only the work that actually completed is undone.

## Why orchestration (not choreography)

| | Orchestration (this module) | Choreography |
|---|---|---|
| Coordinator | One state machine | None — services react to events |
| Visibility | Full execution history in one place | Spread across event logs |
| Compensation ordering | Explicit and centralized | Emergent, harder to reason about |
| Best for | Workflows with clear ordering and rollback | Loosely coupled, highly autonomous services |

## Components

| Step | Lambda handler | Compensated by |
|---|---|---|
| CreateOrder | `handlers.create_order` | `cancel_order` |
| ChargePayment | `handlers.charge_payment` | `refund_payment` |
| ReserveInventory | `handlers.reserve_inventory` | `release_inventory` |
| ScheduleShipment | `handlers.schedule_shipment` | (last forward step) |
| CompleteSaga | `handlers.complete_saga` | — terminal success |
| MarkFailed | `handlers.mark_failed` | — terminal failure |

State for every execution is persisted to a DynamoDB table keyed by `order_id`,
including the overall status, a per-step status map, and a per-step attempt
counter.

## Reliability features

- **Retries with backoff.** Every forward `Task` retries `SagaTransientError` and
  Lambda service exceptions with exponential backoff before failing over to
  compensation. Compensations retry even more aggressively because they *must*
  eventually succeed.
- **Idempotent compensations.** `refund_payment` and `release_inventory` no-op if
  the corresponding forward step never recorded a result, so re-running a
  compensation is safe.
- **Compensation-failure escape hatch.** If a compensation itself exhausts its
  retries, the execution ends in `CompensationFailed` (distinct from
  `SagaRolledBack`) so an operator can be alerted for manual intervention.
- **Observability.** The state machine logs at `ALL` level to CloudWatch Logs and
  supports X-Ray active tracing.

## Inputs

| Variable | Default | Description |
|---|---|---|
| `name_prefix` | `saga` | Prefix for all resource names |
| `lambda_runtime` | `python3.12` | Python runtime for the handlers |
| `lambda_memory_mb` | `256` | Memory per function |
| `lambda_timeout_s` | `15` | Per-function timeout (keep below the Task `TimeoutSeconds`) |
| `log_level` | `INFO` | `LOG_LEVEL` passed to handlers |
| `log_retention_days` | `30` | Retention for all log groups |
| `saga_state_ttl_days` | `90` | TTL for saga records (`0` disables) |
| `enable_xray_tracing` | `true` | X-Ray active tracing |
| `tags` | `{}` | Extra tags merged into default tags |

## Outputs

`state_machine_arn`, `state_machine_name`, `dynamodb_table_name`,
`dynamodb_table_arn`, `lambda_function_names`, `lambda_exec_role_arn`,
`sfn_role_arn`.

## Deploy

```bash
cd patterns/saga
terraform init
terraform apply -var 'name_prefix=demo'
```

## Run an execution

Happy path:

```bash
aws stepfunctions start-execution \
  --state-machine-arn "arn:aws:states:us-east-1:123456789012:stateMachine:demo-saga" \
  --input '{
    "order": {
      "order_id": "ord-1001",
      "customer_id": "cust-42",
      "amount": 149.99,
      "currency": "USD",
      "items": [{"sku": "SKU-1", "qty": 2}]
    }
  }'
```

Force a failure at a step to watch compensation unwind the completed work
(`ReserveInventory` failing here triggers `RefundPayment` then `CancelOrder`):

```bash
--input '{ "order": { ... }, "fail_at": "reserve_inventory" }'
```

Exercise the retry/backoff path (make `charge_payment` fail transiently twice,
then succeed on the third attempt):

```bash
--input '{ "order": { ... }, "flaky_steps": { "charge_payment": 3 } }'
```

`fail_at` and `flaky_steps` exist purely so the control flow can be demonstrated
without wiring real payment or inventory back-ends; remove them in production and
let the handlers call your downstream services.

## Files

| File | Purpose |
|---|---|
| `statemachine.asl.json` | Step Functions definition (templated with Lambda ARNs) |
| `main.tf` | DynamoDB table, Lambda packaging, functions, log groups |
| `iam.tf` | Least-privilege Lambda and Step Functions roles |
| `step_functions.tf` | State machine + its log group |
| `variables.tf` / `outputs.tf` / `versions.tf` | Module interface and provider constraints |
| `src/handlers.py` | The nine step handlers |
| `src/store.py` | DynamoDB saga-state repository |
| `src/errors.py` | `SagaTransientError` (retried) and `SagaBusinessError` (compensated) |
