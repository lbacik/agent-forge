---
name: debug-agent
description: Debug a running or finished simple-coding-agent instance from this agent-forge project (instances live in `agent-instances/agent-<name>/`). Covers why it failed an issue, what it did during a run, why it went infrastructure_error/incomplete/handoff, why setup or the baseline/final check failed, why the container keeps restarting or exited, and what's in its logs, state or working clone. Use this whenever the user names an agent (e.g. "cli", "jsonhub-api", "agent-paysubscriptions"), an issue number the agent worked on, or asks about agent logs, runs, attempts, tool calls, costs or outcomes, locally (OrbStack) or on a remote docker context — e.g. "why did the api agent fail #45", "sprawdź logi agenta paysubscriptions", "co robił agent przy issue 49 na rpi5", "agent cli się nie uruchamia" — even if they don't say "debug".
---

# debug-agent

Each `agent-instances/agent-<name>/` directory in this repo (ignored by Git) is
one Docker Compose deployment of
simple-coding-agent. It runs either locally under OrbStack or on a remote host
reached through a docker context (e.g. `rpi5`, an `ssh://` endpoint).
Everything the agent persists lives on its named volume, mounted at `/data` in
the container. Only OrbStack also exposes that volume on the host. This skill
covers finding those files, choosing which run to look at, and reading the
evidence without guessing its layout.

The detailed file layout, event names, outcomes and `jq` recipes are in
`references/log-layout.md`. Read it before you open any attempt files. The
layout isn't obvious: tool names, for example, appear only in
`agent_output.json` and never in the numbered files.

## 1. Resolve the agent

Run the bundled resolver. It finds `agent-instances/` from its own location, so
it works from any working directory (`AGENT_INSTANCES_DIR` overrides it):

```bash
.claude/skills/debug-agent/scripts/locate-agent.sh [--context <ctx>] <name-fragment> [issue-number]
```

`<name-fragment>` is the full directory name or any unambiguous part of it
(`cli`, `jsonhub-api`, `pay`). The resolver prints the agent dir, docker
context and mode (`local`/`remote`), compose project, container name, state
and image, volume, where to read `/data` from, the contents of
`state/*.json`, the issue numbers that have logs, and, if you pass an issue
number, that issue's runs with their outcomes. If the fragment is ambiguous
(e.g. `jsonhub` matches three agents), it exits with code 4 and lists the
matches. Ask the user which one they mean; don't pick for them.

If the user is already inside an `agent-instances/agent-*/` directory and names
no agent, that directory is the agent.

### Which docker context

Without `--context` the resolver uses `orbstack`, which is local mode. Pass
`--context <ctx>` when the user names a host or context ("na rpi5",
`/debug-agent rpi5 …`). The same agent directory can be deployed on several
contexts at once, with the same project, container and volume names but
completely separate runs. `agent-simple-coding-agent` issue 84, for example,
has different runs on `orbstack` and on `rpi5`. So when the user names no
context and the local volume has no runs matching what they describe, ask
which context they mean. Don't probe every context in `docker context ls`:
each one is an SSH connection, and unreachable hosts hang.

### How the names are derived (in case you need them by hand)

No `compose.yaml` sets `name:`, and no `.env` sets `COMPOSE_PROJECT_NAME`, so
the **compose project = directory name**. From that:

| Thing | Pattern | Example for `agent-instances/agent-jsonhub-cli/` |
|---|---|---|
| Volume | `<dir>_agent_data` | `agent-jsonhub-cli_agent_data` |
| Host path of `/data` (local only) | `~/OrbStack/docker/volumes/<dir>_agent_data/` | `/Users/lukasz/OrbStack/docker/volumes/agent-jsonhub-cli_agent_data/` |
| Local cache of `/data/logs` (remote) | `~/.cache/simple-coding-agent-env/<ctx>/<dir>/logs/` | `~/.cache/simple-coding-agent-env/rpi5/agent-jsonhub-cli/logs/` |
| Container | `<dir>-agent-1` | `agent-jsonhub-cli-agent-1` |
| Compose service | `agent` | `docker compose -f agent-instances/agent-jsonhub-cli/compose.yaml exec agent …` |

Always match against the `agent-instances/agent-*/` directories on disk, never against
`docker volume ls`. There are stale volumes from old project names, such as
`jsonhub-api_agent_data` (label `com.docker.compose.project=jsonhub-api`).
They hold old, unrelated runs, and a substring search like `*jsonhub-api*`
would pull them in.

## 2. Pick the access path

On a remote context, set `DOCKER_CONTEXT=<ctx>` on every `docker` and
`docker compose` command below (or pass `--context <ctx>`). Otherwise they go
to OrbStack, where a container with the same name may exist and show you the
wrong agent.

