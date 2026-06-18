"""Fan-out SQS worker.

Drains an SQS queue that is fed by an SNS fan-out topic. The handler uses the
Lambda partial-batch-response contract: it returns the message IDs that failed
so SQS re-delivers only those records (the rest are deleted automatically).

Replace ``process_record`` with the real per-consumer business logic. Raising
from ``process_record`` marks that single record as failed; after
``maxReceiveCount`` receives SQS redrives it to the consumer's dead-letter
queue for inspection.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any

LOGGER = logging.getLogger()
LOGGER.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

CONSUMER_NAME = os.environ.get("CONSUMER_NAME", "unknown")


class TransientError(RuntimeError):
    """Raised for retryable failures (the record returns to the queue)."""


def process_record(body: dict[str, Any], attributes: dict[str, Any]) -> None:
    """Apply business logic to a single fan-out message.

    Args:
        body: The parsed message payload (raw SNS message delivery is enabled,
            so this is the producer's original JSON, not an SNS envelope).
        attributes: SQS system attributes for the record (e.g. Approximate
            ReceiveCount), useful for backoff or poison detection.

    Raises:
        TransientError: To signal a retryable failure for this record only.
    """
    receive_count = int(attributes.get("ApproximateReceiveCount", "1"))
    LOGGER.info(
        "consumer=%s processing event_type=%s receive_count=%d",
        CONSUMER_NAME,
        body.get("event_type", "n/a"),
        receive_count,
    )
    # ---- business logic goes here ----
    # e.g. write to a data store, call a downstream API, transform and forward.


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    """Lambda entry point for the SQS event source mapping.

    Returns a ``batchItemFailures`` list per the partial-batch-response contract
    so only failed records are retried.
    """
    failures: list[dict[str, str]] = []

    for record in event.get("Records", []):
        message_id = record["messageId"]
        try:
            body = json.loads(record["body"])
        except (json.JSONDecodeError, KeyError):
            # Unparseable body is non-retryable: log and let it drain so it
            # eventually lands in the DLQ rather than looping forever.
            LOGGER.exception("consumer=%s unparseable record %s", CONSUMER_NAME, message_id)
            continue

        try:
            process_record(body, record.get("attributes", {}))
        except Exception:  # noqa: BLE001 - report failure, do not crash the batch
            LOGGER.exception("consumer=%s failed record %s", CONSUMER_NAME, message_id)
            failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": failures}
