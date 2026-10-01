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
 "started_at": "2026-09-23T19:58:45.329884Z", "updated_at": "2026-09-23T19:58:55.346933Z"}
```
`phase` moves forward only: `claimed` → `setup` → `model_running` → `pushing`
→ `publishing`. If the file is present while the container is stopped, the run
was interrupted. On restart the agent resumes or recovers from this phase.
Don't delete the file without the user's agreement.

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
| `incomplete` | model ran but the final check was still red (see `final_check_failed`), or the work was only partial |
| `handoff` | cost soft threshold crossed; the model wrote `repo/.agent/handoff/<issue>.md` and a continuation run will pick it up |
| `no_changes` | model finished without changing anything |
| `infrastructure_error` | anything outside the model's work: git/workspace, setup, baseline check, SDK/runtime, publishing. Counts toward `consecutive_errors` |

A missing `outcome` (or a missing `attempt.json`) means the run is still
active or the process died. Check `state/attempt.json` and the container's
exit status or `docker compose logs`.

`model_execution_finished` in `agent_output.json` gives the model-side status:
`succeeded`, `model_limit_reached`, `infrastructure_error` or
`handoff_requested`.

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
| `provenance_verification_failed`, `git_workspace_unrecoverable`, `continuation_branch_missing`, `working_tree_dirty` | git/branch state problems in `repo/` |
| `consecutive_error_limit_reached` | stdout only. The agent has stopped picking up issues (see `state/consecutive_errors.json`) |

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
```
