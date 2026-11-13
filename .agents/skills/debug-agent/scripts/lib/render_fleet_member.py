#!/usr/bin/env python3
"""Render one Fleet overview line from an `agentfleet status --json` envelope.

Reads the envelope on stdin; discovery fields (name, backend, contract,
duplicate) arrive as argv. On `ok:true` prints backend, Target Repository,
instance state and Intake on one line. On a failure reply or malformed
stdout prints a one-line `status unavailable` / `status unreadable` note and
exits 1 (the caller keeps listing the rest of the Fleet).
"""

import argparse
import json
import sys


def _docker_state(args):
    state = getattr(args, "state", "")
    if state:
        return " (docker %s)" % state
    return ""


def _duplicate(args):
    if getattr(args, "duplicate", "0") == "1":
        return " DUPLICATE"
    return ""


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--backend", default="")
    parser.add_argument("--contract", default="")
    parser.add_argument("--state", default="")
    parser.add_argument("--duplicate", default="0")
    parser.add_argument("--fallback-repo", default="")
    args = parser.parse_args(argv)
    try:
        envelope = json.load(sys.stdin)
    except ValueError:
        sys.stdout.write("%s%s%s: status unreadable (not JSON)\n" % (
            args.name, _docker_state(args), _duplicate(args)))
        return 1
    if not isinstance(envelope, dict):
        sys.stdout.write("%s%s%s: status unreadable (not an envelope)\n" % (
            args.name, _docker_state(args), _duplicate(args)))
        return 1
    if envelope.get("ok") is not True:
        error = envelope.get("error") if isinstance(envelope.get("error"), dict) else {}
        code = error.get("code", "unknown")
        sys.stdout.write("%s backend=%s contract=%s%s%s: status unavailable (%s)\n" % (
            args.name, args.backend or "unknown", args.contract or "?",
            _docker_state(args), _duplicate(args), code))
        return 1
    snap = envelope.get("result")
    if not isinstance(snap, dict):
        sys.stdout.write("%s: status unreadable (no result document)\n" % args.name)
        return 1
    identity = snap.get("identity") if isinstance(snap.get("identity"), dict) else {}
    backend = identity.get("backend", "") or args.backend or "unknown"
    repo = identity.get("repository", "") or getattr(args, "fallback_repo", "") or "(unknown)"
    instance = snap.get("instance") if isinstance(snap.get("instance"), dict) else {}
    intake = snap.get("intake") if isinstance(snap.get("intake"), dict) else {}
    marker = " DUPLICATE" if args.duplicate == "1" else ""
    sys.stdout.write("%s backend=%s repository=%s contract=%s instance=%s intake=%s%s\n" % (
        args.name, backend, repo, args.contract or "?",
        instance.get("state", "") or "unknown",
        intake.get("state", "") or "unknown", marker))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
