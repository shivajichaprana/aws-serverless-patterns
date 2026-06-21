"""Tests for the long-running workflow handlers backed by moto DynamoDB."""

from __future__ import annotations

import boto3
import pytest
from moto import mock_aws

from conftest import load_pattern_module

TABLE = "job-state"


def _create_table():
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    ddb.create_table(
        TableName=TABLE,
        KeySchema=[{"AttributeName": "job_id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "job_id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )


def _load(monkeypatch):
    monkeypatch.setenv("TABLE_NAME", TABLE)
    monkeypatch.setenv("POLL_INTERVAL_BASE_SECONDS", "30")
    monkeypatch.setenv("POLL_INTERVAL_MAX_SECONDS", "900")
    return load_pattern_module("long-running", "handlers")


@mock_aws
def test_submit_creates_running_job(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    out = h.submit_job({"job_id": "report-1", "succeed_after_attempts": 2}, None)
    assert out["status"] == "RUNNING"
    assert out["attempt"] == 0
    assert out["next_poll_seconds"] == 30


@mock_aws
def test_poll_loop_progresses_to_success(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    h.submit_job({"job_id": "report-2", "succeed_after_attempts": 2}, None)

    first = h.poll_job({"job": {"job_id": "report-2"}}, None)
    assert first["status"] == "RUNNING"
    assert first["attempt"] == 1
    assert first["next_poll_seconds"] == 60  # 30 * 2^1

    second = h.poll_job({"job": {"job_id": "report-2"}}, None)
    assert second["status"] == "SUCCEEDED"
    assert second["progress"] == 100


@mock_aws
def test_poll_reports_failure(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    h.submit_job({"job_id": "report-3", "succeed_after_attempts": 5, "fail_job": True}, None)
    out = h.poll_job({"job": {"job_id": "report-3"}}, None)
    assert out["status"] == "FAILED"


@mock_aws
def test_poll_missing_job_raises(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    with pytest.raises(h.JobNotFoundError):
        h.poll_job({"job": {"job_id": "nope"}}, None)


@mock_aws
def test_signoff_and_finalize(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    h.submit_job({"job_id": "report-4", "succeed_after_attempts": 1}, None)

    h.request_signoff({"job": {"job_id": "report-4"}, "task_token": "tok-123"}, None)
    out = h.finalize({"job": {"job_id": "report-4"}, "signoff": {"approved_by": "alice"}}, None)
    assert out["status"] == "COMPLETED"
    assert out["signed_off_by"] == "alice"


@mock_aws
def test_backoff_curve(monkeypatch):
    _create_table()
    h = _load(monkeypatch)
    assert h._backoff_seconds(0) == 30
    assert h._backoff_seconds(1) == 60
    assert h._backoff_seconds(2) == 120
    assert h._backoff_seconds(20) == 900  # capped
