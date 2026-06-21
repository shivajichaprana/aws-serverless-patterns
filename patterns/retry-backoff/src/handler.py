"""SQS processor with exponential backoff and full jitter.

SQS gives durability and a dead-letter queue out of the box, but every retry of a
failed message reuses the same fixed visibility timeout — there is no growing
delay between attempts. When the failure is a struggling downstream (throttling,
a cold cache, a brief outage), retrying at a constant rate just keeps the
pressure on.

This handler adds the missing piece. For each record that fails processing it:

1. reads the SQS ``ApproximateReceiveCount`` (the attempt number),
2. computes a backoff of ``base * 2^(attempt-1)``, capped at ``BACKOFF_MAX_SECONDS``,
3. applies **full jitter** — a uniform random value in ``[0, computed]`` — so a
   batch of messages that all failed at once do not retry in lockstep, and
4. extends that message's visibility timeout via ``ChangeMessageVisibility`` so
   SQS holds it for the backoff period before redelivering.

The record is then reported in ``batchItemFailures`` so the Lambda event source
mapping leaves it on the queue (successful records in the same batch are deleted).
After ``MAX_RECEIVE_COUNT`` attempts SQS redrives the message to the DLQ.

Why full jitter? AWS's "Exponential Backoff And Jitter" analysis shows that
capped exponential backoff *with* full jitter minimises both contention and
completion time versus no-jitter or equal-jitter strategies.

Replace :func:`process_record` with real per-message work. Raise
:class:`RetryableError` (or any exception) to trigger a backed-off retry; return
normally to acknowledge the message.
"""

from __future__ import annotations

import json
import logging
import os
import random
from typing import Any

import boto3

LOGGER = logging.getLogger()
LOGGER.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

# SQS hard limit on a visibility timeout (12 hours). A backoff can never exceed it.
_SQS_MAX_VISIBILITY_SECONDS = 43200

# Lazily-created SQS client so the module imports without AWS context (keeps unit
# tests cheap and avoids a client per cold start before it is needed).
_sqs_client: Any = None


class RetryableError(RuntimeError):
    """Raised by :func:`process_record` to request a backed-off retry of a record."""


def _client() -> Any:
    """Return a cached SQS client, creating it on first use."""
    global _sqs_client
    if _sqs_client is None:
        _sqs_client = boto3.client("sqs")
    return _sqs_client


def _int_env(name: str, default: int) -> int:
    """Read an integer environment variable, falling back to ``default``."""
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def compute_backoff_seconds(
    receive_count: int,
    *,
    base: int,
    cap: int,
    rng: random.Random | None = None,
) -> int:
    """Return a full-jitter exponential backoff for the given attempt.

    The deterministic ceiling for attempt ``n`` (1-based) is
    ``min(cap, base * 2^(n-1))``, itself clamped to the SQS visibility maximum.
    The returned delay is a uniform random integer in ``[0, ceiling]`` (full
    jitter), so simultaneously-failed messages spread their retries out.

    Args:
        receive_count: The SQS ``ApproximateReceiveCount`` for the message
            (1 on the first delivery).
        base: Base backoff interval in seconds.
        cap: Maximum backoff ceiling in seconds before jitter.
        rng: Optional random source (injected by tests for determinism).

    Returns:
        A non-negative integer delay in seconds, never exceeding ``cap`` or the
        SQS visibility-timeout maximum.
    """
    rng = rng or random
    attempt = max(1, receive_count)
    # Shift by attempt-1 with a guard so a large receive_count cannot overflow
    # into a huge intermediate before the min() clamps it.
    exponent = min(attempt - 1, 30)
    ceiling = min(cap, base * (2 ** exponent), _SQS_MAX_VISIBILITY_SECONDS)
    ceiling = max(0, ceiling)
    return int(rng.uniform(0, ceiling))


def process_record(body: dict[str, Any], attributes: dict[str, Any]) -> None:
    """Apply business logic to a single message.

    Replace the body with real work (downstream call, DB write, transform…).
    Raise :class:`RetryableError` — or let any exception propagate — to signal a
    retryable failure for *this record only*; the caller will back it off.

    Args:
        body: The parsed JSON message payload.
        attributes: SQS system attributes for the record (e.g.
            ``ApproximateReceiveCount``).
    """
    receive_count = int(attributes.get("ApproximateReceiveCount", "1"))
    LOGGER.info("processing message attempt=%d keys=%s", receive_count, sorted(body))
    # ---- business logic goes here ----
    # raise RetryableError("downstream unavailable") to trigger a backed-off retry.


def _backoff_record(queue_url: str, receipt_handle: str, receive_count: int) -> int:
    """Compute and apply the backoff visibility timeout for a failed record.

    Returns the delay applied (seconds). A failure to change visibility (e.g. the
    receipt handle already expired) is logged and swallowed so it never masks the
    original processing error or breaks the rest of the batch.
    """
    base = _int_env("BACKOFF_BASE_SECONDS", 5)
    cap = _int_env("BACKOFF_MAX_SECONDS", 900)
    delay = compute_backoff_seconds(receive_count, base=base, cap=cap)
    try:
        _client().change_message_visibility(
            QueueUrl=queue_url,
            ReceiptHandle=receipt_handle,
            VisibilityTimeout=delay,
        )
    except Exception:  # noqa: BLE001 - backoff is best-effort; never crash the batch
        LOGGER.exception("could not set backoff visibility (delay=%ds)", delay)
    return delay


def handle(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    """Lambda entry point for the SQS event source mapping.

    Returns a ``batchItemFailures`` list per the partial-batch-response contract
    so only failed records are retried — each with an exponential, jittered delay.
    """
    queue_url = os.environ["QUEUE_URL"]
    failures: list[dict[str, str]] = []

    for record in event.get("Records", []):
        message_id = record["messageId"]
        attributes = record.get("attributes", {})
        receive_count = int(attributes.get("ApproximateReceiveCount", "1"))

        try:
            body = json.loads(record["body"]) if record.get("body") else {}
        except (json.JSONDecodeError, KeyError):
            # An unparseable body will never become parseable: let it drain to the
            # DLQ via redrive rather than backing off forever.
            LOGGER.warning("dropping unparseable record %s (will redrive to DLQ)", message_id)
            failures.append({"itemIdentifier": message_id})
            continue

        try:
            process_record(body, attributes)
        except Exception:  # noqa: BLE001 - report failure, back it off, keep batch alive
            delay = _backoff_record(queue_url, record["receiptHandle"], receive_count)
            LOGGER.warning(
                "record %s failed on attempt %d; backing off %ds before retry",
                message_id, receive_count, delay,
            )
            failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": failures}
