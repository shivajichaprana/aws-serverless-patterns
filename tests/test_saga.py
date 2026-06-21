"""Tests for the saga handlers (patterns/saga/src) backed by moto DynamoDB."""

from __future__ import annotations

import boto3
import pytest
from moto import mock_aws

from conftest import load_pattern_module

TABLE = "saga-state"


def _create_table():
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    ddb.create_table(
        TableName=TABLE,
        KeySchema=[{"AttributeName": "order_id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "order_id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )


def _load(monkeypatch):
    monkeypatch.setenv("TABLE_NAME", TABLE)
    return load_pattern_module("saga", "handlers")


def _order_event(**extra):
    event = {
        "order": {
            "order_id": "ord-1001",
            "customer_id": "cust-42",
            "amount": 149.99,
            "currency": "USD",
            "items": [{"sku": "SKU-1", "qty": 2}],
        },
        "fail_at": None,
        "flaky_steps": {},
    }
    event.update(extra)
    return event


@mock_aws
def test_happy_path_completes(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    event = _order_event()

    h.create_order(event, None)
    h.charge_payment(event, None)
    h.reserve_inventory(event, None)
    h.schedule_shipment(event, None)
    h.complete_saga(event, None)

    from store import STATUS_COMPLETED, SagaStore  # resolves to saga's store

    record = SagaStore(TABLE).get("ord-1001")
    assert record["status"] == STATUS_COMPLETED
    assert record["step_status"]["create_order"]["status"] == "DONE"
    assert record["step_status"]["charge_payment"]["status"] == "DONE"


@mock_aws
def test_business_failure_raises(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    event = _order_event(fail_at="charge_payment")

    h.create_order(event, None)
    with pytest.raises(h.SagaBusinessError):
        h.charge_payment(event, None)


@mock_aws
def test_missing_order_raises_business_error(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    with pytest.raises(h.SagaBusinessError):
        h.create_order({"order": {}}, None)


@mock_aws
def test_transient_injection_then_success(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    event = _order_event(flaky_steps={"charge_payment": 2})

    h.create_order(event, None)
    # First attempt: injected transient failure (attempt 1 < 2).
    with pytest.raises(h.SagaTransientError):
        h.charge_payment(event, None)
    # Second attempt: counter reaches the threshold and the step succeeds.
    result = h.charge_payment(event, None)
    assert result["status"] == "CHARGED"


@mock_aws
def test_compensation_marks_failed(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    event = _order_event()
    h.create_order(event, None)
    h.cancel_order(event, None)
    h.mark_failed(event, None)

    from store import STATUS_FAILED, SagaStore

    assert SagaStore(TABLE).get("ord-1001")["status"] == STATUS_FAILED
