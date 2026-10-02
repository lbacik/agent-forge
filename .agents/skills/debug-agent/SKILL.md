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
   `model_usage` (cost/tokens). If it has no `outcome`, the run is either still
   in progress (check `state/attempt.json`) or the process died mid-run
   (check `docker compose logs` and the container's exit code; 137 means it
   was killed, e.g. by OOM or `docker stop`).
2. `agent_output.json`: the ordered event stream, JSON lines. Find the first
   `level` = `ERROR`/`WARNING`, or the `*_failed` / `attempt_exception` /
   `model_execution_finished` event. Its `detail` usually names the cause.
3. Only then open the specific files the events point to: `setup_*`,
   `baseline_check_*`, `check_*` logs, or the `NNNN_tool_call.json` /
   `NNNN_tool_result.json` pair around the failure.
4. `repo/` is the agent's working clone (branch `agent/issue-<n>`). The handoff
   note for continuations is `repo/.agent/handoff/<issue>.md`.

Tool-call files can number in the hundreds per run. Grep or `jq` over them for
the thing you need (a command, a path, an error string) instead of reading them
in order.

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
