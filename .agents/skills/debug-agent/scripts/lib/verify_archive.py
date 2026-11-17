#!/usr/bin/env python3
"""Verify a cached Attempt Archive against its export manifest.

Reads ``manifest.json`` (the first member of an ``attempts export`` tar:
``{"contract", "attempt", "files"}`` with ManifestEntry records holding
``path``, ``size`` and ``sha256``) in an archive directory and checks every
listed file's size and ``sha256``. Prints ``verified`` and exits 0 when all
match, prints the first mismatch and exits 1 otherwise.

With ``--sealed-at <timestamp>`` (the ``sealed_at`` that ``attempts show``
reports for a Sealed Attempt) it also checks that the cached manifest is itself
the Sealed archive: its ``attempt.sealed`` is ``true`` and its
``attempt.sealed_at`` is a non-empty string equal to ``<timestamp>``. A cached
moving snapshot of an Attempt that was Sealed since is internally consistent,
so only this check tells it apart; it fails with its own reason, separate from
a ``sha256`` mismatch.

The caller refetches (a torn read fetched again) or reuses the cache based on
this verdict: a cached copy is reused only when ``attempts show`` reports the
Attempt Sealed and this script verifies it with ``--sealed-at``.
"""

import hashlib
import json
import os
import sys


USAGE = "usage: verify_archive.py [--sealed-at <timestamp>] <archive-dir>\n"


def main(argv):
    sealed_at = None
    if argv[:1] == ["--sealed-at"]:
        if len(argv) < 2 or not argv[1]:
            sys.stderr.write(USAGE)
            return 2
        sealed_at = argv[1]
        argv = argv[2:]
    if len(argv) != 1:
        sys.stderr.write(USAGE)
        return 2
    root = argv[0]
    manifest_path = os.path.join(root, "manifest.json")
    try:
        with open(manifest_path, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, ValueError) as exc:
        sys.stderr.write("verify_archive: cannot read manifest.json: {}\n".format(exc))
        return 1
    files = manifest.get("files") if isinstance(manifest, dict) else None
    if not isinstance(files, list):
        sys.stderr.write("verify_archive: manifest.json has no files list\n")
        return 1
    attempt = manifest.get("attempt") if isinstance(manifest, dict) else None
    if not isinstance(attempt, dict):
        attempt = {}
    attempt_id = attempt.get("attempt_id", "")
    if sealed_at is not None:
        cached_sealed = attempt.get("sealed")
        cached_sealed_at = attempt.get("sealed_at")
        if cached_sealed is not True or not isinstance(cached_sealed_at, str) \
                or cached_sealed_at != sealed_at:
            sys.stderr.write(
                "verify_archive: attempt {} manifest is not the Sealed archive "
                "(sealed {!r}, sealed_at {!r}, expected sealed_at {!r})\n".format(
                    attempt_id, cached_sealed, cached_sealed_at, sealed_at
                )
            )
            return 1
    for entry in files:
        if not isinstance(entry, dict):
            sys.stderr.write("verify_archive: manifest has an unreadable entry\n")
            return 1
        rel = entry.get("path", "")
        if not isinstance(rel, str) or not rel or rel.startswith("/") or ".." in rel.split("/"):
            sys.stderr.write("verify_archive: manifest lists an unsafe path: {!r}\n".format(rel))
            return 1
        full = os.path.join(root, rel)
        try:
            with open(full, "rb") as handle:
                content = handle.read()
        except OSError:
            sys.stderr.write(
                "verify_archive: attempt {} is missing {}\n".format(attempt_id, rel)
            )
            return 1
        digest = hashlib.sha256(content).hexdigest()
        if len(content) != entry.get("size") or digest != entry.get("sha256"):
            sys.stderr.write(
                "verify_archive: attempt {} file {} does not match its manifest sha256\n".format(
                    attempt_id, rel
                )
            )
            return 1
    sys.stdout.write("verified\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
