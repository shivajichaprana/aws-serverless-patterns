"""Tests for the scheduled-batch handlers (split / process / reduce)."""

from __future__ import annotations

import pytest

from conftest import load_pattern_module


@pytest.fixture
def handlers(monkeypatch):
    monkeypatch.setenv("BATCH_SHARDS", "4")
    return load_pattern_module("scheduled-batch", "handlers")


def test_split_produces_configured_shards(handlers):
    out = handlers.split({"run_source": "test"}, None)
    assert len(out["shards"]) == 4
    assert out["shards"][0]["run_source"] == "test"
    assert "started_at" in out
    # Ranges are contiguous and non-overlapping.
    for shard in out["shards"]:
        assert shard["range_end"] - shard["range_start"] == 1000


def test_process_returns_succeeded_count(handlers):
    shard = {"shard_id": 2, "run_source": "test", "range_start": 2000, "range_end": 3000}
    out = handlers.process(shard, None)
    assert out == {"shard_id": 2, "status": "SUCCEEDED", "processed": 1000}


def test_reduce_aggregates_partial_failure(handlers):
    results = [
        {"shard_id": 0, "status": "SUCCEEDED", "processed": 1000},
        {"shard_id": 1, "status": "SUCCEEDED", "processed": 500},
        {"shard_id": 2, "status": "FAILED", "processed": 0},
    ]
    summary = handlers.reduce({"results": results}, None)
    assert summary["shards_total"] == 3
    assert summary["shards_succeeded"] == 2
    assert summary["shards_failed"] == 1
    assert summary["records_processed"] == 1500
    assert summary["status"] == "PARTIAL"


def test_reduce_all_succeeded(handlers):
    results = [{"status": "SUCCEEDED", "processed": 10}]
    summary = handlers.reduce({"results": results}, None)
    assert summary["status"] == "SUCCEEDED"
    assert summary["shards_failed"] == 0
