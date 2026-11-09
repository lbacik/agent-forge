---
name: manage-pool
description: Change or steer the Pool of an existing simple-coding-agent Instance in this agent-forge project (`agent-instances/agent-<name>/`) - add a Worker (on the shared login or with its own GitHub identity), remove a Worker, stop or resume one Worker or the whole Pool, or point a Worker at an issue with `agentctl next issue`. Use this whenever the user wants more or fewer Workers, to pause or restart intake, or to prioritise an issue, e.g. "add a second worker to battles", "dodaj workera do agent-cli", "remove worker 3", "zatrzymaj pool na rpi5", "resume agent-2", "let a worker take #57 next".
---

# manage-pool

Change the Pool of one existing Instance: add, remove, stop, resume, and
`next issue`. Terms (Instance, Worker, Pool, Worker identity, Worker id,
Claim, Claim marker, Queue) are defined in `CONTEXT.md`. The layout a Pool
follows is the one `create-agent` renders (`create-agent/SKILL.md`, "Pools",
and `create-agent/assets/compose.yaml.template`); this skill edits it by
hand, as `docs/adr/0002-one-pool-per-docker-context-without-swarm.md`
decides: there is no generator and no script of its own.

## Ground rules

- **Go-ahead per state change.** Every edit of instance files, every
  `docker compose up|stop|rm`, and every mutating `agentctl` command needs
  the user's go-ahead (AGENTS.md). Show the plan (files, commands, which
  Workers are affected), then act. Read-only checks (`agentctl status`,
  `agentctl command <id>`, `pool-status.sh`, `gh` queries) need none.
- **One context.** A Pool is one Compose project on one Docker context with
  one model backend. Workers on another host or backend are another
  Instance, not a change to this Pool.
- **Hard rule.** Never run Workers of different Claim protocol versions on
  one Worker identity. A login's first N>=2, and any upgrade of Workers that
  share a login, follow `references/first-pool-on-a-login.md`.
- **Claims are never forced.** A Worker that holds a Claim is not removed.
  Volumes, labels and assignments are deleted only by the user or with their
  explicit authorization.
- **Secrets stay out of output.** Read single keys with
  `grep -E '^KEY=' <file>`; never print an env file, a token, or
  `docker compose config` without a `jq` filter (it inlines the env files).

## 1. Resolve the Pool

The user names the Instance or a fragment of its name; ask when several
match. Establish, and keep for the report:

- **Context.** The one the user names, else `orbstack`. An Instance on a
  LiteLLM gateway runs where the gateway runs.
- **Env file.** `.env`, unless the Instance runs with an alternative file
  (one setting `AGENT_ENV_FILE`, e.g. `.env.litellm`); that file is then the
  "shared env file" below. Ask when unsure which one is live.
- **Workers.** The services in `compose.yaml` (`agent`, `agent-<n>`), each
  one's Worker id (its `WORKER_ID` line, or none), and whether it has its
  own Worker identity (an `.env.worker-<n>` in its `env_file`).
- `TARGET_REPO` and `AGENT_SRC_REF` (`grep -E '^(TARGET_REPO|AGENT_SRC_REF)=' <env file>`;
  no `AGENT_SRC_REF` means `main`). The version a Worker actually runs is
  the `agent version:` line of its `agentctl status`.
- **Live state.** One read-only overview (it reads `TARGET_REPO` from `.env`
  only, so `--github` needs that file to carry it):

  ```bash
  .agents/skills/debug-agent/scripts/pool-status.sh --context <ctx> --github <name>
  ```

  It prints, per Worker, container state, intake, active issue and
  `pending_next_issue`, and flags orphaned Claim markers and claims without
  labels.

**Command conventions** for this skill and its references: repository paths
(`.agents/…`, `agent-instances/…`) are relative to the project root;
`docker` and `docker compose` commands run in `agent-instances/agent-<name>/`
with `DOCKER_CONTEXT=<ctx>` set and, for an alternative env file,
`docker compose --env-file <file>`. The examples leave both out.

