"""Custom exception types for the saga handlers.

Step Functions matches ``Retry`` / ``Catch`` rules against the *class name* of the
exception a Python Lambda raises. Keeping these names stable is therefore part of
the contract with ``statemachine.asl.json``:

* ``SagaTransientError`` is listed in each forward step's ``Retry`` block, so it is
  retried with exponential backoff before the step is considered failed.
* ``SagaBusinessError`` is **not** retried; raising it sends the execution straight
  to the step's ``Catch`` block, which begins compensation.
"""

from __future__ import annotations


class SagaError(Exception):
    """Base class for all saga-specific errors."""


class SagaTransientError(SagaError):
    """A retryable failure (throttling, dependency blip, optimistic-lock clash).

    Matched by the ``SagaTransientError`` entry in each forward step's ``Retry``
    list. After the configured attempts are exhausted, Step Functions routes the
    execution to the step's ``Catch`` and compensation begins.
    """


class SagaBusinessError(SagaError):
    """A terminal business-rule failure that must trigger compensation.

    Deliberately excluded from every ``Retry`` block: retrying an invalid order or
    a declined card will never succeed, so the saga should roll back immediately.
    """
