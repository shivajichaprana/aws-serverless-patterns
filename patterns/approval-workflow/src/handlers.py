"""Lambda handlers for the human-approval workflow.

Functions invoked by Step Functions:

* ``prepare_request``     — validate and persist the request (Task).
* ``send_approval_email`` — email the approver(s) Approve/Reject links carrying
                            the task token (Task, ``.waitForTaskToken``).
* ``on_approved``         — record the approval and run the gated action (Task).
* ``on_rejected``         — record the rejection (Task).

Invoked by API Gateway:

* ``decision_handler``    — reads the request_id + task token from the approve or
                            reject link and resumes the paused execution with
                            ``SendTaskSuccess`` / ``SendTaskFailure``.

The approval workflow never busy-waits: ``RequestApproval`` is paused on the task
token until a human clicks a link (or the task times out).
"""

from __future__ import annotations

import html
import json
import logging
import os
import time
import uuid
from typing import Any
from urllib.parse import quote

import boto3

from errors import ApprovalInputError
from store import (
    STATUS_APPROVED,
    STATUS_REJECTED,
    AlreadyDecidedError,
    ApprovalStore,
)

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

Event = dict[str, Any]

# Default TTL (seconds) for decided approval records; mirrors the Terraform default.
_DEFAULT_TTL_SECONDS = 90 * 24 * 60 * 60


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

def _store() -> ApprovalStore:
    """Build an approval store bound to the configured table."""
    return ApprovalStore()


def _new_id(prefix: str) -> str:
    """Generate a short, prefixed identifier."""
    return f"{prefix}-{uuid.uuid4().hex[:12]}"


