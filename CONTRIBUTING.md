# Contributing

Thanks for your interest in improving this collection of AWS serverless patterns.

## Ground rules

- Each pattern is a **self-contained Terraform root module** under `patterns/<name>/`.
  A change to one pattern should not require touching another.
- Code must be deployable as-is. No `TODO` stubs, no placeholder resources that
  would fail `terraform validate`.
- Never commit real account data. Use the documented placeholders
  (`123456789012` for account ids, `<your-bucket-name>` for buckets, and so on).

## What good looks like

- **Terraform** — typed variables with `description` and `validation` blocks,
  `default_tags`, explicit `depends_on` only where ordering is not inferable,
  and least-privilege IAM scoped with `aws_caller_identity` / `aws_partition`
  data sources.
- **Python (Lambda)** — type hints, docstrings, structured `logging` (never
  `print`), explicit error types, and no bare `except`.
- **Step Functions** — every `Task` state defines `Retry` for transient errors
  and `Catch` for terminal handling; no unguarded happy-path-only flows.

## Workflow

1. Branch from `main`.
2. Run `terraform fmt -recursive` and `terraform validate` for any pattern you change.
3. Run the Python unit tests for any handler you change.
4. Open a pull request describing the behavior change and how you verified it.

## Questions

Open a Discussion in the repository or comment on the relevant pull request.
