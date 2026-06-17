# aws-serverless-patterns

Reusable, production-minded **AWS Step Functions + Lambda** patterns packaged as
self-contained Terraform modules. Each pattern lives under `patterns/` and can be
deployed on its own or composed into a larger event-driven system.

The aim is to provide battle-tested starting points for the orchestration problems
that recur in serverless architectures — distributed transactions, fan-out
processing, scheduled batch jobs, webhook ingestion, idempotency, human approval,
and resilient retries — rather than re-deriving them on every project.

## Pattern catalog

| Pattern | Directory | Core services | What it solves |
|---|---|---|---|
| Saga (compensating transactions) | `patterns/saga/` | Step Functions, Lambda, DynamoDB | A distributed transaction across services with automatic, ordered rollback |
| Fan-out / fan-in | `patterns/fan-out/` | SNS, SQS, Lambda | Parallel processing with per-consumer dead-letter queues |
| Scheduled batch | `patterns/scheduled-batch/` | EventBridge Scheduler, Step Functions, Lambda | Time-driven batch pipelines with bounded concurrency |
| Webhook ingest | `patterns/webhook-ingest/` | API Gateway, SQS, Lambda | Durable, signature-verified intake of third-party webhooks |
| Idempotent processor | `patterns/idempotent-processor/` | Lambda Powertools, DynamoDB | Exactly-once side effects under at-least-once delivery |
| Long-running workflow | `patterns/long-running/` | Step Functions (wait states) | Workflows that span minutes to days without holding compute |
| Approval workflow | `patterns/approval-workflow/` | Step Functions (task tokens), SES | Human-in-the-loop approval gates |
| Retry with backoff | `patterns/retry-backoff/` | Step Functions, Lambda | Tunable retry/backoff and basic circuit-breaking |

> **Status.** The saga pattern is the first to land and is fully deployable. The
> remaining patterns are scaffolded and are filled in incrementally; check each
> directory's `README.md` for its current state.

## Repository layout

```
aws-serverless-patterns/
├── patterns/
│   ├── saga/                  # distributed transaction + compensations
│   ├── fan-out/               # SNS -> SQS -> Lambda fan-out
│   ├── scheduled-batch/       # EventBridge -> Step Functions batch
│   ├── webhook-ingest/        # API Gateway -> SQS -> Lambda
│   ├── idempotent-processor/  # exactly-once side effects
│   ├── long-running/          # wait-state workflows
│   ├── approval-workflow/     # task-token human approval
│   └── retry-backoff/         # retry / backoff / circuit-breaking
├── docs/                      # cross-pattern notes and selection guide
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform) >= 1.6
- AWS provider >= 5.40
- Python 3.12 (runtime for the Lambda handlers)
- An AWS account and credentials with permission to manage the services listed
  for the pattern you intend to deploy

## Using a pattern

Each pattern is a standalone Terraform root module. To deploy one:

```bash
cd patterns/saga
terraform init
terraform plan  -var 'name_prefix=demo'
terraform apply -var 'name_prefix=demo'
```

Documentation uses the reserved placeholder account id `123456789012`; replace any
example inputs with the values for your own account (`<your-aws-account>`).

## Design principles

- **Least privilege.** IAM policies are scoped to specific ARNs derived from
  `aws_caller_identity`, `aws_partition`, and `aws_region` data sources — never `*`
  on resources where a concrete ARN is knowable.
- **Failure is a first-class path.** Every Step Functions `Task` defines `Retry`
  for transient faults and `Catch` for terminal handling; sagas always unwind
  completed work in reverse order.
- **Observable by default.** State machines log to CloudWatch Logs, and Lambda
  handlers emit structured logs suitable for querying.
- **No secrets in code.** Configuration comes from variables and environment;
  nothing sensitive is committed.

## License

Released under the MIT License — see [LICENSE](LICENSE).

## Security

Please report security issues privately via a
[GitHub Security Advisory](https://github.com/shivajichaprana/aws-serverless-patterns/security/advisories/new)
rather than opening a public issue.
