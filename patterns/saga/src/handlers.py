"""Lambda handlers for the order-fulfillment saga.

Each Step Functions ``Task`` maps to one function here. The forward steps
(``create_order`` -> ``charge_payment`` -> ``reserve_inventory`` ->
``schedule_shipment``) advance the order; the compensation steps
(``release_inventory``, ``refund_payment``, ``cancel_order``) undo completed work
in reverse order when a later step fails.

Failure injection (for demos and tests) is driven entirely by the execution
input, so the saga can be exercised without real payment or inventory systems:

* ``"fail_at": "<step>"`` makes that step raise :class:`SagaBusinessError`, which
  is not retried and triggers compensation immediately.
* ``"flaky_steps": {"<step>": <n>}`` makes that step raise
  :class:`SagaTransientError` until its attempt counter reaches ``n``, exercising
  the retry/backoff configuration before succeeding.

Example execution input::

    {
      "order": {
        "order_id": "ord-1001",
        "customer_id": "cust-42",
        "amount": 149.99,
        "currency": "USD",
        "items": [{"sku": "SKU-1", "qty": 2}]
      },
      "fail_at": null,
      "flaky_steps": {}
    }
"""

from __future__ import annotations

import logging
import os
import uuid
from typing import Any

from errors import SagaBusinessError, SagaTransientError
from store import (
    STATUS_COMPENSATING,
    STATUS_COMPLETED,
    STATUS_FAILED,
    SagaStore,
)

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

# Default TTL (seconds) for completed saga records; mirrors the Terraform default.
_DEFAULT_TTL_SECONDS = 90 * 24 * 60 * 60

Event = dict[str, Any]


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

def _store() -> SagaStore:
    """Build a saga store bound to the configured table."""
    return SagaStore()


def _order(event: Event) -> dict[str, Any]:
    """Extract and lightly validate the ``order`` block from the event."""
    order = event.get("order")
    if not isinstance(order, dict) or "order_id" not in order:
        raise SagaBusinessError("event is missing a valid 'order' object with 'order_id'")
    return order


def _new_id(prefix: str) -> str:
    """Generate a short, prefixed identifier."""
    return f"{prefix}-{uuid.uuid4().hex[:12]}"


def _maybe_inject_transient(store: SagaStore, order_id: str, step: str, event: Event) -> None:
    """Raise :class:`SagaTransientError` until ``step``'s attempt count is reached.

    ``flaky_steps`` maps a step name to the attempt on which it should finally
    succeed (1-based). Each call atomically increments the stored attempt counter.
    """
    flaky = event.get("flaky_steps") or {}
    succeed_on = flaky.get(step)
    if not succeed_on:
        return
    attempt = store.increment_attempt(order_id, step)
    if attempt < int(succeed_on):
        raise SagaTransientError(
            f"{step}: injected transient failure on attempt {attempt} "
            f"(will succeed on attempt {succeed_on})"
        )


def _maybe_inject_business_failure(event: Event, step: str) -> None:
    """Raise :class:`SagaBusinessError` if ``fail_at`` targets ``step``."""
    if event.get("fail_at") == step:
        raise SagaBusinessError(f"{step}: injected business failure (fail_at={step})")


# --------------------------------------------------------------------------- #
# Forward steps
# --------------------------------------------------------------------------- #

def create_order(event: Event, context: Any = None) -> dict[str, Any]:
    """Forward step 1: persist a new order in STARTED/PENDING state."""
    order = _order(event)
    order_id = order["order_id"]
    amount = float(order.get("amount", 0))
    items = order.get("items") or []

    if amount <= 0:
        raise SagaBusinessError(f"order {order_id}: amount must be positive, got {amount}")
    if not items:
        raise SagaBusinessError(f"order {order_id}: at least one line item is required")

    store = _store()
    store.start(
        order_id,
        customer_id=str(order.get("customer_id", "unknown")),
        amount=amount,
        currency=str(order.get("currency", "USD")),
        ttl_seconds=_DEFAULT_TTL_SECONDS,
    )
    _maybe_inject_transient(store, order_id, "create_order", event)
    _maybe_inject_business_failure(event, "create_order")

    result = {"order_id": order_id, "status": "PENDING", "line_items": len(items)}
    store.record_step(order_id, "create_order", "DONE", result)
    logger.info("create_order completed for %s", order_id)
    return result


def charge_payment(event: Event, context: Any = None) -> dict[str, Any]:
    """Forward step 2: charge the customer's payment method."""
    order = _order(event)
    order_id = order["order_id"]
    store = _store()

    _maybe_inject_transient(store, order_id, "charge_payment", event)
    _maybe_inject_business_failure(event, "charge_payment")

    payment_id = _new_id("pay")
    result = {
        "payment_id": payment_id,
        "amount": float(order.get("amount", 0)),
        "currency": str(order.get("currency", "USD")),
        "status": "CHARGED",
    }
    store.record_step(order_id, "charge_payment", "DONE", {"payment_id": payment_id})
    logger.info("charge_payment captured %s for order %s", payment_id, order_id)
    return result


