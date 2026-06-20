"""DynamoDB-backed persistence for long-running job executions.

A single item per job (keyed by ``job_id``) tracks the lifecycle status, the
poll-attempt counter, progress, and the Step Functions task token captured at the
sign-off gate. Updates use atomic expressions so concurrent retries from Step
Functions stay consistent.
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

# Job lifecycle states persisted in the ``status`` attribute.
STATUS_SUBMITTED = "SUBMITTED"
STATUS_RUNNING = "RUNNING"
STATUS_SUCCEEDED = "SUCCEEDED"
STATUS_FAILED = "FAILED"
STATUS_COMPLETED = "COMPLETED"


def _now() -> int:
    """Current Unix time in whole seconds."""
    return int(time.time())


class JobStore:
    """Thin repository over the job-state DynamoDB table."""

    def __init__(self, table_name: Optional[str] = None, *, resource: Any = None) -> None:
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

    def create(
        self,
        job_id: str,
        *,
        succeed_after_attempts: int,
        fail_job: bool,
        payload: Optional[dict[str, Any]] = None,
        ttl_seconds: Optional[int] = None,
    ) -> None:
        """Create (or reset) the job record for ``job_id`` in SUBMITTED state.

        ``succeed_after_attempts`` and ``fail_job`` drive the deterministic,
        store-backed job simulation used by :func:`handlers.poll_job` so the Wait
        + poll loop can be exercised without a real backend system.
        """
        item: dict[str, Any] = {
            "job_id": job_id,
            "status": STATUS_SUBMITTED,
            "attempts": Decimal(0),
            "progress": Decimal(0),
            "succeed_after_attempts": Decimal(int(succeed_after_attempts)),
            "fail_job": bool(fail_job),
            "payload": payload or {},
            "created_at": _now(),
            "updated_at": _now(),
        }
        if ttl_seconds and ttl_seconds > 0:
            item["expires_at"] = _now() + ttl_seconds
        self._table.put_item(Item=item)
        logger.info("job created", extra={"job_id": job_id})

    def get(self, job_id: str) -> Optional[dict[str, Any]]:
        """Return the job record for ``job_id`` or ``None`` if absent."""
        return self._table.get_item(Key={"job_id": job_id}).get("Item")

    def increment_attempt(self, job_id: str) -> int:
        """Atomically increment and return the poll-attempt counter."""
        resp = self._table.update_item(
            Key={"job_id": job_id},
            UpdateExpression="SET attempts = if_not_exists(attempts, :zero) + :one, updated_at = :u",
            ExpressionAttributeValues={":zero": Decimal(0), ":one": Decimal(1), ":u": _now()},
            ReturnValues="UPDATED_NEW",
        )
        return int(resp["Attributes"]["attempts"])

    def update_progress(self, job_id: str, status: str, progress: int) -> None:
        """Persist the latest status and progress percentage."""
        self._table.update_item(
            Key={"job_id": job_id},
            UpdateExpression="SET #st = :s, progress = :p, updated_at = :u",
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={":s": status, ":p": Decimal(int(progress)), ":u": _now()},
        )

    def set_status(self, job_id: str, status: str) -> None:
        """Update the overall job status."""
        self._table.update_item(
            Key={"job_id": job_id},
            UpdateExpression="SET #st = :s, updated_at = :u",
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={":s": status, ":u": _now()},
        )

    def attach_token(self, job_id: str, task_token: str) -> None:
        """Store the Step Functions task token captured at the sign-off gate."""
        self._table.update_item(
            Key={"job_id": job_id},
            UpdateExpression="SET task_token = :t, signoff_status = :p, updated_at = :u",
            ExpressionAttributeValues={":t": task_token, ":p": "PENDING", ":u": _now()},
        )
