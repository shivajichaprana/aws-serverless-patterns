"""Custom exception types for the long-running pattern handlers.

Step Functions matches ``Retry`` / ``Catch`` rules against the *class name* of the
exception a Python Lambda raises, so these names are part of the contract with
``statemachine.asl.json``:

* ``JobTransientError`` is retryable — the Task ``Retry`` blocks back off and try
  again before the step is considered failed.
* ``JobNotFoundError`` and other :class:`JobError` subclasses are terminal: they
  fall through to the state's ``Catch`` and end the execution in a Fail state.
"""

from __future__ import annotations


class JobError(Exception):
    """Base class for all long-running-job errors."""


class JobTransientError(JobError):
    """A retryable failure (throttling, dependency blip, optimistic-lock clash)."""


class JobNotFoundError(JobError):
    """Raised when a job record cannot be found for the supplied job_id."""
