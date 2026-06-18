"""Lambda handlers for the scheduled-batch pattern.

Three entry points wired into a Step Functions workflow:

* ``split``   — partition the batch into N shards (fan-out work units).
* ``process`` — process a single shard; returns a per-shard result.
* ``reduce``  — aggregate every shard result into a single run summary.

The handlers are deliberately self-contained and side-effect free so the
pattern is runnable as-is; replace the marked sections with real I/O (reading a
queue/table, calling a downstream API, writing results, etc.).
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timezone
from typing import Any

LOGGER = logging.getLogger()
LOGGER.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

DEFAULT_SHARDS = int(os.environ.get("BATCH_SHARDS", "4"))


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def split(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    """Partition the run into shards consumed by the Map state.

    Each shard is a small descriptor (here, an index range). In production this
    is where you would page a source table or list S3 prefixes and bucket the
    keys into ``shard_count`` groups.
    """
    run_source = event.get("run_source", "manual")
    shard_count = DEFAULT_SHARDS

    # ---- replace with real partitioning of the work set ----
    shards = [
        {
            "shard_id": i,
            "run_source": run_source,
            "range_start": i * 1000,
            "range_end": (i + 1) * 1000,
        }
        for i in range(shard_count)
    ]

    LOGGER.info("split run_source=%s into %d shards", run_source, shard_count)
    return {"shards": shards, "started_at": _now_iso()}


def process(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    """Process one shard. Raises on failure so Step Functions retries it.

    The Map state catches a terminal failure per shard, so one failing shard
    degrades the run to partial success rather than failing the whole batch.
    """
    shard_id = event["shard_id"]
    start, end = event["range_start"], event["range_end"]

    LOGGER.info("processing shard=%s range=[%d,%d)", shard_id, start, end)
    # ---- replace with real per-shard work ----
    processed = end - start

    return {
        "shard_id": shard_id,
        "status": "SUCCEEDED",
        "processed": processed,
    }


def reduce(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    """Aggregate per-shard results into a run summary."""
    results: list[dict[str, Any]] = event.get("results", [])

    succeeded = [r for r in results if r.get("status") == "SUCCEEDED"]
    failed = [r for r in results if r.get("status") == "FAILED"]
    total_processed = sum(int(r.get("processed", 0)) for r in succeeded)

    summary = {
        "shards_total": len(results),
        "shards_succeeded": len(succeeded),
        "shards_failed": len(failed),
        "records_processed": total_processed,
        "status": "PARTIAL" if failed else "SUCCEEDED",
        "finished_at": _now_iso(),
    }
    LOGGER.info("run summary: %s", summary)
    return summary
