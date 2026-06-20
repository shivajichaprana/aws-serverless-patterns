"""DynamoDB-backed persistence for approval requests.

One item per request (keyed by ``request_id``) tracks the request payload, the
captured Step Functions task token, and the final decision. The status guard
(:meth:`record_decision`'s conditional update) prevents a second click on an
Approve/Reject link from recording a conflicting decision.
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

_DDB_CONFIG = Config(retries={"max_attempts": 5, "mode": "standard"})

STATUS_PENDING = "PENDING"
STATUS_NOTIFIED = "NOTIFIED"
STATUS_APPROVED = "APPROVED"
STATUS_REJECTED = "REJECTED"


def _now() -> int:
    """Current Unix time in whole seconds."""
    return int(time.time())


class AlreadyDecidedError(Exception):
    """Raised when a decision is attempted on a request that is already decided."""


class ApprovalStore:
    """Thin repository over the approval-request DynamoDB table."""

    def __init__(self, table_name: Optional[str] = None, *, resource: Any = None) -> None:
        self.table_name = table_name or os.environ["TABLE_NAME"]
        ddb = resource or boto3.resource("dynamodb", config=_DDB_CONFIG)
        self._table = ddb.Table(self.table_name)

    # ------------------------------------------------------------------ writes

    def create(
        self,
        request_id: str,
        *,
        title: str,
        amount: Optional[float],
        requester: str,
        context: Optional[dict[str, Any]] = None,
        ttl_seconds: Optional[int] = None,
    ) -> None:
        """Persist a new approval request in PENDING state."""
        item: dict[str, Any] = {
            "request_id": request_id,
            "title": title,
            "requester": requester,
            "status": STATUS_PENDING,
            "context": context or {},
            "created_at": _now(),
            "updated_at": _now(),
        }
        if amount is not None:
            item["amount"] = Decimal(str(amount))
        if ttl_seconds and ttl_seconds > 0:
            item["expires_at"] = _now() + ttl_seconds
        self._table.put_item(Item=item)
        logger.info("approval request created", extra={"request_id": request_id})

    def attach_token(self, request_id: str, task_token: str) -> None:
        """Store the task token and mark the request as NOTIFIED."""
        self._table.update_item(
            Key={"request_id": request_id},
            UpdateExpression="SET task_token = :t, #st = :s, updated_at = :u",
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={":t": task_token, ":s": STATUS_NOTIFIED, ":u": _now()},
        )

    def record_decision(
        self,
        request_id: str,
        decision: str,
        approver: str,
        comment: str = "",
    ) -> None:
        """Atomically record the final decision.

        Guarded by a condition so only the first decision wins; a second click is
        rejected with :class:`AlreadyDecidedError`.
        """
        from botocore.exceptions import ClientError

        try:
            self._table.update_item(
                Key={"request_id": request_id},
                UpdateExpression=(
                    "SET #st = :d, approver = :a, decision_comment = :c, decided_at = :t, updated_at = :u"
                ),
                ConditionExpression="attribute_exists(request_id) AND #st IN (:pending, :notified)",
                ExpressionAttributeNames={"#st": "status"},
                ExpressionAttributeValues={
                    ":d": decision,
                    ":a": approver,
                    ":c": comment,
                    ":t": _now(),
                    ":u": _now(),
                    ":pending": STATUS_PENDING,
                    ":notified": STATUS_NOTIFIED,
                },
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise AlreadyDecidedError(request_id) from exc
            raise

    def set_status(self, request_id: str, status: str) -> None:
        """Update the request status without other fields."""
        self._table.update_item(
            Key={"request_id": request_id},
            UpdateExpression="SET #st = :s, updated_at = :u",
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={":s": status, ":u": _now()},
        )

    # ------------------------------------------------------------------- reads

    def get(self, request_id: str) -> Optional[dict[str, Any]]:
        """Return the request record or ``None`` if absent."""
        return self._table.get_item(Key={"request_id": request_id}).get("Item")
