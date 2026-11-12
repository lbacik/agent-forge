#!/usr/bin/env python3
"""Render a contract Status Snapshot envelope as the locate-agent summary.

Reads an `agentfleet status --json` envelope (producer envelope with
``ok:true`` and a Status Snapshot ``result``) from stdin and prints the
sections locate-agent promises: instance state and startup check, last Halt,
Intake with pending stop, stop plan and priority, current Attempt with native
phase and budget Figures, last finished Attempt, and each section's
``observed_at``. Figures show their unit and Figure Basis; unknown values
(``value: null`` with basis ``unavailable`` or ``not_applicable``) render as
``unavailable``/``not_applicable``, never ``0``. Native outcomes are shown as
the backend labels them. Exits 0 on success, 1 when stdin is not an ok
envelope (the caller reports the failure reply instead).
"""

import json
import sys


def fmt_figure(fig):
    if not isinstance(fig, dict):
        return "unavailable"
    value = fig.get("value")
    unit = fig.get("unit", "")
    basis = fig.get("basis", "")
    if not isinstance(unit, str) or not unit:
        unit = "unknown-unit"
    if not isinstance(basis, str) or not basis:
        basis = "unknown-basis"
    if value is None or isinstance(value, bool):
        text = f"{basis} (unit {unit}, basis {basis})"
    else:
        text = f"{value} {unit} (basis {basis})"
    reason = fig.get("reason")
    if isinstance(reason, str) and reason:
        text += f" - {reason}"
    return text


def main():
    try:
        envelope = json.load(sys.stdin)
    except ValueError:
        sys.stderr.write("render_status: stdin is not JSON\n")
        return 1
    if not isinstance(envelope, dict) or envelope.get("ok") is not True:
        sys.stderr.write("render_status: envelope is not ok:true\n")
        return 1
    snap = envelope.get("result")
    if not isinstance(snap, dict):
        sys.stderr.write("render_status: envelope has no result document\n")
        return 1

    lines = []
    lines.append(f"generated_at: {snap.get('generated_at', '')}")

    instance = snap.get("instance") if isinstance(snap.get("instance"), dict) else {}
    lines.append(
        f"instance: {instance.get('state', '')} "
        f"(observed_at {instance.get('observed_at', '')})"
    )
    startup = instance.get("startup_check")
    lines.append(f"startup_check: {startup if startup else 'none'}")
    halt = instance.get("last_halt")
    if isinstance(halt, dict):
        lines.append(
            f"last_halt: {halt.get('reason', '')} "
            f"at {halt.get('at', '')} - {halt.get('detail', '')}"
        )
    else:
        lines.append("last_halt: none")

    intake = snap.get("intake") if isinstance(snap.get("intake"), dict) else {}
    lines.append(
        f"intake: {intake.get('state', '')} "
        f"(observed_at {intake.get('observed_at', '')})"
    )
    pending = intake.get("pending_stop")
    if isinstance(pending, dict):
        lines.append(
            f"pending_stop: request {pending.get('request_id', '')} "
            f"sequence {pending.get('sequence', '')}"
        )
    else:
        lines.append("pending_stop: none")
    plan = intake.get("stop_plan")
    if isinstance(plan, dict):
        lines.append(
            f"stop_plan: request {plan.get('request_id', '')} "
            f"remaining {plan.get('remaining', '')} "
            f"counted {plan.get('counted', '')}"
        )
    else:
        lines.append("stop_plan: none")
    priority = intake.get("priority")
    if isinstance(priority, dict):
        lines.append(
            f"priority: request {priority.get('request_id', '')} "
            f"issue #{priority.get('issue', '')}"
        )
    else:
        lines.append("priority: none")

    current = snap.get("current_attempt")
    if current is None:
        lines.append("current_attempt: none")
    elif isinstance(current, dict):
        issue = current.get("issue") if isinstance(current.get("issue"), dict) else {}
        issue_no = issue.get("number", "")
        lines.append(
            f"current_attempt: {current.get('attempt_id', '')} "
            f"issue #{issue_no} native_phase {current.get('native_phase', '')} "
            f"(observed_at {current.get('observed_at', '')})"
        )
        budget = current.get("budget") if isinstance(current.get("budget"), dict) else {}
        if budget:
            raw = fmt_figure(budget.get("raw_tokens"))
            eff = fmt_figure(budget.get("effective_tokens"))
            enforced = budget.get("enforced_tokens", "")
            lines.append(f"budget: raw {raw}, effective {eff}, enforced: {enforced}")
            limits = budget.get("limits")
            if isinstance(limits, list) and limits:
                lines.append("budget_limits:")
                for entry in limits:
                    if not isinstance(entry, dict):
                        continue
                    name = entry.get("name", "unknown")
                    used = fmt_figure(entry.get("used"))
                    limit = fmt_figure(entry.get("limit"))
                    lines.append(f"  {name}: used {used} / limit {limit}")
        figures = current.get("figures") if isinstance(current.get("figures"), dict) else {}
        if figures:
            lines.append("budget_figures:")
            for name in sorted(figures):
                lines.append(f"  {name}: {fmt_figure(figures[name])}")
    else:
        lines.append("current_attempt: <unreadable>")

    last = snap.get("last_finished")
    if last is None:
        lines.append("last_finished: none")
    elif isinstance(last, dict):
        outcome = last.get("outcome") if isinstance(last.get("outcome"), dict) else None
        if isinstance(outcome, dict):
            lines.append(
                f"last_finished: {last.get('attempt_id', '')} "
                f"outcome {outcome.get('label', '')} "
                f"(native {outcome.get('native', '')}) "
                f"sealed={last.get('sealed', '')}"
            )
        else:
            lines.append(
                f"last_finished: {last.get('attempt_id', '')} "
                f"sealed={last.get('sealed', '')}"
            )
        issue = last.get("issue") if isinstance(last.get("issue"), dict) else {}
        if issue:
            lines.append(
                f"  issue #{issue.get('number', '')} "
                f"{issue.get('title', '') or ''}".rstrip()
            )
        lines.append(f"  finished_at {last.get('finished_at', '')}")
    else:
        lines.append("last_finished: <unreadable>")

    sys.stdout.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
