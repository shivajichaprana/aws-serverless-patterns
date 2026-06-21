"""Tests for the idempotent-processor handler (Lambda Powertools + DynamoDB).

Skips automatically if ``aws_lambda_powertools`` is not installed. Verifies that
duplicate idempotency keys collapse to a single persisted record (exactly-once
side effects) while distinct keys are processed independently.
"""

from __future__ import annotations

import json

import boto3
import pytest
from moto import mock_aws

from conftest import load_pattern_module

pytest.importorskip("aws_lambda_powertools")

TABLE = "idempotency-store"


def _create_table():
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    ddb.create_table(
        TableName=TABLE,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )


def _load(monkeypatch):
    monkeypatch.setenv("IDEMPOTENCY_TABLE", TABLE)
    monkeypatch.setenv("POWERTOOLS_SERVICE_NAME", "idempotent-test")
    monkeypatch.setenv("POWERTOOLS_IDEMPOTENCY_DISABLED", "false")
    monkeypatch.setenv("POWERTOOLS_TRACE_DISABLED", "true")
    return load_pattern_module("idempotent-processor", "handler")


def _sqs_record(message_id: str, payload: dict) -> dict:
    return {"messageId": message_id, "body": json.dumps(payload)}


def _item_count() -> int:
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    return ddb.scan(TableName=TABLE, Select="COUNT")["Count"]


@mock_aws
def test_duplicate_keys_collapse_to_one_record(monkeypatch, lambda_context):
    _create_table()
    handler = _load(monkeypatch)

    event = {
        "Records": [
            _sqs_record("m1", {"idempotency_key": "dup-1", "data": "a"}),
            _sqs_record("m2", {"idempotency_key": "dup-1", "data": "b"}),
        ]
    }
    result = handler.handle(event, lambda_context)
    assert result["batchItemFailures"] == []
    assert _item_count() == 1


@mock_aws
def test_distinct_keys_are_processed_independently(monkeypatch, lambda_context):
    _create_table()
    handler = _load(monkeypatch)

    event = {
        "Records": [
            _sqs_record("m1", {"idempotency_key": "k-1"}),
            _sqs_record("m2", {"idempotency_key": "k-2"}),
        ]
    }
    result = handler.handle(event, lambda_context)
    assert result["batchItemFailures"] == []
    assert _item_count() == 2
