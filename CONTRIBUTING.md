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
2. Format and validate any pattern you change:
   ```bash
   make fmt                    # terraform fmt -recursive
   make validate PATTERN=<name>
   ```
3. Run the handler tests for any Lambda you change:
   ```bash
   make test-deps              # first time only
   make test
   ```
4. Open a pull request describing the behaviour change and how you verified it.

## Continuous integration

Every push and pull request runs [`.github/workflows/ci.yml`](.github/workflows/ci.yml):

- a **terraform** job runs `fmt -check`, `init -backend=false`, and `validate`
  across all eight patterns via a build matrix (no AWS credentials required), and
- a **python-tests** job runs the `pytest` handler suite.

Each action is pinned to a commit SHA. Please keep CI green; if you add a pattern,
add it to the matrix in the workflow and give its handlers a test under `tests/`.

## Questions

Open a Discussion in the repository or comment on the relevant pull request.
