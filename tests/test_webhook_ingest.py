"""Tests for the webhook-ingest pattern.

Two layers: the pure HMAC ``verify_signature`` module, and the SQS consumer
handler (which fetches the signing key from Secrets Manager via moto and verifies
each record before processing).
"""

from __future__ import annotations

import json

import boto3
import pytest
from moto import mock_aws

from conftest import load_pattern_module

SECRET = b"super-secret-key"


def _sign(body: bytes) -> str:
    """Reference HMAC-SHA256 hex signature, independent of the module under test."""
    import hashlib
    import hmac

    return hmac.new(SECRET, body, hashlib.sha256).hexdigest()


# --------------------------------------------------------------------------- #
# verify_signature — pure HMAC
# --------------------------------------------------------------------------- #

@pytest.fixture
def vs():
    return load_pattern_module("webhook-ingest", "verify_signature")


def test_compute_signature_is_deterministic(vs):
    a = vs.compute_signature(SECRET, b"hello", "sha256")
    b = vs.compute_signature(SECRET, b"hello", "sha256")
    assert a == b and len(a) == 64


def test_verify_accepts_valid_signature(vs):
    body = b'{"event":"ping"}'
    sig = vs.compute_signature(SECRET, body, "sha256")
    assert vs.verify(secret=SECRET, body=body, provided_signature=sig, algorithm="sha256") is True


def test_verify_rejects_tampered_body(vs):
    sig = vs.compute_signature(SECRET, b"original", "sha256")
    assert vs.verify(secret=SECRET, body=b"tampered", provided_signature=sig, algorithm="sha256") is False


def test_verify_handles_prefix(vs):
    body = b"payload"
    sig = vs.compute_signature(SECRET, body, "sha256")
    assert vs.verify(secret=SECRET, body=body, provided_signature=f"sha256={sig}", algorithm="sha256", prefix="sha256=") is True
    # Wrong scheme prefix -> failed verification (not an error).
    assert vs.verify(secret=SECRET, body=body, provided_signature=sig, algorithm="sha256", prefix="sha256=") is False


def test_verify_unsupported_algorithm_raises(vs):
    with pytest.raises(vs.SignatureError):
        vs.compute_signature(SECRET, b"x", "md5")


def test_verify_empty_signature_raises(vs):
    with pytest.raises(vs.SignatureError):
        vs.verify(secret=SECRET, body=b"x", provided_signature="")


# --------------------------------------------------------------------------- #
# handler — SQS consumer with Secrets Manager (moto)
# --------------------------------------------------------------------------- #

def _load_handler(monkeypatch):
    secrets = boto3.client("secretsmanager", region_name="us-east-1")
    arn = secrets.create_secret(Name="webhook-key", SecretString=SECRET.decode())["ARN"]
    monkeypatch.setenv("SECRET_ARN", arn)
    monkeypatch.setenv("SIGNATURE_ALGORITHM", "sha256")
    monkeypatch.setenv("SIGNATURE_PREFIX", "")
    return load_pattern_module("webhook-ingest", "handler")


def _record(message_id: str, body: str, signature: str, source: str = "github") -> dict:
    return {
        "messageId": message_id,
        "body": body,
        "messageAttributes": {
            "source": {"stringValue": source, "dataType": "String"},
            "signature": {"stringValue": signature, "dataType": "String"},
        },
    }


@mock_aws
def test_valid_signature_is_processed(monkeypatch):
    handler = _load_handler(monkeypatch)
    body = json.dumps({"event": "push"})
    sig = _sign(body.encode())

    event = {"Records": [_record("ok", body, sig)]}
    assert handler.handle(event, None) == {"batchItemFailures": []}


@mock_aws
def test_bad_signature_is_dropped(monkeypatch):
    handler = _load_handler(monkeypatch)
    body = json.dumps({"event": "push"})
    event = {"Records": [_record("forged", body, "deadbeef")]}
    # Non-retryable: dropped, not returned for retry.
    assert handler.handle(event, None) == {"batchItemFailures": []}


@mock_aws
def test_retryable_business_failure_is_reported(monkeypatch):
    handler = _load_handler(monkeypatch)
    body = json.dumps({"event": "push"})
    sig = _sign(body.encode())

    def boom(source, payload):
        raise RuntimeError("downstream unavailable")

    monkeypatch.setattr(handler, "process_event", boom)
    event = {"Records": [_record("retry-me", body, sig)]}
    assert handler.handle(event, None) == {"batchItemFailures": [{"itemIdentifier": "retry-me"}]}