def _now_iso() -> str:
    """Current UTC time as an ISO-8601 string."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _decision_url(action: str, request_id: str, token: str) -> str:
    """Build an absolute approve/reject callback URL with URL-encoded params."""
    base = os.environ["API_BASE_URL"].rstrip("/")
    return f"{base}/{action}?request_id={quote(request_id)}&token={quote(token)}"


def _html_response(status_code: int, title: str, message: str) -> dict[str, Any]:
    """Render a minimal HTML response for the API Gateway proxy integration."""
    body = (
        "<!doctype html><html><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        f"<title>{html.escape(title)}</title></head>"
        "<body style='font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;"
        "text-align:center;color:#1f2937'>"
        f"<h1>{html.escape(title)}</h1><p>{html.escape(message)}</p>"
        "<p style='color:#6b7280'>You can close this window.</p></body></html>"
    )
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": body,
    }


# --------------------------------------------------------------------------- #
# Step Functions Tasks
# --------------------------------------------------------------------------- #

def prepare_request(event: Event, context: Any = None) -> dict[str, Any]:
    """Validate the incoming request and persist it in PENDING state."""
    spec = event or {}
    title = spec.get("title")
    if not title or not isinstance(title, str):
        raise ApprovalInputError("request is missing a non-empty 'title'")

    requester = str(spec.get("requester", "unknown"))
    request_id = spec.get("request_id") or _new_id("req")
    amount = spec.get("amount")
    if amount is not None:
        try:
            amount = float(amount)
        except (TypeError, ValueError) as exc:
            raise ApprovalInputError(f"amount must be numeric, got {amount!r}") from exc

    store = _store()
    store.create(
        request_id,
        title=title,
        amount=amount,
        requester=requester,
        context=spec.get("context") or {},
        ttl_seconds=_DEFAULT_TTL_SECONDS,
    )
    logger.info("prepared approval request %s", request_id)
    return {
        "request_id": request_id,
        "title": title,
        "amount": amount,
        "requester": requester,
    }


def send_approval_email(event: Event, context: Any = None) -> dict[str, Any]:
    """Email approver(s) Approve/Reject links carrying the task token.

    Invoked with ``.waitForTaskToken``; the return value is ignored by Step
    Functions, which keeps the execution paused until the API callback resumes it.
    """
    token = event.get("task_token")
    request = event.get("request") or {}
    request_id = request.get("request_id")
    if not request_id or not token:
        raise ApprovalInputError("send_approval_email: missing request_id or task_token")

    store = _store()
    store.attach_token(request_id, token)

    approve_url = _decision_url("approve", request_id, token)
    reject_url = _decision_url("reject", request_id, token)
    _send_email(request, approve_url, reject_url)

    logger.info("approval email sent for request %s", request_id)
    return {"request_id": request_id, "status": "NOTIFIED"}


def on_approved(event: Event, context: Any = None) -> dict[str, Any]:
    """Record the approval and run the gated action.

    ``decision_handler`` already wrote APPROVED via the conditional update; this
    is where a real workflow would perform the now-approved side effect.
    """
    request = event.get("request") or {}
    request_id = request.get("request_id")
    decision = event.get("decision") or {}
    logger.info("request %s approved by %s", request_id, decision.get("approved_by"))
    return {
        "request_id": request_id,
        "outcome": STATUS_APPROVED,
        "approved_by": decision.get("approved_by"),
        "decided_at": decision.get("decided_at"),
    }


def on_rejected(event: Event, context: Any = None) -> dict[str, Any]:
    """Record the rejection."""
    request = event.get("request") or {}
    request_id = request.get("request_id")
    decision = event.get("decision") or {}
    cause = decision.get("Cause")
    detail: dict[str, Any] = {}
    if isinstance(cause, str):
        try:
            detail = json.loads(cause)
        except json.JSONDecodeError:
            detail = {"comment": cause}
    logger.info("request %s rejected by %s", request_id, detail.get("rejected_by"))
    return {
        "request_id": request_id,
        "outcome": STATUS_REJECTED,
        "rejected_by": detail.get("rejected_by"),
        "comment": detail.get("comment"),
    }


# --------------------------------------------------------------------------- #
# API Gateway target
# --------------------------------------------------------------------------- #

def decision_handler(event: Event, context: Any = None) -> dict[str, Any]:
    """Resume the paused execution from an Approve/Reject link click.

    Reads ``request_id`` and ``token`` from the query string, infers the action
    from the route path, and calls ``SendTaskSuccess`` (approve) or
    ``SendTaskFailure`` with error ``ApprovalRejected`` (reject).
    """
    params = event.get("queryStringParameters") or {}
    raw_path = event.get("rawPath") or ""
    if raw_path.endswith("/approve"):
        action = "approve"
    elif raw_path.endswith("/reject"):
        action = "reject"
    else:
        action = (params.get("action") or "").lower()

    request_id = params.get("request_id")
    token = params.get("token")
    approver = params.get("approver") or "unknown"
    comment = params.get("comment") or ""

    if action not in ("approve", "reject") or not request_id or not token:
        return _html_response(400, "Invalid link", "This approval link is malformed.")

    store = _store()
    record = store.get(request_id)
    if record is None:
        return _html_response(404, "Not found", "No matching approval request was found.")
    if record.get("status") in (STATUS_APPROVED, STATUS_REJECTED):
        return _html_response(
            409, "Already decided",
            f"This request was already {record['status'].lower()}.",
        )

    decided_at = _now_iso()
    sfn = boto3.client("stepfunctions")
    try:
        if action == "approve":
            sfn.send_task_success(
                taskToken=token,
                output=json.dumps({"approved_by": approver, "decided_at": decided_at, "comment": comment}),
            )
            store.record_decision(request_id, STATUS_APPROVED, approver, comment)
            return _html_response(200, "Approved", "Thank you — the request has been approved.")

        sfn.send_task_failure(
            taskToken=token,
            error="ApprovalRejected",
            cause=json.dumps({"rejected_by": approver, "decided_at": decided_at, "comment": comment})[:32000],
        )
        store.record_decision(request_id, STATUS_REJECTED, approver, comment)
        return _html_response(200, "Rejected", "The request has been rejected.")

    except AlreadyDecidedError:
        return _html_response(409, "Already decided", "This request was already decided.")
    except sfn.exceptions.TaskTimedOut:
        return _html_response(410, "Link expired", "This approval link has expired.")
    except sfn.exceptions.TaskDoesNotExist:
        return _html_response(410, "Link expired", "This approval request is no longer awaiting a decision.")


# --------------------------------------------------------------------------- #
# SES email rendering
# --------------------------------------------------------------------------- #

def _send_email(request: dict[str, Any], approve_url: str, reject_url: str) -> None:
    """Send the approval email to the configured approver(s) via SES."""
    from_address = os.environ["FROM_ADDRESS"]
    recipients = [a.strip() for a in os.environ.get("APPROVER_ADDRESSES", "").split(",") if a.strip()]
    if not recipients:
        raise ApprovalInputError("no approver addresses configured (APPROVER_ADDRESSES is empty)")

    subject_prefix = os.environ.get("EMAIL_SUBJECT_PREFIX", "[Approval Required]")
    title = request.get("title", "approval request")
    requester = request.get("requester", "unknown")
    amount = request.get("amount")
    amount_line = f"Amount: {amount}\n" if amount is not None else ""

    subject = f"{subject_prefix} {title}"
    text_body = (
        f"An approval is requested.\n\n"
        f"Title: {title}\n"
        f"Requested by: {requester}\n"
        f"{amount_line}\n"
        f"Approve: {approve_url}\n"
        f"Reject:  {reject_url}\n"
    )
    html_body = (
        "<html><body style='font-family:system-ui,sans-serif;color:#1f2937'>"
        f"<h2>{html.escape(subject_prefix)} {html.escape(str(title))}</h2>"
        f"<p>Requested by <strong>{html.escape(str(requester))}</strong>.</p>"
        + (f"<p>Amount: <strong>{html.escape(str(amount))}</strong></p>" if amount is not None else "")
        + "<p style='margin-top:1.5rem'>"
        f"<a href='{html.escape(approve_url)}' style='background:#16a34a;color:#fff;"
        "padding:.6rem 1.2rem;border-radius:.4rem;text-decoration:none;margin-right:.75rem'>Approve</a>"
        f"<a href='{html.escape(reject_url)}' style='background:#dc2626;color:#fff;"
        "padding:.6rem 1.2rem;border-radius:.4rem;text-decoration:none'>Reject</a>"
        "</p></body></html>"
    )

    ses = boto3.client("ses")
    ses.send_email(
        Source=from_address,
        Destination={"ToAddresses": recipients},
        Message={
            "Subject": {"Data": subject, "Charset": "UTF-8"},
            "Body": {
                "Text": {"Data": text_body, "Charset": "UTF-8"},
                "Html": {"Data": html_body, "Charset": "UTF-8"},
            },
        },
    )
