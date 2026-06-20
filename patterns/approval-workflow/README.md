# Approval workflow pattern (Step Functions task token + SES email)

Pause a Step Functions execution on a human-approval gate, email the approver(s)
an Approve/Reject link, and resume the workflow only when someone clicks — no
polling, no busy-waiting.

## Architecture

```
 start ─▶ PrepareRequest ─▶ RequestApproval ──(SendTaskSuccess)──▶ RecordApproval ─▶ Approved
          (Task)            (.waitForTaskToken)                     (Task)
            │                   │     ▲                                 
            │              email │     │ SendTaskSuccess / SendTaskFailure
            │                    ▼     │
            │               approver  HTTP API  ◀── GET /approve | /reject
            │                 inbox   (decision_handler Lambda)
            │
       DynamoDB request store (status guard + captured task token)

 reject  ─▶ HandleRejection ─▶ Rejected (Fail)        timeout ─▶ ApprovalTimedOut (Fail)
```

1. **`PrepareRequest`** validates the request and writes it to DynamoDB.
2. **`RequestApproval`** uses `arn:aws:states:::lambda:invoke.waitForTaskToken`.
   The `send_approval_email` Lambda stores the task token and emails the
   approver(s) via **SES** with two links: `/approve` and `/reject`, each
   carrying the `request_id` and the task token.
3. The approver clicks a link, which hits the **HTTP API**. The
   `decision_handler` Lambda calls **`SendTaskSuccess`** (approve) or
   **`SendTaskFailure`** with error `ApprovalRejected` (reject), resuming the
   paused execution.
4. Approve → **`RecordApproval`** → `Succeed`. Reject → **`HandleRejection`** →
   `Fail`. No decision before `TimeoutSeconds` → **`ApprovalTimedOut`**.

A DynamoDB conditional update guarantees only the first click wins, and the task
token is single-use, so a duplicate or prefetched click is rejected cleanly.

## Resources created

| Resource | Purpose |
|---|---|
| `aws_sfn_state_machine.approval` | Standard workflow with the task-token approval gate. |
| `aws_lambda_function.approval[*]` | `prepare_request`, `send_approval_email`, `decision_handler`, `on_approved`, `on_rejected`. |
| `aws_apigatewayv2_api.this` + routes/stage | HTTP API serving the `/approve` and `/reject` callback links. |
| `aws_dynamodb_table.approvals` | Request store with captured token + decision (TTL + PITR + SSE). |
| `aws_ses_email_identity.*` | Verified sender (and approver identities while in the SES sandbox). |
| `aws_iam_role.{lambda_exec,sfn_exec}` | Least-privilege execution roles. |
| `aws_cloudwatch_log_group.*` | Lambda, API access, and state-machine logs. |

## Prerequisites

- A **verified SES sender** (`from_address`). While the account is in the SES
  sandbox, every recipient must also be verified — keep
  `verify_approver_identities = true` and confirm the verification emails AWS
  sends to each address. Request SES production access to email unverified
  recipients.

## Usage

```hcl
module "approval" {
  source             = "./patterns/approval-workflow"
  name_prefix        = "expense-approval"
  from_address       = "approvals@example.invalid"
  approver_addresses = ["manager@example.invalid"]
}
```

Start an execution:

```bash
aws stepfunctions start-execution \
  --state-machine-arn "$(terraform output -raw state_machine_arn)" \
  --input '{"title":"Refund #4821","amount":250,"requester":"support-bot"}'
```

The approver receives an email and clicks **Approve** or **Reject**; the workflow
resumes automatically. The callback base URL is also available as
`terraform output approval_api_endpoint` for testing the links directly.

## Request input

| Field | Type | Required | Meaning |
|---|---|---|---|
| `title` | string | yes | Human-readable summary shown in the email subject/body. |
| `requester` | string | no | Who/what raised the request (defaults to `unknown`). |
| `amount` | number | no | Optional amount displayed in the email. |
| `request_id` | string | no | Idempotency / lookup key (generated when omitted). |
| `context` | object | no | Opaque metadata persisted with the record. |

## Security notes

- Approve/reject links are **GET** requests, which email scanners may prefetch.
  Replay is prevented by the single-use task token and the DynamoDB status
  guard; for stricter environments, front the links with a confirmation page
  that **POSTs** the decision.
- `ses:SendEmail` is scoped to the verified sender identity with an
  `ses:FromAddress` condition; `states:SendTask*` cannot be resource-scoped
  because authorization is by the opaque task token.
- The API is throttled (`api_throttle_rate_limit` / `api_throttle_burst_limit`)
  and access-logged.