Talking to one Worker (`<service>` is `agent` or `agent-<n>`; upstream's
operator docs require the absolute path):

```bash
docker compose exec -u agent <service> /usr/local/bin/agentctl status
```

Pass `--expect-repo=<TARGET_REPO>` to mutating commands when the Worker's
`agent version:` is v0.8.0 or newer; on older ones check the `repository:`
line of `status` first. A mutating command prints a `request_id`;
`agentctl command <request-id>` reads its outcome later (`accepted`,
`completed`, `superseded` or `not fulfilled`).

## 2. Stop and resume

`agentctl stop` lets the active attempt finish and then stops intake; the
intake state lives on the Worker's `/data`, so it survives restarts and
recreation, and a stopped Worker stays stopped until `agentctl resume`.

**Drain** a Worker: `agentctl stop` on it, then wait until its `status`
shows `active_attempt: none`. Other sections and the references drain
Workers this way.

- **Stop a Worker:** drain it. When the user also wants the container down,
  then `docker compose stop <service>`. Stopping the container mid-attempt
  kills the attempt and leaves recovery work for the next start; do it only
  on the user's explicit request.
- **Resume a Worker:** `docker compose up -d <service>` if its container is
  down, then `agentctl resume` on it.
- **Whole Pool:** the same on every Worker, one `exec` each; for the
  containers, `docker compose stop` once every Worker is drained, and
  `docker compose up -d` to bring them back.

Done when `pool-status.sh` shows the intended intake state on every Worker
the user named.

## 3. `next issue` in a Pool

`agentctl next issue <n>` is per Worker: it sets a one-shot priority on that
Worker's next claim. Choose the Worker:

- exactly one Worker with `intake: running` and `active_attempt: none` →
  that one;
- none, or several → ask the user, listing the Workers with their state.

Send it (`agentctl next issue <n> --expect-repo=<TARGET_REPO>`) and keep the
`request_id`. A Worker on another login or Instance may claim the issue
first: the command then ends `not fulfilled`, naming the other claimant,
which is a normal outcome. Sending the same issue to another Worker is a new
decision for the user.

Done when `agentctl command <request-id>` shows `completed`,
`not fulfilled` or `superseded`, and the report names the Worker (service
and Worker id), the request id and that outcome; while it is still
`accepted`, report that and how to check it later.

## 4. Add a Worker

The default is a Worker on the shared login. A Worker with its own GitHub
account follows `references/own-worker-identity.md` instead of steps 4-6.

