#!/usr/bin/env python3
"""Render one `agentfleet attempts ls --json` page as the issue's Attempts.

Reads a producer envelope (``ok:true`` with an Attempts list ``result``) from
a file and prints the Attempts whose ``issue.number`` matches the given issue
number, newest first (the list order is kept). Each line names the native
Attempt ID, the native outcome, the delivery, ``attention_required`` and
``sealed``. With ``--ids-only`` it prints just the matching native Attempt
IDs, one per line, for the caller's report line.

Unsealed archives are labelled as moving snapshots: they change while the
Attempt runs and are fetched again on every request, never served from cache.

Exits 0 on success (an empty match prints ``none`` and still exits 0), 1 when
the file is not an ok envelope (the caller reports the failure reply instead).
"""

import json
import sys


def render_delivery(delivery):
    if not isinstance(delivery, dict):
        return "none"
    pr = delivery.get("pull_request")
    if isinstance(pr, dict):
        return "PR #{} {}".format(pr.get("number", ""), pr.get("url", "")).rstrip()
    return "none"


def render_bool(value):
    if value is True:
        return "true"
    if value is False:
        return "false"
    return str(value)


def render_attempt(entry):
    attempt_id = entry.get("attempt_id", "")
    issue = entry.get("issue") if isinstance(entry.get("issue"), dict) else {}
    outcome = entry.get("outcome")
    if outcome is None:
        outcome_text = "none (still open)"
    elif isinstance(outcome, dict):
        outcome_text = "{} ({})".format(
            outcome.get("native", ""), outcome.get("label", "")
        )
    else:
        outcome_text = "unreadable"
    sealed = entry.get("sealed")
    if sealed is True:
        sealed_text = "true (Sealed)"
    elif sealed is False:
        sealed_text = "false (moving snapshot: unsealed, fetched again on every request)"
    else:
        sealed_text = "unknown"
    attention = render_bool(entry.get("attention_required", ""))
    return (
        "attempt {}: issue #{} lifecycle {} native_outcome {} "
        "delivery {} attention_required {} sealed {}".format(
            attempt_id,
            issue.get("number", ""),
            entry.get("lifecycle_state", ""),
            outcome_text,
            render_delivery(entry.get("delivery")),
            attention,
            sealed_text,
        )
    )


def main(argv):
    ids_only = False
    rest = []
    for arg in argv:
        if arg == "--ids-only":
            ids_only = True
        else:
            rest.append(arg)
    if len(rest) != 2:
        sys.stderr.write("usage: render_attempts.py [--ids-only] <issue> <page.json>\n")
        return 2
    try:
        issue = int(rest[0])
    except ValueError:
        sys.stderr.write("render_attempts: issue is not a number\n")
        return 2
    try:
        with open(rest[1], encoding="utf-8") as handle:
            envelope = json.load(handle)
    except (OSError, ValueError) as exc:
        sys.stderr.write("render_attempts: cannot read page: {}\n".format(exc))
        return 1
    if not isinstance(envelope, dict) or envelope.get("ok") is not True:
        sys.stderr.write("render_attempts: page is not an ok:true envelope\n")
        return 1
    result = envelope.get("result")
    if not isinstance(result, dict):
        sys.stderr.write("render_attempts: page has no result document\n")
        return 1
    attempts = result.get("attempts")
    if not isinstance(attempts, list):
        sys.stderr.write("render_attempts: page has no attempts list\n")
        return 1
    matched = [
        entry
        for entry in attempts
        if isinstance(entry, dict)
        and isinstance(entry.get("issue"), dict)
        and entry["issue"].get("number") == issue
    ]
    if ids_only:
        for entry in matched:
            sys.stdout.write("{}\n".format(entry.get("attempt_id", "")))
        return 0
    for entry in matched:
        sys.stdout.write(render_attempt(entry) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
