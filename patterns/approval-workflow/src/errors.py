"""Custom exception types for the approval-workflow handlers.

``ApprovalInputError`` is raised by :func:`handlers.prepare_request` for invalid
input. Step Functions matches ``Catch`` rules on the exception class name, so the
state machine routes any unhandled error from ``PrepareRequest`` to a Fail state.

The *rejection* path is signalled differently: it does not raise here. The API
callback calls ``SendTaskFailure(error="ApprovalRejected", ...)``, which makes the
paused ``RequestApproval`` task fail with the error name ``ApprovalRejected`` —
the value the state machine's ``Catch`` block keys on.
"""

from __future__ import annotations


class ApprovalError(Exception):
    """Base class for approval-workflow errors."""


class ApprovalInputError(ApprovalError):
    """Raised when an approval request fails validation."""