def reserve_inventory(event: Event, context: Any = None) -> dict[str, Any]:
    """Forward step 3: reserve inventory for the order's line items."""
    order = _order(event)
    order_id = order["order_id"]
    store = _store()

    _maybe_inject_transient(store, order_id, "reserve_inventory", event)
    _maybe_inject_business_failure(event, "reserve_inventory")

    reservation_id = _new_id("rsv")
    result = {
        "reservation_id": reservation_id,
        "items": order.get("items") or [],
        "status": "RESERVED",
    }
    store.record_step(order_id, "reserve_inventory", "DONE", {"reservation_id": reservation_id})
    logger.info("reserve_inventory created %s for order %s", reservation_id, order_id)
    return result


def schedule_shipment(event: Event, context: Any = None) -> dict[str, Any]:
    """Forward step 4: schedule the outbound shipment."""
    order = _order(event)
    order_id = order["order_id"]
    store = _store()

    _maybe_inject_transient(store, order_id, "schedule_shipment", event)
    _maybe_inject_business_failure(event, "schedule_shipment")

    shipment_id = _new_id("shp")
    result = {
        "shipment_id": shipment_id,
        "tracking_number": _new_id("trk").upper(),
        "status": "SCHEDULED",
    }
    store.record_step(order_id, "schedule_shipment", "DONE", {"shipment_id": shipment_id})
    logger.info("schedule_shipment created %s for order %s", shipment_id, order_id)
    return result


def complete_saga(event: Event, context: Any = None) -> dict[str, Any]:
    """Terminal happy-path step: mark the saga COMPLETED."""
    order = _order(event)
    order_id = order["order_id"]
    store = _store()
    store.set_status(order_id, STATUS_COMPLETED)
    logger.info("saga %s completed successfully", order_id)
    return {"status": STATUS_COMPLETED}


# --------------------------------------------------------------------------- #
# Compensation steps (run in reverse order on failure)
# --------------------------------------------------------------------------- #

def _completed_detail(event: Event, step: str) -> dict[str, Any]:
    """Return the recorded detail for a previously completed forward step."""
    results = event.get("results") or {}
    block = results.get(step) or {}
    return block if isinstance(block, dict) else {}


def release_inventory(event: Event, context: Any = None) -> dict[str, Any]:
    """Compensation for :func:`reserve_inventory` — release the reservation."""
    order = _order(event)
    order_id = order["order_id"]
    store = _store()
    store.set_status(order_id, STATUS_COMPENSATING)

    reservation = _completed_detail(event, "reservation")
    reservation_id = reservation.get("reservation_id")
    if not reservation_id:
        # Nothing was reserved (or already released): compensation is a no-op.
        store.record_step(order_id, "release_inventory", "SKIPPED")
        logger.info("release_inventory: nothing to release for order %s", order_id)
        return {"status": "SKIPPED"}

    store.record_step(order_id, "release_inventory", "DONE", {"reservation_id": reservation_id})
    logger.info("release_inventory released %s for order %s", reservation_id, order_id)
    return {"status": "RELEASED", "reservation_id": reservation_id}


def refund_payment(event: Event, context: Any = None) -> dict[str, Any]:
    """Compensation for :func:`charge_payment` — refund the captured charge."""
    order = _order(event)
    order_id = order["order_id"]
    store = _store()
    store.set_status(order_id, STATUS_COMPENSATING)

    payment = _completed_detail(event, "payment")
    payment_id = payment.get("payment_id")
    if not payment_id:
        store.record_step(order_id, "refund_payment", "SKIPPED")
        logger.info("refund_payment: nothing to refund for order %s", order_id)
        return {"status": "SKIPPED"}

    store.record_step(order_id, "refund_payment", "DONE", {"payment_id": payment_id})
    logger.info("refund_payment refunded %s for order %s", payment_id, order_id)
    return {"status": "REFUNDED", "payment_id": payment_id}


def cancel_order(event: Event, context: Any = None) -> dict[str, Any]:
    """Compensation for :func:`create_order` — mark the order cancelled."""
    order = _order(event)
    order_id = order["order_id"]
    store = _store()
    store.set_status(order_id, STATUS_COMPENSATING)
    store.record_step(order_id, "cancel_order", "DONE")
    logger.info("cancel_order cancelled order %s", order_id)
    return {"status": "CANCELLED", "order_id": order_id}


def mark_failed(event: Event, context: Any = None) -> dict[str, Any]:
    """Terminal failure step: record the saga as FAILED after rollback."""
    order = _order(event)
    order_id = order["order_id"]
    store = _store()
    store.set_status(order_id, STATUS_FAILED)
    cause = (event.get("error") or {}).get("Cause", "unknown")
    logger.warning("saga %s marked FAILED (cause: %s)", order_id, cause)
    return {"status": STATUS_FAILED}
