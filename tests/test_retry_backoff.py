"""Tests for the retry-backoff processor (patterns/retry-backoff/src/handler.py).

Covers the pure backoff-curve maths and the SQS-backed failure path (a failed
record is reported in ``batchItemFailures`` and its visibility timeout is extended
so it is not immediately redelivered).
"""

from __future__ import annotations

import json
import random

import boto3
import pytest
from moto import mock_aws

from conftest import load_pattern_module


@pytest.fixture
def handler():
    # Import is side-effect-free (no env / client at import time).
    return load_pattern_module("retry-backoff", "handler")


# --------------------------------------------------------------------------- #
# compute_backoff_seconds — pure backoff curve
# --------------------------------------------------------------------------- #

def test_backoff_respects_exponential_ceiling(handler):
    # With jitter forced to its maximum (uniform -> upper bound), the delay equals
    # the deterministic ceiling base * 2^(attempt-1).
    class MaxRng:
        def uniform(self, a, b):
            return b

    rng = MaxRng()
    assert handler.compute_backoff_seconds(1, base=5, cap=900, rng=rng) == 5
    assert handler.compute_backoff_seconds(2, base=5, cap=900, rng=rng) == 10
    assert handler.compute_backoff_seconds(3, base=5, cap=900, rng=rng) == 20
    assert handler.compute_backoff_seconds(4, base=5, cap=900, rng=rng) == 40


def test_backoff_is_capped(handler):
    class MaxRng:
        def uniform(self, a, b):
            return b

    # 5 * 2^9 = 2560, but cap is 900.
    assert handler.compute_backoff_seconds(10, base=5, cap=900, rng=MaxRng()) == 900


def test_backoff_full_jitter_within_bounds(handler):
    rng = random.Random(1234)
    for attempt in range(1, 12):
        delay = handler.compute_backoff_seconds(attempt, base=5, cap=900, rng=rng)
        ceiling = min(900, 5 * (2 ** min(attempt - 1, 30)))
        assert 0 <= delay <= ceiling


def test_backoff_never_exceeds_sqs_maximum(handler):
    class MaxRng:
        def uniform(self, a, b):
            return b

    # A huge cap is still clamped to the SQS 12h visibility maximum.
    assert handler.compute_backoff_seconds(40, base=60, cap=10**9, rng=MaxRng()) == 43200


# --------------------------------------------------------------------------- #
# handle — SQS-backed failure path
# --------------------------------------------------------------------------- #

@mock_aws
def test_failed_record_is_backed_off_and_reported(monkeypatch):
    sqs = boto3.client("sqs", region_name="us-east-1")
    dlq = sqs.create_queue(QueueName="rb-dlq")["QueueUrl"]
    dlq_arn = sqs.get_queue_attributes(QueueUrl=dlq, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    queue = sqs.create_queue(
        QueueName="rb-queue",
        Attributes={
            "VisibilityTimeout": "0",
            "RedrivePolicy": json.dumps({"deadLetterTargetArn": dlq_arn, "maxReceiveCount": 5}),
        },
    )["QueueUrl"]

    sqs.send_message(QueueUrl=queue, MessageBody=json.dumps({"order_id": "o-1"}))
    received = sqs.receive_message(QueueUrl=queue, AttributeNames=["All"])["Messages"][0]

    monkeypatch.setenv("QUEUE_URL", queue)
    monkeypatch.setenv("BACKOFF_BASE_SECONDS", "5")
    monkeypatch.setenv("BACKOFF_MAX_SECONDS", "900")

    handler = load_pattern_module("retry-backoff", "handler")
    # Force a retryable failure and a deterministic, non-zero backoff.
    monkeypatch.setattr(handler, "process_record", lambda body, attrs: (_ for _ in ()).throw(handler.RetryableError("nope")))
    monkeypatch.setattr(handler, "compute_backoff_seconds", lambda *a, **k: 120)

    event = {
        "Records": [
            {
                "messageId": received["MessageId"],
                "receiptHandle": received["ReceiptHandle"],
                "body": received["Body"],
                "attributes": {"ApproximateReceiveCount": received["Attributes"]["ApproximateReceiveCount"]},
            }
        ]
    }
    result = handler.handle(event, None)

    assert result["batchItemFailures"] == [{"itemIdentifier": received["MessageId"]}]
    # The message had its visibility extended to 120s, so it is not immediately
    # redelivered despite the queue's own VisibilityTimeout being 0.
    again = sqs.receive_message(QueueUrl=queue, WaitTimeSeconds=0)
    assert "Messages" not in again or len(again["Messages"]) == 0


@mock_aws
def test_successful_record_acks(monkeypatch):
    sqs = boto3.client("sqs", region_name="us-east-1")
    queue = sqs.create_queue(QueueName="rb-ok")["QueueUrl"]
    monkeypatch.setenv("QUEUE_URL", queue)

    handler = load_pattern_module("retry-backoff", "handler")
    event = {
        "Records": [
            {
                "messageId": "m1",
                "receiptHandle": "rh",
                "body": json.dumps({"order_id": "o-1"}),
                "attributes": {"ApproximateReceiveCount": "1"},
            }
        ]
    }
    # Default process_record succeeds -> nothing reported as a failure.
    assert handler.handle(event, None) == {"batchItemFailures": []}


@mock_aws
def test_unparseable_body_is_sent_to_dlq_path(monkeypatch):
    sqs = boto3.client("sqs", region_name="us-east-1")
    queue = sqs.create_queue(QueueName="rb-junk")["QueueUrl"]
    monkeypatch.setenv("QUEUE_URL", queue)

    handler = load_pattern_module("retry-backoff", "handler")
    event = {
        "Records": [
            {
                "messageId": "junk",
                "receiptHandle": "rh",
                "body": "}{not-json",
                "attributes": {"ApproximateReceiveCount": "1"},
            }
        ]
    }
    # Reported as a failure so SQS redrives it toward the DLQ (it can never parse).
    assert handler.handle(event, None) == {"batchItemFailures": [{"itemIdentifier": "junk"}]}