### Remote: fetch the run, then read it locally

A remote volume has no host path. Copy the run you picked (step 3) into the
local cache, then read it with Read, Grep and `jq` exactly as in local mode:

```bash
.claude/skills/debug-agent/scripts/fetch-run.sh --context <ctx> <name-fragment> <issue> [<run>|latest|all]
```

It prints the local path of each attempt dir. Use that as `$A` in the recipes
in `references/log-layout.md`. It works whether the container is running or
stopped (`docker cp`), and falls back to a throwaway container if the
container was removed. Finished runs are cached and reused. An unfinished run
(active, or the process died) is fetched again on each call. A run is about
1 MB and 160 files on average, so fetching costs one SSH round trip, not a
noticeable transfer.

Don't read a remote run file by file through `docker exec`. Every call is an
SSH round trip (about 0.3–1 s on `rpi5`), so a `jq` loop over a few hundred
tool-call files becomes minutes, and the output of every call lands in your
context. If you really need a query where the files are, send the whole
script in one `docker exec … sh -c '…'` call.

Never copy `repo/` (hundreds of MB). Read the few files you need from it with
one `docker exec -u agent -w /data/repo <container> sh -c '…'` (running
container). If the container is stopped, mount the volume read-only in a
throwaway container of the agent's own image, which is already on the host
and has `jq`:

```bash
DOCKER_CONTEXT=<ctx> docker run --rm --entrypoint sh -u agent -w /data/repo \
  -v <dir>_agent_data:/data:ro <image> -c 'git log --oneline -5; git status --short'
```

The image name is in the resolver output. The pushed branch
`agent/issue-<n>` is usually also on GitHub.

### Local: read files directly from the host path

**Default in local mode.** Use Read, Grep and `jq`
on `~/OrbStack/docker/volumes/<dir>_agent_data/...`. This works whether the
container is running, exited or crash-looping. You can grep across runs, or
across agents, in one call, and you don't run into missing tools in the image
or shell-quoting problems.

### Both modes: volume rules, live runtime, stdout

**Treat the volume as read-only.** Writing into it races with the live agent,
and files there belong to UID 1000 (`agent`), not to you. The remote cache is
only a copy, so editing it changes nothing. If
something in `/data` really has to change (e.g. clearing a stuck
`state/attempt.json`), tell the user what you would change and why, and do it
only after they agree, with the container stopped or through `docker exec`.

Use **`docker exec` / `docker compose exec`** only when you need the
container's live runtime, not its files:

- the agent's live control state: `agentctl status` (intake running or
  stopped, active attempt, pending commands, recovery, handoff). It's
  read-only, like `agentctl command`. Every other `agentctl` subcommand
  (`stop`, `resume`, `next issue`, `handoff now`, `recovery …`) changes what
  the agent does, so run those only when the user asks
- process state: whether MySQL/Redis from `agent-entrypoint.sh` are up
  (bundled-services instances: `agent-jsonhub-api`, `agent-paysubscriptions`).
  The images have no `ps`, so use `ls /proc/[0-9]*/cmdline` or the service's
  own client, e.g. `mysqladmin ping`, `redis-cli ping`
- reproducing a profile command exactly as the agent runs it: same `PATH`,
  toolchain, and the `agent` user
- paths outside `/data`, e.g. `/opt/agent-profile/`, `/var/lib/mysql`, `/tmp`

```bash
docker exec -u agent -w /data/repo agent-jsonhub-cli-agent-1 sh -c '…'
# or, from inside the agent dir:
docker compose exec -u agent agent sh -c '…'
```

Pass `-u agent` explicitly. In the bundled-services images the container's
default user is root (the entrypoint drops to `agent` via `gosu`), so a bare
`exec` would run as the wrong user and could mask permission problems.

`exec` needs a **running** container. If the container is stopped, read the
files from the host path (local) or with `fetch-run.sh` (remote). For a runtime check on a stopped instance, run
`docker compose run --rm --entrypoint sh agent` from the agent dir, but say so
first: it starts a fresh container that shares the volume.

**Container stdout: `docker compose logs`** (from the agent dir, or
`docker logs <container>`). This is the only place for events that have no
issue number: startup and runtime-version checks, polling, errors between
attempts. It's where to look when the container exits or restarts before
claiming an issue. For a `provenance_verification_failed` startup event, follow
`references/log-layout.md#diagnosing-provenance_verification_failed`.
Use `--since`/`--tail` to keep it small. The output
disappears when the container is removed (`compose down`, rebuild), and the
volume's files don't. On a remote context, check the resolver's `image` line
and the container's start time against what you expect: a container that
exited long ago may still be running an image built before the latest fix.

