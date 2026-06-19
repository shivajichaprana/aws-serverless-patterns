"""HMAC signature verification for inbound webhooks.

Most webhook providers (GitHub, Stripe, Shopify, Slack, …) sign each request by
computing an HMAC of the raw request body with a shared secret and sending the
hex digest in a header. This module re-computes that digest and compares it to
the supplied value in constant time.

The verification is deliberately decoupled from the Lambda handler so it can be
unit-tested in isolation and reused by other consumers.
"""

from __future__ import annotations

import hashlib
import hmac
from typing import Final

# Digest algorithms we are willing to verify. SHA-1 is included only because some
# legacy providers still use it; prefer SHA-256 or stronger for new integrations.
_SUPPORTED_ALGORITHMS: Final[frozenset[str]] = frozenset({"sha1", "sha256", "sha512"})


class SignatureError(ValueError):
    """Raised when a signature is malformed or fails verification."""


def compute_signature(secret: bytes, body: bytes, algorithm: str = "sha256") -> str:
    """Return the lowercase hex HMAC digest of ``body`` keyed by ``secret``.

    Args:
        secret: The shared signing key, as raw bytes.
        body: The exact raw request body that the provider signed.
        algorithm: One of ``sha1``, ``sha256``, ``sha512``.

    Raises:
        SignatureError: If ``algorithm`` is not supported.
    """
    if algorithm not in _SUPPORTED_ALGORITHMS:
        raise SignatureError(f"unsupported algorithm: {algorithm!r}")
    digestmod = getattr(hashlib, algorithm)
    return hmac.new(secret, body, digestmod).hexdigest()


def verify(
    *,
    secret: bytes,
    body: bytes,
    provided_signature: str,
    algorithm: str = "sha256",
    prefix: str = "",
) -> bool:
    """Verify a provider signature against a freshly computed HMAC.

    Args:
        secret: The shared signing key, as raw bytes.
        body: The exact raw request body the provider signed.
        provided_signature: The signature header value as received, optionally
            carrying ``prefix`` (e.g. ``sha256=ab12…``).
        algorithm: HMAC digest algorithm.
        prefix: Prefix the provider prepends to the hex digest. Stripped before
            comparison; if present but missing on the input, verification fails.

    Returns:
        True if the signature is valid, False otherwise. Never raises on a simple
        mismatch — only on structurally invalid input.

    Raises:
        SignatureError: If the signature is empty or the prefix is malformed.
    """
    if not provided_signature:
        raise SignatureError("empty signature header")

    candidate = provided_signature.strip()
    if prefix:
        if not candidate.startswith(prefix):
            # Wrong scheme entirely — treat as a failed verification, not an error,
            # so the caller can log and DLQ rather than crash.
            return False
        candidate = candidate[len(prefix) :]

    expected = compute_signature(secret, body, algorithm)

    # hmac.compare_digest is constant-time, defeating timing side-channels.
    return hmac.compare_digest(candidate.lower(), expected.lower())