1. **Order check.** Every Worker on the shared login, in this and any other
   Instance, must run `v0.9.0` or newer with a Worker id. If they have no
   Worker id yet (the login's first N>=2) or one runs an older version,
   complete `references/first-pool-on-a-login.md` first.
2. **Capacity.** Ask before going past the rough host maximums in
   `create-agent/references/pools.md` ("Host capacity").
3. **Number.** `n = max(n ever used) + 1`, never reused, so an old Claim
   marker can never match a new Worker. "Ever used" is the maximum of:
   - the services in `compose.yaml` (`agent` counts as 1);
   - the Worker volumes on the context:
     `docker volume ls -q | grep -E '^agent-<name>_data_[0-9]+$'`;
   - the Claim marker labels in the repository:
     `gh label list --repo <TARGET_REPO> --search 'claimed-by:<short-name>-' --limit 500 --json name -q '.[].name' | grep -E '^claimed-by:<short-name>-[0-9]+$'`
     (the search is fuzzy, hence the `grep`; labels outlive the Claims that
     created them, so this also covers removed Workers).

   The Worker id is `<short-name>-<n>`: `[a-z0-9-]`, at most 32 characters.
4. **Edit the files.** In `compose.yaml`, copy an existing `agent-<m>`
   stanza (or the template's `agent-<n>` stanza when there is none), with
   `agent-<n>`, `WORKER_ID: <short-name>-<n>`, the commit author
   `Claude Code (<short-name>-<n>)` in both `GIT_*_NAME` keys, volume
   `data_<n>:/data`, and no `.env.worker-<n>` entry; add `data_<n>:` under
   `volumes:`. If the Instance has `compose.litellm.yaml`, add `agent-<n>`
   there as well: a Worker missing from it cannot reach the gateway.
5. **Validate.** `docker compose config -q`, then
   `docker compose config --format json | jq '.services | map_values({worker_id: .environment.WORKER_ID, author: .environment.GIT_AUTHOR_NAME, volumes: [.volumes[].source], networks: (.networks // {} | keys)})'`:
   distinct Worker ids, every Worker its own volume, the gateway network on
   every Worker for LiteLLM.
6. **Start only the new Worker:** `docker compose up -d agent-<n>`. The
   other Workers keep running untouched; the image is the one `agent`
   built (`pull_policy: never`).

Done when `pool-status.sh` lists `agent-<n>` running with intake running
(a fresh `/data` starts with intake running), and
`docker compose exec -u agent agent-<n> git var GIT_AUTHOR_IDENT` names
`Claude Code (<short-name>-<n>)`.

## 5. Remove a Worker

Removes Worker `agent-<n>` (n>=2). The first Worker `agent` builds the image
and keeps `agent_data`; it stays as long as the Instance exists (stop it
instead, section 2). A Worker id never changes: to rename a Worker, remove
it and add a new one.

1. **Drain** it (section 2). With the user's consent,
   `agentctl handoff now` ends the active attempt sooner with a published
   handoff.
2. **Claim check.** The Worker holds a Claim while any of these is true:
   - its `status` shows an active attempt;
   - an open issue carries its Claim marker:
     `gh issue list --repo <TARGET_REPO> --label 'claimed-by:<worker-id>' --state open`;
   - with its own identity: an open issue is assigned to its login
     (`gh issue list --repo <TARGET_REPO> --assignee <login> --state open`);
   - on the shared login: an open issue assigned to that login carries no
     `claimed-by:*` label and no Worker has an active attempt on it
     (`pool-status.sh --github` lists the live attempts). Such an
     assignment cannot be told apart from this Worker's.

   While any of these holds, refuse, report what holds it, and stop. There
   is no force mode.
3. **Remove the container:** `docker compose stop agent-<n>`, then
   `docker compose rm -f agent-<n>`.
4. **Edit the files.** Drop the `agent-<n>` stanza and its `data_<n>:`
   entry from `compose.yaml`, and its entry from `compose.litellm.yaml`.
   Then `docker compose config -q`. A Worker with its own identity also has
   `.env.worker-<n>` (see `references/own-worker-identity.md`, "Removing").
5. **Volume.** `agent-<name>_data_<n>` stays on the context, and its number
   is never reused. Tell the user how to delete it, and run it only on their
   explicit authorization: `docker volume rm agent-<name>_data_<n>`.

The remaining Workers keep their Worker ids, even when one Worker is left.

Done when `pool-status.sh` no longer lists `agent-<n>`,
`docker compose config -q` passes, and the report names the volume left
behind.

**A Worker that lost its `/data`** has no attempt to drain and no state to
consult; its Claim marker and the assignment stay on the issue. Find the
issue with the Claim marker query of step 2 and point the user at it: they
remove the label, and the assignment when no other `claimed-by:*` label
remains on that issue. Continue at step 3 once the issue is clean.

## 6. Report

Tell the user, in their language: the Instance and context, the operation,
each Worker touched (service, Worker id, identity), the commands run with
their `request_id` and outcome, files changed, what was validated, and what
remains for them (a volume to delete, a label or assignment to clear, a
Worker still draining, another Instance on the same login that needs the
same procedure). `agent-instances/` is ignored by Git; there is nothing to
commit.
