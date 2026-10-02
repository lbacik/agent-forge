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
| `provenance_verification_failed` | Startup, stdout only: see [Diagnosing `provenance_verification_failed`](#diagnosing-provenance_verification_failed) |
| `git_workspace_unrecoverable`, `continuation_branch_missing`, `working_tree_dirty` | git/branch state problems in `repo/` |
| `consecutive_error_limit_reached` | stdout only. The agent has stopped picking up issues (see `state/consecutive_errors.json`) |

## Diagnosing `provenance_verification_failed`

The agent refuses to start when the installed runtime differs from the pinned
one (upstream `provenance.py`, emitted from `__main__.py`). Typical `detail`:
`Claude Agent SDK version does not match the pinned runtime` or
`Claude Code CLI version does not match the pinned runtime`. The event has no
issue number, so it exists only in container stdout, phase `startup`; the
container then exits or restarts, so no attempt dir exists.

```bash
cd agent-instances/agent-<name>
docker compose logs --tail 50 agent | grep provenance_verification_failed
```

All commands below are read-only and work on a stopped container: they run a
throwaway container of the instance's image (the `image` line of the resolver
output; add `DOCKER_CONTEXT=<ctx>` for a remote context).

### Three-way version comparison

```bash
IMG=<image>   # from locate-agent.sh

# 1. Installed in the image
docker run --rm --entrypoint sh $IMG -c \
  'pip show claude-agent-sdk | grep -i ^version; claude --version'

# 2. Expected by the agent: the container environment wins ...
docker compose config | grep -E 'CLAUDE_(AGENT_SDK|CODE)_VERSION'
grep -E 'CLAUDE_(AGENT_SDK|CODE)_VERSION' .env
# ... otherwise upstream config.py defaults at the ref the image was built from
docker run --rm --entrypoint sh $IMG -c \
  'grep -rn "_DEFAULT_CLAUDE_" "$(python -c "import simple_coding_agent.config as c; print(c.__file__)")"'

# 3. Pinned by upstream: SDK in pyproject.toml, CLI in package.json
docker run --rm --entrypoint sh $IMG -c \
  'grep -n "claude-agent-sdk" /app/pyproject.toml; grep -n "claude-code" /app/package.json /app/Dockerfile'
```

If `/app` lacks those files, read them from GitHub `lbacik/simple-coding-agent`
at the `AGENT_SRC_REF` the image was built from. The mismatching pair is the
one where "installed" differs from "expected".

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
| Instance-level SDK pin silently overridden by upstream's exact `pyproject.toml` pin | The Dockerfile's `pip install claude-agent-sdk==X` runs, then installing `/app` re-resolves the SDK to upstream's version; installed = upstream pin, env/Dockerfile say X | instance | Align `CLAUDE_AGENT_SDK_VERSION` (and the Dockerfile pin) with upstream's `pyproject.toml` pin, or install the agent first and pin afterwards; rebuild |
| Upstream's own claude-code sources disagree (`package.json` / Dockerfile vs `config.py`) | Upstream `package.json`/Dockerfile CLI version differs from `config.py` default, and the instance sets no env | upstream | Short term, set both `CLAUDE_*_VERSION` in the instance `.env` and install the matching CLI; rebuild. Real fix: align the sources in `simple-coding-agent` |

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