### Instances behind a LiteLLM gateway

An instance whose env file sets `COMPOSE_FILE=compose.yaml:compose.litellm.yaml`
sends model traffic to a LiteLLM gateway on the external network
`GATEWAY_NETWORK` (`MODEL_BASE_URL`, usually `http://litellm:4000`). Read
those keys from the instance's env file (`.env`, or the file a run was started
with via `--env-file`, e.g. `.env.litellm`) with
`grep -E '^(COMPOSE_FILE|GATEWAY_NETWORK|MODEL_BASE_URL|MODEL_NAME)=' <file>`,
never the whole file. The overlay doesn't change the compose project,
container or volume names.

For backend failures (401, unknown model, model mismatch, timeouts, a
container that can't resolve `litellm`), check the gateway's side too, on the
same docker context: `docker network inspect <GATEWAY_NETWORK>` shows whether
the agent and the gateway are attached, and `docker logs --since <run start>
<gateway container>` shows the request from the gateway's view. Compare a low
`prompt_cache.main_hit_rate` in `token_budget_reconciled`, or a
`prompt_cache_ineffective` warning, with an earlier good run: caching depends on
the gateway's LiteLLM version (`LITELLM_VERSION`), so check whether its image
tag changed. The gateway
is separate shared infrastructure; don't restart or reconfigure it without the
user's approval, and report gateway-side causes as such.

## 3. Choose which run(s) to inspect

Every attempt gets its own directory, `logs/<issue>/<started_at>/`. One issue
often has several runs (retries, continuations after handoff), so the user's
wording may not pin down a single run. Decide as follows:

- **One run clearly identified**: an issue with a single run, or an issue plus
  a time or date that matches one run, or "the last/latest/current run".
  Go ahead. "Current" means the run in `state/attempt.json` if one exists.
- **More than one run could match**: an agent named but no issue, an issue
  with several runs and no time hint, or "why does it keep failing". Don't
  quietly read all of them. Show the candidates from the resolver (issue,
  timestamp, outcome) and ask whether to look at one specific run or search
  across several. Searching many runs is slower, pulls in a lot of noisy
  evidence, and usually isn't what the user meant. Their answer also tells you
  whether they want one failure explained or a pattern found.
- If the user has already asked for a cross-run view ("all runs for #45",
  "every infrastructure_error this week"), go ahead without asking.

Run directory timestamps are **UTC**, with `:` replaced by `-`. The user
thinks in local time (Europe/Warsaw, UTC+2 in summer, UTC+1 in winter), so
convert before you match "the run around 21:00".

## 4. Read the evidence

Work from the summary down to the detail. `references/log-layout.md` explains
each file.

1. `attempt.json`: `outcome`, `duration_seconds`, `model_stop_reason`,
   `model_usage` (cost/tokens), plus `attempt_kind` (`ordinary` when missing;
   `conflict` for a merge-conflict requeue). If it has no `outcome`, the run
   is either still in progress (check `state/attempt.json`) or the process
   died mid-run (check `docker compose logs` and the container's exit code;
   137 means it was killed, e.g. by OOM or `docker stop`). A conflict attempt
   maps its marker outcome to the lifecycle outcome (`success` → `complete`,
   `skipped` → `no_changes`, `rebase_conflict` / `check_failed` /
   `model_limit` / `resolution_failed` / `no_change` → `incomplete`,
   `setup_failed` / `error` / `push_failed` → `infrastructure_error`); see
   `references/log-layout.md`. Note the singular/plural split: the marker
   outcome is `no_change`, the lifecycle outcome for `skipped` is
   `no_changes`.
2. `agent_output.json`: the ordered event stream, JSON lines. Find the first
   `level` = `ERROR`/`WARNING`, or the `*_failed` / `attempt_exception` /
   `model_execution_finished` / `conflict_escalated` event. Its `detail`
   usually names the cause. For a conflict run also look for
   `conflict_requeue_detected` and `conflict_attempt_claimed`.
3. Only then open the specific files the events point to: `setup_*`,
   `baseline_check_*`, `check_*` logs, or the `NNNN_tool_call.json` /
   `NNNN_tool_result.json` pair around the failure.
4. `repo/` is the agent's working clone (branch `agent/issue-<n>`). The handoff
   note for continuations is `repo/.agent/handoff/<issue>.md`.

If several runs in a row fail within seconds, each in a different place, or
any log shows `Resource temporarily unavailable` / `EAGAIN` / exit code -6,
suspect pids exhaustion from unreaped zombies before reading further. Follow
`references/log-layout.md#diagnosing-pids-exhaustion-zombie-processes`.

Tool-call files can number in the hundreds per run. Grep or `jq` over them for
the thing you need (a command, a path, an error string) instead of reading them
in order. Conflict attempts run little or no model work, so an empty tool-call
sequence is normal: the marker in the issue's result comment is the outcome,
not missing evidence.

### Conflict requeue: PR has conflicts but was not requeued

When the user asks why a conflicting agent PR did not come back as a
conflict attempt, work through this list and name the first match. The
detector (`conflict_requeue_detected`) only fires with
`MAX_CONFLICT_ATTEMPTS=N > 0`; at `0` no pull-request query runs and a
labelled issue waits untouched.

1. Setting: `grep -E '^MAX_CONFLICT_ATTEMPTS='` in the instance `.env`
   (commented out means `0`, the default). At `0` nothing else matters.
2. Mergeability: only an open, non-draft PR reporting `CONFLICTING`
   qualifies. `UNKNOWN` means GitHub is still computing it and this poll
   skips the issue; a draft never qualifies.
3. Issue state: open, unassigned, non-empty body, no open blocker, and none
   of the queue labels. Assigned issues, issues carrying `ready-for-agent`
   or `round-finished` (they take the ordinary/continuation path and the
   stale `merge-conflict` is cleared at claim), issues already carrying
   `merge-conflict`, and issues another worker claimed first (`claimed-by:*`
   labels) are never relabelled. At claim time the same precedence decides
   the attempt kind: with `ready-for-agent` or `round-finished` alongside
   `merge-conflict` the run is an ordinary/continuation attempt (no
   `conflict_attempt_claimed` event) and the stale label is cleared.
4. `ready-for-human`: the detector never labels it and the queue never
   claims from it, even with a hand-applied `merge-conflict`. Only a human
   removing the label requeues the issue, with the full budget.
5. Confirm with `conflict_requeue_detected` in the issue's
   `agent_output.json` (INFO, `detail` names the issue, PR and sha). Its
   absence plus one of the above is the answer; do not treat the missing
   requeue as an agent failure.

### Conflict attempt failed or escalated

When the user asks about a conflict attempt's failure, or how close the
issue is to a human handoff, read the GitHub result comment plus the local
run, newest first:

1. Marker: `<!-- conflict-attempt: outcome=<...> sha=<...|none> ... -->`
   gives `outcome` (`success`, `skipped`, or a failure kind:
   `rebase_conflict`, `check_failed`, `setup_failed`, `error`,
   `push_failed`, `model_limit`, `resolution_failed`, `no_change`), the
   pushed sha, `reason` for `skipped` (`no_open_pr`, `draft`,
   `not_conflicting`, `base_mismatch`), and `files` / `fix_commits` /
   `extra_files`. The visible `**Conflict attempts**: k/N` line is the
   standing; the hidden `<!-- conflict-escalation -->` plus the
   `### Human handoff` section means this attempt escalated.
2. Why it pushed nothing: only `success` with a new sha pushes. Every other
   outcome leaves the remote branch untouched so the PR stays `CONFLICTING`
   (check `check_*.log` for `check_failed`, `setup_*.log` for
   `setup_failed`, the conflicting-files listing for `rebase_conflict`,
   `publication_failed` for `push_failed`, and a `success` whose sha equals
   the PR head for `no_change`). A recovered run (restart mid-attempt)
   always publishes a conflict `error` with the `<!-- requeue-source:
   conflict -->` marker and counts toward the budget.
3. How far from escalation: `N - k` from the newest `k/N` line, where `N`
   is `MAX_CONFLICT_ATTEMPTS`. A pushed-sha `success`, a `skipped` result,
   an ordinary attempt result, or the latest escalation comment resets or
   stops the streak; removing `ready-for-human` requeues with the full
   budget. Correlate with `conflict_escalated` (WARNING) or
   `conflict_escalation_failed` in `agent_output.json`, and with
   `state/attempt.json` (`attempt_kind: conflict`,
   `requeue_source: conflict`) while the attempt is active.

The resolvers already handle both kinds: `locate-agent.sh` prints
`attempt_kind` per run (missing means `ordinary`), and `fetch-run.sh`'s
finished check (presence of `outcome`) applies to conflict attempts
unchanged.

## 5. Report

Tell the user:

- which agent, on which docker context, and which run(s) you looked at:
  issue, UTC timestamp, outcome
- the root cause, backed by a quote from the specific file and event
  (e.g. `check_stderr.log`, or event `final_check_failed`)
- whether the cause is in the target repo, the agent instance config
  (Dockerfile, profile, `.env`), or upstream simple-coding-agent
- a suggested fix. Changes to an `agent-instances/agent-*/` instance are made in this repo.
  Upstream changes go to the separate `simple-coding-agent` checkout, so point
  there instead of editing the image.
