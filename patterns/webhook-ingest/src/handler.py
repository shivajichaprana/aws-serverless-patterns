"""Webhook ingest consumer.

Drains the SQS ingest buffer that sits behind the API Gateway endpoint. For each
record it:

1. reads the signature and source from the SQS message attributes (set by the
   API Gateway integration template),
2. fetches the signing key from Secrets Manager (cached across invocations),
3. re-verifies the HMAC signature over the raw body, and
4. hands verified events to ``process_event`` for business logic.

It follows the Lambda partial-batch-response contract: only records that fail are
returned in ``batchItemFailures`` so SQS retries those alone. A record that fails
*signature* verification is treated as non-retryable — retrying will never make a
forged or corrupt payload valid — so it is dropped (logged) rather than redriven.
"""

from __future__ import annotations

import json
import logging
import os
from functools import lru_cache
from typing import Any

import boto3

from verify_signature import SignatureError, verify

LOGGER = logging.getLogger()
LOGGER.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

SECRET_ARN = os.environ["SECRET_ARN"]
SIGNATURE_ALGORITHM = os.environ.get("SIGNATURE_ALGORITHM", "sha256")
SIGNATURE_PREFIX = os.environ.get("SIGNATURE_PREFIX", "")

_secrets = boto3.client("secretsmanager")


class _Unverified(RuntimeError):
    """Internal marker for a record that failed signature verification."""


@lru_cache(maxsize=1)
def _signing_key() -> bytes:
    """Fetch and cache the webhook signing key from Secrets Manager.

    Cached for the lifetime of the execution environment to avoid a Secrets
    Manager call per record. Rotate by publishing a new secret version and
    letting cold starts pick it up (or shorten cache TTL if you rotate often).
    """
    resp = _secrets.get_secret_value(SecretId=SECRET_ARN)
    secret = resp.get("SecretString")
    if secret is None:
        # Binary secret — decode from the SDK-provided bytes.
        return resp["SecretBinary"]
    return secret.encode("utf-8")


def _attr(record: dict[str, Any], name: str) -> str | None:
    """Extract a string message attribute value from an SQS record."""
    attrs = record.get("messageAttributes", {})
    entry = attrs.get(name)
    if not entry:
        return None
    return entry.get("stringValue")


def process_event(source: str, payload: dict[str, Any]) -> None:
    """Apply business logic to a verified webhook event.

    Replace this with the real downstream work (persist, enqueue, call an API…).
    Raising signals a *retryable* failure for this record only.

    Args:
        source: The ``{source}`` path part identifying the provider/integration.
        payload: The parsed JSON webhook body.
    """
    LOGGER.info("processing verified webhook source=%s keys=%s", source, sorted(payload))
    # ---- business logic goes here ----


def handle(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    """Lambda entry point for the SQS event source mapping."""
    failures: list[dict[str, str]] = []
    key = _signing_key()

    for record in event.get("Records", []):
        message_id = record["messageId"]
        source = _attr(record, "source") or "unknown"
        signature = _attr(record, "signature") or ""
        body = record.get("body", "")

        try:
            ok = verify(
                secret=key,
                body=body.encode("utf-8"),
                provided_signature=signature,
                algorithm=SIGNATURE_ALGORITHM,
                prefix=SIGNATURE_PREFIX,
            )
            if not ok:
                raise _Unverified(message_id)

            payload = json.loads(body) if body else {}
            process_event(source, payload)

        except (_Unverified, SignatureError):
            # Non-retryable: a bad signature never becomes good. Drop + log so it
            # does not loop until it hits the DLQ.
            LOGGER.warning("dropping record %s source=%s: signature verification failed", message_id, source)
        except json.JSONDecodeError:
            LOGGER.warning("dropping record %s source=%s: body is not valid JSON", message_id, source)
        except Exception:  # noqa: BLE001 - report failure, keep the batch alive
            LOGGER.exception("retryable failure for record %s source=%s", message_id, source)
            failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": failures}
