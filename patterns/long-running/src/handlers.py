"""Lambda handlers for the long-running workflow pattern.

Each Step Functions ``Task`` maps to one function here:

* ``submit_job``      — start the asynchronous job and persist its initial state.
* ``poll_job``        — check status and compute the next exponential-backoff wait.
* ``request_signoff`` — record the task token and request human sign-off; invoked
                        with ``.waitForTaskToken`` so the execution pauses until
                        ``SendTaskSuccess``/``SendTaskFailure`` is called.
* ``finalize``        — mark the job COMPLETED once it is signed off.

The job itself is simulated deterministically from two fields persisted at submit
time so the Wait + poll loop can be exercised end-to-end without a real backend:

* ``succeed_after_attempts`` — the poll attempt on which the job reports SUCCEEDED.
* ``fail_job``               — when true, the first poll reports FAILED.

Example execution input::

    { "job_id": "report-987", "succeed_after_attempts": 3, "fail_job": false }
"""

from __future__ import annotations

import logging
import os
import uuid
from typing import Any

from errors import JobNotFoundError
from store import (
    STATUS_COMPLETED,
    STATUS_FAILED,
    STATUS_RUNNING,
    STATUS_SUCCEEDED,
    JobStore,
)

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

Event = dict[str, Any]


# --------------------------------------------------------------------------- #
# Configuration helpers
# --------------------------------------------------------------------------- #

def _int_env(name: str, default: int) -> int:
    """Read an integer environment variable, falling back to ``default``."""
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def _store() -> JobStore:
    """Build a job store bound to the configured table."""
    return JobStore()


def _new_id(prefix: str) -> str:
    """Generate a short, prefixed identifier."""
    return f"{prefix}-{uuid.uuid4().hex[:12]}"


def _backoff_seconds(attempt: int) -> int:
    """Exponential backoff (base * 2**attempt) capped at the configured maximum.

    ``attempt`` is 0-based: the first wait uses the base interval, the second
    doubles it, and so on, never exceeding ``POLL_INTERVAL_MAX_SECONDS``.
    """
    base = _int_env("POLL_INTERVAL_BASE_SECONDS", 30)
    cap = _int_env("POLL_INTERVAL_MAX_SECONDS", 900)
    return int(min(cap, base * (2 ** max(0, attempt))))


# --------------------------------------------------------------------------- #
# Handlers
# --------------------------------------------------------------------------- #

def submit_job(event: Event, context: Any = None) -> dict[str, Any]:
    """Start the asynchronous job and persist its initial state.

    Returns the ``job`` object that the state machine carries through the Wait +
    poll loop, including ``next_poll_seconds`` for the first Wait state.
    """
    spec = event or {}
    job_id = spec.get("job_id") or _new_id("job")
    succeed_after = int(spec.get("succeed_after_attempts", 3))
    fail_job = bool(spec.get("fail_job", False))

    if succeed_after < 1:
        succeed_after = 1

    ttl_days = _int_env("JOB_STATE_TTL_DAYS", 30)
    store = _store()
    store.create(
        job_id,
        succeed_after_attempts=succeed_after,
        fail_job=fail_job,
        payload=spec.get("payload") or {},
        ttl_seconds=ttl_days * 24 * 60 * 60 if ttl_days > 0 else None,
    )

    next_poll = _backoff_seconds(0)
    logger.info("submitted job %s (succeed_after=%s, fail=%s)", job_id, succeed_after, fail_job)
    return {
        "job_id": job_id,
        "status": STATUS_RUNNING,
        "attempt": 0,
        "exhausted": False,
        "progress": 0,
        "next_poll_seconds": next_poll,
    }


def poll_job(event: Event, context: Any = None) -> dict[str, Any]:
    """Poll the job's status and compute the next backed-off wait interval."""
    job = event.get("job") or {}
    job_id = job.get("job_id")
    if not job_id:
        raise JobNotFoundError("poll_job: event is missing job.job_id")

    store = _store()
    record = store.get(job_id)
    if record is None:
        raise JobNotFoundError(f"poll_job: no job record for {job_id}")

    attempt = store.increment_attempt(job_id)
    max_attempts = _int_env("MAX_POLL_ATTEMPTS", 20)
    succeed_after = int(record.get("succeed_after_attempts", 3))
    fail_job = bool(record.get("fail_job", False))

    if fail_job:
        status = STATUS_FAILED
    elif attempt >= succeed_after:
        status = STATUS_SUCCEEDED
    else:
        status = STATUS_RUNNING

    progress = min(100, int(round(100 * attempt / max(succeed_after, 1))))
    if status in (STATUS_SUCCEEDED, STATUS_COMPLETED):
        progress = 100
    exhausted = status == STATUS_RUNNING and attempt >= max_attempts

    store.update_progress(job_id, status, progress)
    next_poll = _backoff_seconds(attempt)
    logger.info(
        "polled job %s: status=%s attempt=%s/%s progress=%s%% exhausted=%s",
        job_id, status, attempt, max_attempts, progress, exhausted,
    )
    return {
        "job_id": job_id,
        "status": status,
        "attempt": attempt,
        "exhausted": exhausted,
        "progress": progress,
        "next_poll_seconds": next_poll,
    }


def request_signoff(event: Event, context: Any = None) -> dict[str, Any]:
    """Record the task token and request human sign-off.

    Invoked with ``.waitForTaskToken``: the return value is ignored by Step
    Functions, which keeps the execution paused until ``SendTaskSuccess`` (or
    ``SendTaskFailure``) is called with the stored token. A real implementation
    would also emit a notification (email/Slack) carrying a resume link.
    """
    token = event.get("task_token")
    job = event.get("job") or {}
    job_id = job.get("job_id")
    if not job_id:
        raise JobNotFoundError("request_signoff: event is missing job.job_id")
    if not token:
        raise JobNotFoundError("request_signoff: event is missing task_token")

    store = _store()
    store.attach_token(job_id, token)
    logger.info("sign-off requested for job %s; awaiting task-token callback", job_id)
    return {"job_id": job_id, "signoff_status": "PENDING"}


def finalize(event: Event, context: Any = None) -> dict[str, Any]:
    """Mark the job COMPLETED after sign-off."""
    job = event.get("job") or {}
    job_id = job.get("job_id")
    if not job_id:
        raise JobNotFoundError("finalize: event is missing job.job_id")

    signoff = event.get("signoff") or {}
    store = _store()
    store.set_status(job_id, STATUS_COMPLETED)
    logger.info("job %s completed and signed off", job_id)
    return {
        "job_id": job_id,
        "status": STATUS_COMPLETED,
        "signed_off_by": signoff.get("approved_by"),
    }
