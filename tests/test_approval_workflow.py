"""Tests for the approval-workflow handlers backed by moto DynamoDB + SES.

The Step Functions task-token callback (SendTaskSuccess/SendTaskFailure) is not
exercised here — moto cannot resume a real paused execution — so these tests
cover request preparation, the SES email, the single-decision store guard, the
rejection-cause parsing, and the API decision_handler's validation branches.
"""

from __future__ import annotations

import boto3
import pytest
from moto import mock_aws

from conftest import load_pattern_module

TABLE = "approvals"
FROM = "approvals@example.com"
APPROVER = "manager@example.com"


def _create_table():
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    ddb.create_table(
        TableName=TABLE,
        KeySchema=[{"AttributeName": "request_id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "request_id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )


def _load(monkeypatch):
    monkeypatch.setenv("TABLE_NAME", TABLE)
    monkeypatch.setenv("FROM_ADDRESS", FROM)
    monkeypatch.setenv("APPROVER_ADDRESSES", APPROVER)
    monkeypatch.setenv("API_BASE_URL", "https://api.example.com")
    monkeypatch.setenv("EMAIL_SUBJECT_PREFIX", "[Approval Required]")
    return load_pattern_module("approval-workflow", "handlers")


@mock_aws
def test_prepare_request_persists_pending(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    out = h.prepare_request({"request_id": "req-1", "title": "Refund #42", "amount": 100}, None)
    assert out["request_id"] == "req-1"

    from store import STATUS_PENDING, ApprovalStore

    assert ApprovalStore(TABLE).get("req-1")["status"] == STATUS_PENDING


@mock_aws
def test_prepare_request_requires_title(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    with pytest.raises(h.ApprovalInputError):
        h.prepare_request({"amount": 10}, None)


@mock_aws
def test_prepare_request_rejects_non_numeric_amount(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    with pytest.raises(h.ApprovalInputError):
        h.prepare_request({"title": "x", "amount": "not-a-number"}, None)


@mock_aws
def test_send_approval_email_marks_notified(monkeypatch):
    _create_table()
    ses = boto3.client("ses", region_name="us-east-1")
    ses.verify_email_identity(EmailAddress=FROM)
    ses.verify_email_identity(EmailAddress=APPROVER)

    h = _load(monkeypatch)
    h.prepare_request({"request_id": "req-2", "title": "Deploy prod"}, None)
    out = h.send_approval_email({"task_token": "tok-9", "request": {"request_id": "req-2"}}, None)
    assert out["status"] == "NOTIFIED"

    from store import STATUS_NOTIFIED, ApprovalStore

    assert ApprovalStore(TABLE).get("req-2")["status"] == STATUS_NOTIFIED


@mock_aws
def test_store_guards_against_double_decision(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    h.prepare_request({"request_id": "req-3", "title": "Pay invoice"}, None)

    from store import STATUS_APPROVED, AlreadyDecidedError, ApprovalStore

    store = ApprovalStore(TABLE)
    store.attach_token("req-3", "tok")
    store.record_decision("req-3", STATUS_APPROVED, "alice", "ok")
    with pytest.raises(AlreadyDecidedError):
        store.record_decision("req-3", STATUS_APPROVED, "bob", "again")


@mock_aws
def test_on_rejected_parses_cause(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    event = {
        "request": {"request_id": "req-4"},
        "decision": {"Cause": '{"rejected_by": "bob", "comment": "no budget"}'},
    }
    out = h.on_rejected(event, None)
    assert out["outcome"] == "REJECTED"
    assert out["rejected_by"] == "bob"
    assert out["comment"] == "no budget"


@mock_aws
def test_decision_handler_validation_branches(monkeypatch):
    _create_table()
    h = _load(monkeypatch)

    bad = h.decision_handler({"rawPath": "/approve", "queryStringParameters": {"request_id": "x"}}, None)
    assert bad["statusCode"] == 400  # missing token

    missing = h.decision_handler(
        {"rawPath": "/approve", "queryStringParameters": {"request_id": "ghost", "token": "t"}}, None
    )
    assert missing["statusCode"] == 404  # no such request
