"""Exactly-once SQS processor using AWS Lambda Powertools Idempotency.

SQS guarantees *at-least-once* delivery, so the same message can be handed to the
Lambda more than once (visibility-timeout expiry, redrive, producer retry). When
the work has a side effect — charge a card, send an email, ship an order —
running it twice is a bug.

Powertools' ``@idempotent_function`` wraps the business function with a DynamoDB
persistence layer: the first call for a given idempotency key records an
INPROGRESS item, runs the function, and persists the result; subsequent calls
with the same key return the stored result without re-running the side effect.
DynamoDB TTL expires records after the configured window.

Combined with the Powertools ``BatchProcessor`` this also honours the SQS
partial-batch-response contract — only genuinely failed records are returned for
retry.
"""

from __future__ import annotations

import hashlib
import os
from typing import Any

from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.batch import (
    BatchProcessor,
    EventType,
    process_partial_response,
)
from aws_lambda_powertools.utilities.data_classes.sqs_event import SQSRecord
from aws_lambda_powertools.utilities.idempotency import (
    DynamoDBPersistenceLayer,
    IdempotencyConfig,
    idempotent_function,
)
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()
tracer = Tracer()

# Persistence layer + config are module-level so they are reused across warm
# invocations (one DynamoDB client, one config object).
_persistence = DynamoDBPersistenceLayer(table_name=os.environ["IDEMPOTENCY_TABLE"])

# The idempotency key is read from the "idempotency_key" field of the payload we
# pass in. record_handler guarantees that field is always present (see below).
_config = IdempotencyConfig(
    event_key_jmespath="idempotency_key",
    raise_on_no_idempotency_key=True,
    # Persist outputs for replay; expiry is governed by the DynamoDB TTL the
    # Terraform module configures via idempotency_ttl_seconds.
    use_local_cache=True,
)

_processor = BatchProcessor(event_type=EventType.SQS)


@idempotent_function(
    data_keyword_argument="payload",
    persistence_store=_persistence,
    config=_config,
)
def process_payload(payload: dict[str, Any]) -> dict[str, Any]:
    """Run the side-effecting business logic exactly once per idempotency key.

    Replace the body with real work (DB write, payment, downstream API call…).
    The return value is stored by Powertools and replayed verbatim on duplicate
    invocations, so keep it JSON-serialisable.

    Args:
        payload: The message body plus a guaranteed ``idempotency_key`` field.

    Returns:
        A small JSON-serialisable result describing the outcome.
    """
    logger.info("processing message", extra={"idempotency_key": payload["idempotency_key"]})
    # ---- side-effecting business logic goes here ----
    return {"status": "processed", "idempotency_key": payload["idempotency_key"]}


def _idempotency_key(record: SQSRecord, body: dict[str, Any]) -> str:
    """Choose a stable idempotency key for a record.

    Prefers an explicit business key in the message body (``idempotency_key`` or
    ``id``); otherwise derives a deterministic key from a SHA-256 of the raw body
    so identical payloads collapse to one execution.
    """
    for field in ("idempotency_key", "id"):
        value = body.get(field)
        if value:
            return str(value)
    return hashlib.sha256((record.body or "").encode("utf-8")).hexdigest()


@tracer.capture_method
def record_handler(record: SQSRecord) -> dict[str, Any]:
    """Per-record handler invoked by the Powertools BatchProcessor."""
    body: dict[str, Any] = record.json_body if record.body else {}
    body["idempotency_key"] = _idempotency_key(record, body)
    return process_payload(payload=body)


@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handle(event: dict[str, Any], context: LambdaContext) -> dict[str, Any]:
    """Lambda entry point for the SQS event source mapping."""
    # Lets Powertools abort cleanly if the function is about to time out mid-run,
    # leaving the record retryable rather than wedged INPROGRESS.
    _config.register_lambda_context(context)

    return process_partial_response(
        event=event,
        record_handler=record_handler,
        processor=_processor,
        context=context,
    )
