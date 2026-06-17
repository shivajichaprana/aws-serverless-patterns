"""DynamoDB-backed persistence for saga executions.

A single item per saga (keyed by ``order_id``) tracks the overall status, a
per-step status map, and a per-step attempt counter. Writes use conditional and
atomic update expressions so that concurrent retries from Step Functions remain
consistent.
"""

from __future__ import annotations

import logging
import os
import time
from decimal import Decimal
from typing import Any, Optional

import boto3
from botocore.config import Config

logger = logging.getLogger(__name__)

# Bounded client-side retries so a transient DynamoDB blip does not immediately
# surface as a step failure.
_DDB_CONFIG = Config(retries={"max_attempts": 5, "mode": "standard"})

# Saga lifecycle states persisted in the ``status`` attribute.
STATUS_STARTED = "STARTED"
STATUS_COMPLETED = "COMPLETED"
STATUS_FAILED = "FAILED"
STATUS_COMPENSATING = "COMPENSATING"


def _now() -> int:
    """Current Unix time in whole seconds."""
    return int(time.time())


class SagaStore:
    """Thin repository over the saga-state DynamoDB table."""

    def __init__(
        self,
        table_name: Optional[str] = None,
        *,
        resource: Any = None,
    ) -> None:
        """Create a store.

        Args:
            table_name: Table name. Defaults to the ``TABLE_NAME`` environment
                variable injected by Terraform.
            resource: Optional pre-built ``boto3`` DynamoDB *resource* (used by
                tests to inject a mocked backend).
        """
        self.table_name = table_name or os.environ["TABLE_NAME"]
        ddb = resource or boto3.resource("dynamodb", config=_DDB_CONFIG)
        self._table = ddb.Table(self.table_name)

    # ------------------------------------------------------------------ writes

    def start(
        self,
        order_id: str,
        *,
        customer_id: str,
        amount: float,
        currency: str,
        ttl_seconds: Optional[int] = None,
    ) -> None:
        """Create (or reset) the saga record for ``order_id`` in STARTED state.

        Idempotent across retries of the first step: re-running simply overwrites
        the record with a fresh STARTED snapshot, which is the desired behavior if
        ``create_order`` is retried.
        """
        item: dict[str, Any] = {
            "order_id": order_id,
            "customer_id": customer_id,
            "amount": Decimal(str(amount)),
            "currency": currency,
            "status": STATUS_STARTED,
            "step_status": {},
            "attempts": {},
            "created_at": _now(),
            "updated_at": _now(),
        }
        if ttl_seconds and ttl_seconds > 0:
            item["expires_at"] = _now() + ttl_seconds
        self._table.put_item(Item=item)
        logger.info("saga started", extra={"order_id": order_id})

    def record_step(
        self,
        order_id: str,
        step: str,
        status: str,
        detail: Optional[dict[str, Any]] = None,
    ) -> None:
        """Record the outcome of a single saga step.

        Uses a SET on a nested map path; the parent ``step_status`` map is created
        by :meth:`start`, so the path always resolves.
        """
        self._table.update_item(
            Key={"order_id": order_id},
            UpdateExpression="SET #ss.#step = :v, updated_at = :u",
            ExpressionAttributeNames={"#ss": "step_status", "#step": step},
            ExpressionAttributeValues={
                ":v": {"status": status, "detail": detail or {}, "at": _now()},
                ":u": _now(),
            },
        )
        logger.info(
            "saga step recorded",
            extra={"order_id": order_id, "step": step, "status": status},
        )

    def set_status(self, order_id: str, status: str) -> None:
        """Update the overall saga status."""
        self._table.update_item(
            Key={"order_id": order_id},
            UpdateExpression="SET #st = :s, updated_at = :u",
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={":s": status, ":u": _now()},
        )
        logger.info(
            "saga status updated",
            extra={"order_id": order_id, "status": status},
        )

    def increment_attempt(self, order_id: str, step: str) -> int:
        """Atomically increment and return the attempt counter for ``step``.

        DynamoDB's ``ADD`` action only works on top-level attributes, so the
        nested per-step counter is incremented with ``SET`` + ``if_not_exists``
        arithmetic instead. The parent ``attempts`` map is created by
        :meth:`start`. Used to drive deterministic, store-backed transient-failure
        injection so the retry behavior of the state machine can be exercised.
        """
        resp = self._table.update_item(
            Key={"order_id": order_id},
            UpdateExpression=(
                "SET #att.#step = if_not_exists(#att.#step, :zero) + :one, "
                "updated_at = :u"
            ),
            ExpressionAttributeNames={"#att": "attempts", "#step": step},
            ExpressionAttributeValues={":zero": Decimal(0), ":one": Decimal(1), ":u": _now()},
            ReturnValues="UPDATED_NEW",
        )
        return int(resp["Attributes"]["attempts"][step])

    # ------------------------------------------------------------------- reads

    def get(self, order_id: str) -> Optional[dict[str, Any]]:
        """Return the saga record for ``order_id`` or ``None`` if absent."""
        return self._table.get_item(Key={"order_id": order_id}).get("Item")
