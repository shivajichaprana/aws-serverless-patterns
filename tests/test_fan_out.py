"""Tests for the fan-out worker (patterns/fan-out/src/worker.py).

The worker is pure (no AWS calls), so these exercise the partial-batch-response
contract directly: successful records are acknowledged, failing records are
returned in ``batchItemFailures``, and unparseable records are dropped.
"""

from __future__ import annotations

import json

import pytest

from conftest import load_pattern_module


@pytest.fixture
def worker():
    return load_pattern_module("fan-out", "worker")


def _record(message_id: str, body: object, receive_count: int = 1) -> dict:
    return {
        "messageId": message_id,
        "body": json.dumps(body) if not isinstance(body, str) else body,
        "attributes": {"ApproximateReceiveCount": str(receive_count)},
    }


def test_all_records_succeed(worker):
    event = {"Records": [_record("m1", {"event_type": "order_created"})]}
    assert worker.handler(event, None) == {"batchItemFailures": []}


def test_failing_record_is_reported(worker, monkeypatch):
    def boom(body, attributes):
        if body.get("event_type") == "bad":
            raise worker.TransientError("downstream down")

    monkeypatch.setattr(worker, "process_record", boom)

    event = {
        "Records": [
            _record("ok", {"event_type": "order_created"}),
            _record("bad", {"event_type": "bad"}),
        ]
    }
    result = worker.handler(event, None)
    assert result["batchItemFailures"] == [{"itemIdentifier": "bad"}]


def test_unparseable_record_is_dropped_not_failed(worker):
    # A non-JSON body can never be processed; it is logged and allowed to drain
    # toward the DLQ rather than being retried forever.
    event = {"Records": [_record("junk", "not-json")]}
    assert worker.handler(event, None) == {"batchItemFailures": []}
