"""Shared pytest fixtures and helpers for the pattern handler tests.

Each pattern keeps its Lambda source under ``patterns/<name>/src`` and uses flat
sibling imports (e.g. ``from store import SagaStore``). Several patterns reuse the
same file names (``store.py``, ``errors.py``, ``handlers.py``), so importing more
than one in a single test session would collide in ``sys.modules``.

:func:`load_pattern_module` isolates each import: it purges any cached sibling
modules left by a previously-loaded pattern and puts the target pattern's ``src``
directory at the front of ``sys.path`` before (re)importing, so the module's own
sibling imports resolve against the correct pattern.
"""

from __future__ import annotations

import importlib
import sys
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PATTERNS_DIR = REPO_ROOT / "patterns"

# Module names that appear in more than one pattern's src directory.
_SIBLING_NAMES = {"handlers", "handler", "store", "errors", "verify_signature", "worker"}


def load_pattern_module(pattern: str, module: str) -> Any:
    """Import ``module`` from ``patterns/<pattern>/src`` in isolation.

    Args:
        pattern: Pattern directory name under ``patterns/``.
        module: Top-level module name to import from that pattern's ``src`` dir.

    Returns:
        The freshly imported module object.
    """
    src = (PATTERNS_DIR / pattern / "src").resolve()
    if not src.is_dir():
        raise FileNotFoundError(f"no src dir for pattern {pattern!r}: {src}")

    # Drop sibling modules cached from another pattern so their names re-resolve.
    for name in list(sys.modules):
        if name in _SIBLING_NAMES:
            del sys.modules[name]

    src_str = str(src)
    while src_str in sys.path:
        sys.path.remove(src_str)
    sys.path.insert(0, src_str)

    sys.modules.pop(module, None)
    return importlib.import_module(module)


@pytest.fixture
def load_module():
    """Expose :func:`load_pattern_module` to tests that import lazily (e.g. inside
    a moto context, after the required environment variables are set)."""
    return load_pattern_module


@pytest.fixture(autouse=True)
def _aws_environment(monkeypatch):
    """Set dummy AWS credentials + region so boto3/moto never touch real creds."""
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SECURITY_TOKEN", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("AWS_REGION", "us-east-1")


class FakeLambdaContext:
    """Minimal Lambda context stand-in for handlers/Powertools that need one."""

    function_name = "test-fn"
    memory_limit_in_mb = 256
    invoked_function_arn = "arn:aws:lambda:us-east-1:123456789012:function:test-fn"
    aws_request_id = "test-request-id"

    def get_remaining_time_in_millis(self) -> int:
        return 30000


@pytest.fixture
def lambda_context() -> FakeLambdaContext:
    """Return a reusable fake Lambda context."""
    return FakeLambdaContext()
