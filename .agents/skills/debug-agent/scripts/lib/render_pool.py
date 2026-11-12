#!/usr/bin/env python3
"""Render one contract-path pool-status Worker block from a Status Snapshot.

Reads an `agentfleet status --json` envelope on stdin.

`--block` prints the whole Worker block: the header from argv (worker label,
service, backend) plus one line per snapshot section the pool overview
promises (instance state, Intake with pending stop / stop plan / priority,
current issue with native phase). `last_halt` prints only when present.
Every section carries its `observed_at`; unknown values are already rendered
by the producer and are passed through unchanged.

`--meta` prints one machine line for the caller's records:
`backend|active|phase|mode` (`-` for missing values).

Exits 0 on `ok:true`, 1 otherwise (the caller reports the failure reply).
"""

import argparse
import json
import sys


def _pad(label):
    return "  %s%s" % (label.ljust(21), "")


def _line(label, value):
    return "%s%s" % (_pad(label + ":"), value)


def _ref(doc, *keys):
    for key in keys:
        if not isinstance(doc, dict):
            return None
        doc = doc.get(key)
    return doc


def _cmdref(ref):
    if not isinstance(ref, dict):
        return "none"
    request = ref.get("request_id", "")
    if "sequence" in ref:
        return "request %s sequence %s" % (request, ref.get("sequence", ""))
    if "remaining" in ref or "counted" in ref:
        return "request %s remaining %s counted %s" % (
            request, ref.get("remaining", ""), ref.get("counted", ""))
    if "issue" in ref:
        return "request %s issue #%s" % (request, ref.get("issue", ""))
    return "request %s" % request


def _load_envelope():
    try:
        envelope = json.load(sys.stdin)
    except ValueError:
        sys.stderr.write("render_pool: stdin is not JSON\n")
        return None
    if not isinstance(envelope, dict) or envelope.get("ok") is not True:
        sys.stderr.write("render_pool: envelope is not ok:true\n")
        return None
    snap = envelope.get("result")
    if not isinstance(snap, dict):
        sys.stderr.write("render_pool: envelope has no result document\n")
        return None
    return snap


def _snapshot_texts(snap):
    identity = snap.get("identity") if isinstance(snap.get("identity"), dict) else {}
    backend = identity.get("backend", "") or ""
    mode = identity.get("mode", "") or ""
    lines = []
    instance = snap.get("instance") if isinstance(snap.get("instance"), dict) else {}
    lines.append(_line("instance", "%s (observed_at %s)" % (
        instance.get("state", ""), instance.get("observed_at", ""))))
    halt = instance.get("last_halt")
    if isinstance(halt, dict):
        lines.append(_line("last_halt", "%s at %s - %s" % (
            halt.get("reason", ""), halt.get("at", ""), halt.get("detail", ""))))
    intake = snap.get("intake") if isinstance(snap.get("intake"), dict) else {}
    lines.append(_line("intake", "%s (observed_at %s)" % (
        intake.get("state", ""), intake.get("observed_at", ""))))
    lines.append(_line("pending_stop", _cmdref(intake.get("pending_stop"))))
    lines.append(_line("stop_plan", _cmdref(intake.get("stop_plan"))))
    lines.append(_line("priority", _cmdref(intake.get("priority"))))
    current = snap.get("current_attempt")
    if current is None:
        lines.append(_line("current_attempt", "none"))
        active, phase = "-", "-"
    elif isinstance(current, dict):
        issue = current.get("issue") if isinstance(current.get("issue"), dict) else {}
        number = issue.get("number", "")
        active = str(number) if number != "" else "-"
        phase = current.get("native_phase", "") or "-"
        lines.append(_line("current_attempt", "%s issue #%s native_phase %s (observed_at %s)" % (
            current.get("attempt_id", ""), active, phase, current.get("observed_at", ""))))
    else:
        lines.append(_line("current_attempt", "<unreadable>"))
        active, phase = "-", "-"
    return backend, active, phase, mode, lines


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--block", action="store_true")
    parser.add_argument("--meta", action="store_true")
    parser.add_argument("--worker-label", default="")
    parser.add_argument("--service", default="")
    parser.add_argument("--managed", default="")
    parser.add_argument("--container", default="")
    parser.add_argument("--cstate", default="")
    parser.add_argument("--offline", default="0")
    args = parser.parse_args(argv)
    snap = _load_envelope()
    if snap is None:
        return 1
    backend, active, phase, mode, lines = _snapshot_texts(snap)
    if args.meta:
        sys.stdout.write("%s|%s|%s|%s\n" % (backend or "-", active, phase, mode or "-"))
        return 0
    backend_text = backend or "unknown"
    sys.stdout.write("%s service=%s backend=%s:\n" % (
        args.worker_label, args.service, backend_text))
    sys.stdout.write("%s\n" % _line("container", "%s [%s]" % (args.container, args.cstate)))
    if args.offline == "1":
        sys.stdout.write("%s\n" % _line(
            "offline_read", "yes (stopped container read without starting it)"))
    for text in lines:
        sys.stdout.write("%s\n" % text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
