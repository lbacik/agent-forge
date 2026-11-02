# Agent data layout (`/data` = `~/OrbStack/docker/volumes/<dir>_agent_data/`)

For a remote agent, `/data/logs/...` is read from the local cache that
`scripts/fetch-run.sh` fills, `~/.cache/simple-coding-agent-env/<ctx>/<dir>/logs/...`.
The layout below is the same.

This layout was checked against upstream simple-coding-agent
(`observability.py`, `attempt_state.py`, `operating.py`, `lifecycle.py`,
`model_execution.py`) and against the real volumes. If a file you expect is
missing, or an unfamiliar one shows up, upstream may have changed. Check the
upstream checkout (`/Volumes/Sources/python/ai/simple-coding-agent`, or
GitHub `lbacik/simple-coding-agent` main for instances that build from it)
before assuming anything.

## Contents

- [Tree](#tree)
- [State files](#state-files-datastate)
- [Attempt directory](#attempt-directory-datalogsissuestarted_at)
- [agent_output.json events](#agent_outputjson-events)
- [Diagnosing `provenance_verification_failed`](#diagnosing-provenance_verification_failed)
- [Conflict attempts (merge-conflict requeue)](#conflict-attempts-merge-conflict-requeue)
- [Diagnosing pids exhaustion (zombie processes)](#diagnosing-pids-exhaustion-zombie-processes)
- [jq recipes](#jq-recipes)

## Tree

```
/data/
├── state/
│   ├── consecutive_errors.json      # always present once the agent has run
│   ├── control.sqlite3 (+ -wal/-shm)# operator control store (agentctl commands, intake state)
│   └── attempt.json                 # ONLY while an attempt is active (deleted at the end)
├── repo/                            # working clone of TARGET_REPO (CLONE_DIR default)
│   └── .agent/handoff/<issue>.md    # handoff note written by the model (continuations)
└── logs/
    └── <issue_number>/              # one dir per GitHub issue, e.g. 45
        └── <started_at>/            # one dir per attempt, UTC, ':' -> '-'
            ├── attempt.json         # summary, written at the end
            ├── agent_output.json    # JSON-lines event stream (mirror of stdout for this issue)
            ├── setup_stdout.log / setup_stderr.log
            ├── baseline_check_stdout.log / baseline_check_stderr.log
            ├── check_stdout.log / check_stderr.log          # final check, only if the model finished
            ├── NNNN_tool_call.json / NNNN_tool_result.json  # one pair per tool use
            └── NNNN_model_response.txt                      # assistant text blocks
```

Example attempt dir: `logs/49/2026-09-22T20-07-47.012475Z/` is the attempt
that started at `2026-09-22T20:07:47.012475Z` UTC. The same value is the
attempt id in `state/*.json` (with `:`).

## State files (`/data/state/`)

`consecutive_errors.json`:
```json
{"count": 0, "last_attempt_id": "2026-09-23T09:46:23.220746Z", "last_success_at": "2026-09-23T09:55:33.355276Z"}
```
`count` goes up with every `infrastructure_error` outcome and resets to 0 on
any other outcome (which also updates `last_success_at`). When it reaches
`MAX_CONSECUTIVE_ERRORS` (default 3), the agent logs
`consecutive_error_limit_reached` to stdout and stops taking issues. If the
agent is idle and the user can't see why, check this file and
`agentctl status` first.

`control.sqlite3` is the operator control store behind `agentctl`
(upstream `control.py`). Tables: `commands` (every `agentctl` request with its
`kind`, `acknowledgement` and `detail`), `control_state` (a single row:
`intake` `running`/`stopped`, pending command, stop-after plan, requested next
issue, handoff), and `counted_attempts`. Don't open it with `sqlite3`: it's a
live WAL database, the images don't ship the CLI, and a copy without its
`-wal` file is stale. Ask the live process with `agentctl status` (and
`agentctl command <request-id>`) through `docker exec -u agent`. If the agent
is idle, `intake: stopped` there, or a pending stop plan, explains why as
often as `consecutive_errors.json` does.

`attempt.json`, the active-attempt checkpoint:
```json
{"branch": "agent/issue-44", "issue_number": 44, "phase": "model_running",
 "started_at": "2026-09-23T19:58:45.329884Z", "updated_at": "2026-09-23T19:58:55.346933Z",
 "attempt_kind": "ordinary", "requeue_source": "human"}
```
`phase` moves forward only: `claimed` → `setup` → `model_running` → `pushing`
→ `publishing`. If the file is present while the container is stopped, the run
was interrupted. On restart the agent resumes or recovers from this phase.
Don't delete the file without the user's agreement.

`attempt_kind` is `ordinary` (the model-driven implementation path) or
`conflict` (a conflict attempt that only brings the already-published
`agent/issue-N` branch up to date: rebase onto the base, setup plus one
profile check, force-push only when green, at most one narrow model
resolution session and no `code-review`). Checkpoints written before the
kind existed carry no kind and read as `ordinary`. `requeue_source` is
`human` (the issue carried `ready-for-agent` at claim), `automatic` (a
`round-finished` continuation) or `conflict` (a `merge-conflict` requeue: no
continuation index, transparent to the automatic-continuation count). Only
startup recovery of a retained conflict attempt stamps its result comment
with the `<!-- requeue-source: conflict -->` marker; an ordinary conflict
result carries no requeue-source marker.

## Attempt directory (`/data/logs/<issue>/<started_at>/`)

### `attempt.json` (summary)
```json
{"started_at": "...", "completed_at": "...", "duration_seconds": 741.9,
 "outcome": "incomplete", "model_stop_reason": "end_turn",
 "model_usage": {"<model>": {"costUSD": 9.85, "inputTokens": 1196002, "outputTokens": 33025, "...": "..."}},
 "skill_events": [{"name": "code-review", "phase": "PreToolUse", "timestamp": "..."}],
 "token_estimate_authority": "non-authoritative"}
```
`outcome` is one of:

| outcome | meaning |
|---|---|
| `complete` | work finished, final check green, published |
| `incomplete` | model ran but the final check was still red (see `final_check_failed`), or the work was only partial; also a red baseline check before the model ran (`baseline_check_failed`, not on a continuation). Resets `consecutive_errors`, which can hide [pids exhaustion](#diagnosing-pids-exhaustion-zombie-processes) |
| `handoff` | cost soft threshold crossed; the model wrote `repo/.agent/handoff/<issue>.md` and a continuation run will pick it up |
| `no_changes` | model finished without changing anything |
| `infrastructure_error` | anything outside the model's work: git/workspace, setup, a baseline check that didn't run, SDK/runtime, publishing. Counts toward `consecutive_errors` |

A missing `outcome` (or a missing `attempt.json`) means the run is still
active or the process died. Check `state/attempt.json` and the container's
exit status or `docker compose logs`.

`model_execution_finished` in `agent_output.json` gives the model-side status:
`succeeded`, `model_limit_reached`, `infrastructure_error` or
`handoff_requested`. Conflict attempts run little or no model work, so this
event may be absent; the result comment marker (see
[Conflict attempts](#conflict-attempts-merge-conflict-requeue)) is the
authoritative outcome instead.

`attempt_kind` is written to `attempt.json` at claim time for conflict
attempts (`"attempt_kind": "conflict"`) even if the checkpoint is later
lost; ordinary attempts leave the archive untouched, so a missing kind
means `ordinary` (including archives written before the kind existed).
Lifecycle outcomes for a conflict marker outcome: `success` → `complete`,
`skipped` → `no_changes`, `rebase_conflict` / `check_failed` / `model_limit`
/ `resolution_failed` / `no_change` → `incomplete` (the branch stays
published but conflicting, and the consecutive-error guard does not trip),
`setup_failed` / `error` / `push_failed` → `infrastructure_error`.

### Command logs
`setup_*`, `baseline_check_*` and `check_*` hold the concatenated stdout and
stderr of the profile's `setup:` / `check:` commands. Baseline runs `check:`
before the model starts. A red baseline means the target branch was already
broken or the environment is misconfigured, not that the model did something
wrong. The failing command and its exit code are in the matching event's
`detail`: `` `vendor/bin/phpmd src text phpmd.xml` (exit 2): <stderr> ``.
Commands run through `sh -c` with a minimal env (only `PATH` plus the
profile's `env:`), so "command not found" or "HOME not set" usually points to
the profile or Dockerfile, not the target repo.

### Numbered evidence files
`NNNN` is one counter shared by all three kinds, in the order things
happened. A call and its result are **not** always adjacent: parallel tool
calls look like `0005_call, 0006_call, 0007_result, 0008_result`.

- `NNNN_tool_call.json`: only the tool's **input** (e.g. `{"command": "..."}`
  or `{"file_path": "..."}`). **It doesn't contain the tool name.** The
  name is in `agent_output.json`: `{"event":"tool_call","detail":"Bash -> 0003_tool_call.json"}`.
- `NNNN_tool_result.json`: the tool's response. For Bash that's
  `stdout`/`stderr`/`interrupted`. The `detail` of the `tool_result` event can
  carry a short outcome hint after the filename.
- `NNNN_model_response.txt`: assistant text. The event detail shows `(chars=N)`.
- Skill calls (`skill_call` / `skill_result`, e.g. `skill:code-review`) are
  **not** written to numbered files. Their payload is inline in the event's
  `detail`.

All evidence is redacted at write time, so real secrets show up as
`[REDACTED]`. A `[REDACTED]` in a command that failed can itself be the clue:
a token got into a URL or an argument.

## agent_output.json events

Each line looks like
`{"timestamp","level","event","issue_number","phase","detail"}`, where
`phase` is the coarse process phase (`polling`, `setup`, `model_execution`, …),
not the checkpoint phase. The file only has events that carry this issue
number. Anything before the claim or between issues is only in the
container's stdout (`docker compose logs`).

Typical order in a healthy run:
`workspace_prepared` (or `workspace_reprepared` for a continuation) →
`profile_loaded` → `attempt_phase_transitioned` → `setup_started` →
`setup_succeeded` → `baseline_check_succeeded` → `model_dispatch_starting` →
`model_execution_started` → `model_usage_shape` → { `tool_call` / `tool_result`
/ `limits_checked` / `model_response` / `skill_call` / `skill_result` }* →
`model_execution_finished` → final check → push / publish (`comment_posted` …).

Events that signal trouble:

| event | where to look next |
|---|---|
| `attempt_exception` (ERROR) | `detail` = `ExceptionType: message`, e.g. `GitWorkspaceError: Base branch is unavailable in the local clone` (profile `base_branch` vs repo branches) |
| `setup_failed` | `setup_stderr.log`, the command in `detail` |
| `baseline_check_failed` | `baseline_check_*.log`. The target branch or environment is broken before the model runs |
| `final_check_failed` | `check_*.log`. The model's changes didn't turn the gate green |
| `cost_soft_threshold_crossed` / `cost_soft_threshold_handoff_context_injected` | expected before a `handoff` outcome |
| `limits_checked` | running `estimated_cost_usd`, `turns`, `elapsed_seconds` against the limits. The last one shows how close the run got |
| `provenance_verification_failed` | Startup, stdout only: see [Diagnosing `provenance_verification_failed`](#diagnosing-provenance_verification_failed) |
| `git_workspace_unrecoverable`, `continuation_branch_missing`, `working_tree_dirty` | git/branch state problems in `repo/` |
| `consecutive_error_limit_reached` | stdout only. The agent has stopped picking up issues (see `state/consecutive_errors.json`) |
| `conflict_requeue_detected` (INFO) | the detector labelled the issue `merge-conflict`: `detail` = `issue #N; pull request #M (<sha>) reports merge conflicts`. Carries the issue number, so it is in that issue's `agent_output.json` |
| `conflict_attempt_claimed` (INFO) | a `merge-conflict` claim routed to a conflict attempt: `detail` = `issue #N; merge-conflict requeue`. Expect `attempt_kind: conflict` in `state/attempt.json` and `attempt.json` |
| `conflict_escalated` (WARNING) | the attempt whose failure reached `MAX_CONFLICT_ATTEMPTS` handed the issue to a human: `detail` names the issue and `ready-for-human`. The issue's result comment carries the escalation section plus `<!-- conflict-escalation -->` |
| `conflict_escalation_failed` (WARNING) | labelling `ready-for-human` failed. The posted escalation comment still stops the streak, so the next poll requeues instead of looping |
| `archive_attempt_kind_failed` (WARNING) | `attempt_kind: conflict` could not be written to `attempt.json` at claim time. The checkpoint still carries the kind |

## Conflict attempts (merge-conflict requeue)

With `MAX_CONFLICT_ATTEMPTS=N > 0` (`.env`, default `0` disables the path with
no pull-request query) every poll reads the open pull requests and labels an
issue `merge-conflict` when its `agent/issue-N` branch reports `CONFLICTING`.
The labelled issue is claimed ahead of automatic continuations and new work;
the conflict attempt rebases the branch onto the base, runs setup plus one
profile check and force-pushes only when green, with no model call except for
one narrow resolution session after a real rebase conflict (never the
`code-review` skill). After N consecutive failed conflict attempts on one
issue the agent adds `ready-for-human` and never removes it; a human removing
it requeues the issue with the full budget.

### Detection

The detector (`conflict_requeue_detected`, upstream `github_tracker.py`)
labels only an open, unassigned issue with a non-empty body and no open
blocker that carries none of the queue labels (`ready-for-agent`,
`round-finished`, `ready-for-human`, `merge-conflict`); an already-queued
issue is never relabelled and `ready-for-human` is never labelled by the
detector. The pull request must be open, non-draft and report `CONFLICTING`:
`UNKNOWN` (GitHub still computing mergeability) is skipped this poll and a
draft never qualifies. A human may also apply `merge-conflict` by hand. The
detector never counts any budget and never removes the label; the claim
snapshot clears a stale `merge-conflict` when the issue is claimed through
the ordinary or continuation path instead (an issue carrying
`ready-for-agent` or `round-finished` alongside `merge-conflict` takes that
path, never the conflict attempt).

A conflicting PR that was not requeued is therefore one of: the setting is
`0`; the PR reports `UNKNOWN` or is a draft / not `CONFLICTING`; the issue
is assigned, has an empty body or an open blocker, or carries a precedence
label (`ready-for-agent`, `round-finished`, `ready-for-human` or the label
already); the issue carries `ready-for-human` (out of scope for detection
and claiming until a human removes it). With a pool of workers sharing one
login, `PEER_LOGINS` decides whose conflict comments count toward the budget.

### Attempt and result comment

A conflict claim emits `conflict_attempt_claimed` and checkpoints
`attempt_kind: conflict` with `requeue_source: conflict`. The attempt dir
carries the same `attempt_kind` in its `attempt.json` (see above). A run
interrupted by a restart recovers as a conflict error (`error` outcome,
`requeue-source: conflict` marker), never as an ordinary result, so the
streak keeps counting; an ordinary marker would stop it.

Every conflict attempt posts exactly one `## Conflict Attempt Result:
<outcome>` comment carrying the `<!-- agent-attempt: <started_at> -->`
dedup marker and the conflict-attempt marker:

`<!-- conflict-attempt: outcome=<outcome> sha=<sha|none> [reason=<reason>] [files=<a,b>] [fix_commits=<x,y>] [extra_files=<p,q>] -->`

Marker outcomes: `success` (rebased, checked and pushed as `<sha>`),
`skipped` (entry check, with a `reason`), and the failure kinds
`rebase_conflict`, `check_failed`, `setup_failed`, `error`, `push_failed`,
`model_limit` (the single resolution session hit its turn/time/token limit),
`resolution_failed` (the resolution rewrote the PR's own commits instead of
adding fixes on top), and `no_change` (a `success`-path push that left the
remote head unchanged: clean rebase plus green check, but nothing new
reached the pull request). `skipped` reasons: `no_open_pr` (no open PR for
the branch), `draft` (never publishes draft work), `not_conflicting` (the
re-read PR no longer reports `CONFLICTING`), `base_mismatch` (the PR targets
another base). Only `success` with a new `<sha>` pushes; every other outcome
leaves the remote branch untouched so the pull request stays `CONFLICTING`.
A `success` marker with `sha=none` counts as a failure toward the streak.
Note the singular/plural split: the marker outcome is `no_change`, while
the lifecycle outcome for a `skipped` marker is `no_changes`.

Every result carries the `**Conflict attempts**: k/N` standing line (omitted
only when the budget is `0`). The visible header names the conflict outcome,
not the lifecycle outcome; the lifecycle outcome mapping is in
[`attempt.json`](#attempt-directory-datalogsissuestarted_at).

### Standing and escalation

The streak is derived newest-first from the agent's own result comments (plus
pool-peer logins): consecutive failures count, and it stops at a pushed-sha
`success`, a `skipped` result, an ordinary attempt result, or the latest
`<!-- conflict-escalation -->` comment. The budget is enforced at escalation
time, never at claim time, so lowering N escalates on the next failure.

The attempt whose failure reaches N escalates exactly once: its own comment
gains the `### Human handoff` section (the failure tail or reason in a
collapsed section, a link to the pull request, and the line telling the
human to remove `ready-for-human` for N more attempts) plus the hidden
`<!-- conflict-escalation -->` marker, the issue gains `ready-for-human`,
and `agent_output.json` gains `conflict_escalated` (WARNING). A label failure
is `conflict_escalation_failed` (WARNING) but the posted escalation comment
still stops the streak. Removing `ready-for-human` requeues with the full
budget; the agent never removes it. How far the issue is from escalation is
`N - k` from the newest comment's `k/N` line (a `0/N` success or `skipped`
reset the count; check the marker when the line is absent at budget `0`).

## Diagnosing `provenance_verification_failed`

The agent refuses to start when the installed runtime differs from the pinned
one (upstream `provenance.py`, emitted from `__main__.py`). Since upstream PR
#189 the pinned runtime is the `claude-agent-sdk` release that upstream's
`pyproject.toml` pins plus the Claude Code CLI bundled inside it
(`claude_agent_sdk/_bundled/claude`); a CLI on `PATH` is neither run nor
checked, and `CLAUDE_CODE_VERSION` has no effect. Typical `detail`:
`Claude Agent SDK version does not match the pinned runtime`,
`Bundled Claude Code CLI is missing at <path>; the pinned runtime cannot be verified`
or `Claude Code CLI version does not match the pinned runtime`. The event has
no issue number, so it exists only in container stdout, phase `startup`; the
container then exits or restarts, so no attempt dir exists.

```bash
cd agent-instances/agent-<name>
docker compose logs --tail 50 agent | grep provenance_verification_failed
```

All commands below are read-only and work on a stopped container: they run a
throwaway container of the instance's image (the `image` line of the resolver
output; add `DOCKER_CONTEXT=<ctx>` for a remote context).

### Version comparison

```bash
IMG=<image>   # from locate-agent.sh

# 1. Installed SDK and the bundled CLI it ships (expected vs actual binary)
docker run --rm --entrypoint sh $IMG -c '
  pip show claude-agent-sdk | grep -i ^version
  python -c "import claude_agent_sdk as s, claude_agent_sdk._cli_version as v; print(s.__file__); print(\"expected cli:\", v.__cli_version__)"
  "$(python -c "import claude_agent_sdk as s, pathlib; print(pathlib.Path(s.__file__).parent / \"_bundled\" / \"claude\")")" --version'

# 2. Expected SDK: the container environment wins ...
docker compose config | grep -E 'CLAUDE_AGENT_SDK_VERSION'
grep -E 'CLAUDE_AGENT_SDK_VERSION' .env
# ... otherwise upstream's pin at the ref the image was built from
docker run --rm --entrypoint sh $IMG -c 'grep -n "claude-agent-sdk" /app/pyproject.toml'
```

If `/app` lacks `pyproject.toml`, read it from GitHub
`lbacik/simple-coding-agent` at the `AGENT_SRC_REF` the image was built from.

### Timeline check

Compare when the image was built with when the instance files last changed:

```bash
docker image inspect --format '{{.Created}}' $IMG
ls -l --time-style=full-iso .env Dockerfile 2>/dev/null || stat -f '%Sm %N' .env Dockerfile
```

A `.env` or Dockerfile newer than the image means the image is stale.

### Usual causes and fixes

| Cause | Sign | Owner | Fix |
|---|---|---|---|
| `.env` changed without a rebuild | `.env` newer than image; installed differs from env | instance | `docker compose build`, then `up -d` |
| Instance-level SDK pin | `CLAUDE_AGENT_SDK_VERSION` in `.env`/compose, or a `pip install claude-agent-sdk==X` in the Dockerfile, differs from upstream's `pyproject.toml` pin | instance | Remove the instance pin; upstream's pin is the only source. Rebuild |
| Bundled CLI missing | `_bundled/claude` absent: the SDK came from a source distribution or a platform without a bundled binary | instance / upstream | Check that pip installed a platform wheel for the image's architecture; rebuild |
| Instance Dockerfile predates upstream PR #189 | Build fails with `cannot determine claude-code version`, or the image still installs `@anthropic-ai/claude-code` and its entrypoint sources `/etc/agent-runtime.env` | instance | Realign the Dockerfile, compose file and `.env` with the current `create-agent` templates; rebuild |

## Diagnosing pids exhaustion (zombie processes)

Without an init process the agent itself is PID 1. Processes orphaned by the
model's tool commands are reparented to it, and it never reaps them. The
zombies count toward the container cgroup's `pids.max`. Once that is reached,
every fork or thread spawn fails with `EAGAIN`, and each attempt fails within
seconds, each one in a different place. The leak grows only while the model
works; the zombies are mostly `git` and `sh`, all with `PPid: 1`. See
agent-forge #9.

Signs in the runs:

- several short runs in a row (seconds, not minutes) on different issues
- `model_execution_finished`: `Claude SDK execution failed: ProcessError`,
  stdout `Command failed with exit code -6`
- `attempt_exception`: `GitWorkspaceError: Git command failed`
- `setup_*`, `baseline_check_*` or `check_*` logs: `Resource temporarily
  unavailable`, `EAGAIN`, `code: 11`, `failed to spawn thread`,
  `fork: retry`

A red baseline ends as `incomplete`, which resets `consecutive_errors`. The
circuit breaker may therefore never trip, and the agent keeps claiming
`ready-for-agent` issues and failing them.

Confirm on the running container, in one call (add `DOCKER_CONTEXT=<ctx>` for
a remote context). The paths are for cgroup v2:

```bash
docker exec -u agent <container> sh -c '
  cat /sys/fs/cgroup/pids.current /sys/fs/cgroup/pids.max
  grep -l "^State:.Z" /proc/[0-9]*/status | wc -l
  tr "\0" " " </proc/1/cmdline; echo'
docker inspect --format '{{.HostConfig.Init}}' <container>
```

Exhaustion: `pids.current` is close to `pids.max`, the zombie count is in
the thousands, PID 1 is the agent (`python -m simple_coding_agent`)
instead of `/sbin/docker-init`, and `HostConfig.Init` is `<nil>` or `false`.
A `docker exec` that itself fails with `resource temporarily unavailable`
points the same way. With an init a few transient zombies are normal.

Cause and fix belong to the instance: its `compose.yaml` lacks `init: true` on
the `agent` service (the create-agent template has it). Add it and recreate
the container with `docker compose up -d`; no rebuild is needed. Only PID 1
can reap the zombies: a restart clears them, but only recreation applies the
fix. Both interrupt an active attempt, so do either only with the user's
approval.

## jq recipes

Set `A=~/OrbStack/docker/volumes/<dir>_agent_data/logs/<issue>/<started_at>` first
(remote: the path `fetch-run.sh` printed).

```bash
# event histogram
jq -r .event $A/agent_output.json | sort | uniq -c | sort -rn

# everything that isn't routine tool traffic
jq -c 'select(.event|test("^(tool_call|tool_result|limits_checked)$")|not)' $A/agent_output.json

# errors/warnings only
jq -c 'select(.level!="INFO")' $A/agent_output.json

# which tool each numbered file belongs to
jq -r 'select(.event=="tool_call")|.detail' $A/agent_output.json

# all Bash commands the model ran, in order
for f in $(jq -r 'select(.event=="tool_call" and (.detail|startswith("Bash ")))|.detail|sub(".*-> ";"")' $A/agent_output.json); do
  printf '%s: ' "$f"; jq -r .command "$A/$f"; done

# last cost/turn reading
jq -r 'select(.event=="limits_checked")|.detail' $A/agent_output.json | tail -1

# outcomes of every run of one issue (cross-run: only after the user agreed;
# remote: run `fetch-run.sh ... <issue> all` first and loop over the cache dir)
for d in ~/OrbStack/docker/volumes/<dir>_agent_data/logs/<issue>/*/; do
  printf '%s ' "$(basename $d)"; jq -r '.outcome // "<none>"' $d/attempt.json 2>/dev/null || echo '<no attempt.json>'; done

# conflict attempts: kind and outcome per run (missing kind means ordinary)
for d in ~/OrbStack/docker/volumes/<dir>_agent_data/logs/<issue>/*/; do
  printf '%s ' "$(basename $d)"; jq -r '"\(.outcome // "<none>") kind=\(.attempt_kind // "ordinary")"' $d/attempt.json 2>/dev/null || echo '<no attempt.json>'; done

# conflict detector and escalation events for one run
jq -c 'select(.event=="conflict_requeue_detected" or .event=="conflict_attempt_claimed" or .event=="conflict_escalated" or .event=="conflict_escalation_failed")' $A/agent_output.json

# active checkpoint kind and requeue source (only while an attempt is active)
jq -r '{attempt_kind, requeue_source, phase, issue_number}' ~/OrbStack/docker/volumes/<dir>_agent_data/state/attempt.json

# conflict-attempt markers in the issue's GitHub comments (needs gh; newest first)
# outcome/sha/reason/files/fix_commits/extra_files, plus the escalation marker that stops the streak
gh issue view <issue> --repo <owner>/<repo> --comments --json comments -q '.comments[].body' | grep -o '<!-- conflict-attempt:[^>]*-->'
gh issue view <issue> --repo <owner>/<repo> --comments --json comments -q '.comments[].body' | grep -c '<!-- conflict-escalation -->'
```
