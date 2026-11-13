---
name: operate-agent
description: Send an Operator Command to a simple-coding-agent instance in this agent-forge project (`agent-instances/agent-<name>/`) — stop or resume one Worker or the whole Pool, or read back a committed command. Use this whenever the user wants to pause or restart intake, or asks about a command's request ID, acknowledgement or final state, e.g. "stop agent-cli", "resume worker 2 on rpi5", "did the stop for #57 go through". Read-only diagnosis stays in debug-agent; every mutation here runs only on the operator's explicit request.
---

# operate-agent

One Worker of one Instance is one Managed Instance. This skill owns every
Operator Command that changes what the agent does, on both paths: the
contract path (labelled containers, through `agentfleet`) and the legacy
path (unlabelled containers, through `agentctl`, marked "legacy agentctl"
below). Read-only diagnosis — status, logs, state, attempt files — stays in
[debug-agent](../debug-agent/SKILL.md); that skill never mutates.

Terms (Instance, Worker, Pool, Managed Instance, Target Repository, Intake,
Operator Command, Acknowledgement, Status Snapshot) are defined in
`CONTEXT.md`. The operator contract is pinned as described in
`README.md#operator-contract`; `agentfleet` is the host-side client shipped
by the contract. Forge ships no Python package.

## Ground rules

- **Explicit request, confirmed target.** Every command below runs only on
  the operator's explicit request. Before submitting, restate the Managed
  Instance, the Target Repository, the backend, and the command's effect, and
  wait for the go-ahead. The bundled helper (`scripts/operate.sh`) does not
  ask; invoking it IS the request, so run it only after the operator
  confirmed the restated target.
- **One Worker per submission.** The helper addresses one Worker
  (`--worker <n|worker-id>`, default the first Worker). A whole Pool is the
  same command on every Worker, one submission each. Never invent a Worker
  id; resolve it from the instance directory and `compose.yaml` as
  `debug-agent` does.
- **Read-only checks need no go-ahead** (`identity`, `status`,
  `command <request-id>`, `pool-status.sh`). Everything that changes intake
  or queue priority needs one.
- **Secrets stay out of output.** Read single keys with
  `grep -E '^KEY=' <file>`; never print an env file or a token.
- The helpers default to the `orbstack` Docker context; pass
  `--context <name>` for another host, and use that context consistently.

## 1. Confirm the target

1. Resolve the instance and Worker (the helper does this itself from the
   Forge directory; with N>=2 and no `--worker` it stops and lists the
   Workers instead of guessing — pick one and re-run).
2. Read the Target Repository from the instance's configuration, never from
   the instance's identity: `TARGET_REPO` in the instance env file
   (simple-coding-agent `.env`, or the live alternative file when the
   instance runs with one), or `target.repository` in the Workflow
   Configuration (coding-agent). The helper takes `--expect-repo` to
   override; without it, it reads the configuration in that order and stops
   when nothing parses as `owner/repo`.
3. Restate: Managed Instance name, Forge Instance (directory), Docker
   context, Target Repository, backend (from `identity`), the operation and
   its effect from the table in section 2. Then submit.

## 2. Operations and their effects

| Operation | Effect |
|---|---|
| `stop` | Closes Intake after the active attempt finishes (drain). Intake state lives on the Worker's `/data`, so a stopped Worker stays stopped until `resume`. |
| `stop --after N` (1-999, only where advertised) | Closes Intake after N finalized attempts (stop plan). |
| `resume` | Reopens Intake only. It never starts a container. |
| `next-issue N` | One-shot priority: issue N is preferred for the Worker's next claim. Losing the race to another Worker is a normal outcome (`not_fulfilled`), not a failure; sending it to another Worker is a new decision. |
| `handoff` | Completes an Operator Handoff of the active attempt. |
| `recovery-retry <attempt-id>` | Retries safe finalization of a retained attempt from its retained evidence. Commits a `completed` no-op when the attempt is already finalized. |
| `recovery-release <attempt-id> --saved-at <location>` | Records the retained work as secured at the location, releases the issue and finalizes the attempt. Refused for an active attempt (nothing retained) and for an already-finalized one. |
| `errors-reset` | Resets the durable infrastructure-error guard. Rejected with no change (nothing stored) while the guard is already clear. |
| `command <request-id>` | Reads back the committed Operator Command. No state changes. |

Semantics that are easy to get wrong:

- **`stop` is a drain, never `docker stop` or `docker compose stop`.**
  Stopping the container mid-attempt kills the attempt and leaves recovery
  work; the drain lets the active attempt finish and then closes Intake. For
  coding-agent, SIGTERM is an interruption that produces an `interrupted`
  outcome — never send it as a way to stop.
- **`resume` never starts a container.** If the container is down, starting
  it is a separate deployment action (`docker compose up -d <service>`)
  that needs the operator's authorization; only then does `resume` reopen
  Intake.
- **`recovery-release --saved-at` takes a location, never a credential.**
  Pass where the work was secured (a shelf, path or URL); anything token-
  or key-shaped is refused before submission, so secrets never land in the
  command store. The helper never echoes a refused value back.
- **`recovery-retry` and `recovery-release` are different decisions.**
  Retry keeps the attempt and finishes it from retained evidence; release
  abandons the attempt after its work was secured elsewhere. Release needs
  the `--saved-at` location; retry takes none.
- **`client.instance_stopped`: a mutation is never sent to a stopped
  instance.** A stopped instance takes no Operator Command through
  `agentfleet` or `agentctl`. Read it offline through `debug-agent`; never
  start it as a side effect of operating it.
`next-issue` and `handoff` beyond one Worker follow
[manage-pool](../manage-pool/SKILL.md): that skill picks the Worker (intake
running, no active attempt; ask when none or several qualify) and the Claim
checks before removal, and calls back here for the submission itself.

## 3. Contract path (labelled containers)

Before submission the helper reads `agentfleet identity` and refuses an
operation whose capability is not advertised, listing the advertised
Operator Capabilities. `stop` and `resume` are core and need no capability;
`stop --after` needs `stop-after`, `next-issue` needs `next-issue`,
`handoff` needs `operator-handoff`, `recovery-retry` needs
`recovery-retry`, `recovery-release` needs `recovery-release`, and
`errors-reset` needs `errors-reset`. The producer re-checks before
committing; a refusal names the missing capability. For example, coding-agent
advertises `next-issue` and `stop-after` but not `operator-handoff`, so the
skill refuses `handoff` there and says so from `identity`.

Every mutation carries `--expect-repo` with the Target Repository from
section 1 and a request ID generated before submission: the helper uses
`agentfleet`'s own generator and passes the ID explicitly (so the ID is on
the record even if the submitter crashes), falling back to the same
`req-<hex>` shape only when that import is unavailable. The
helper submits once (`--max-attempts 1`): an uncertain outcome is never
retried with a new ID.

Report the Acknowledgement, distinguishing `accepted` (committed, effect
not yet applied) from the final states (`completed`, `superseded`,
`not_fulfilled`):

- `accepted` → report the request ID, the operation and kind, and how to
  check it (`command <request-id>`); with `--follow`, follow it to its
  final state.
- `completed` / `superseded` / `not_fulfilled` → report the final state
  and what it means. `not_fulfilled` is final but not done (for
  `next-issue`, the priority lost the race or was ineligible — who won the
  race when the command names another claimant); never report it as success,
  and re-decide whether to submit again.
- `replayed: true` → the command was already committed under this request
  ID; nothing new happened.
- Rejection (`rejected`, `repository_mismatch`, `payload_mismatch`, …) →
  report the code and message; nothing was stored, so there is nothing to
  follow up.
- `unsupported` / `contract_mismatch` → report as such, never retried
  through the legacy grammar.
- Ambiguous outcome (`agent_unreachable`, `internal`, timeout, Docker
  transport error) → the outcome is unknown. Report the request ID, then
  check it with `command <request-id>` using the same ID. Never submit
  again with a new ID: a blind retry could execute the command twice.

Run the bundled helper; it encodes exactly the submit-then-follow-up
sequence above (one submission, same-ID `command` check, `--follow` loop
to a final state):

```bash
.agents/skills/operate-agent/scripts/operate.sh [--context <ctx>] [--worker <n|worker-id>] [--expect-repo <owner/repo>] [--request-id <id>] [--follow] <name-fragment> <stop [--after <n>]|resume|next-issue <n>|handoff|recovery-retry <attempt-id>|recovery-release <attempt-id> --saved-at <location>|errors-reset|command <request-id>>
```

Examples (from anywhere; the helper resolves `agent-instances/` itself):

```bash
.agents/skills/operate-agent/scripts/operate.sh cli stop
.agents/skills/operate-agent/scripts/operate.sh --context rpi5 --worker 2 paysubscriptions resume --follow
.agents/skills/operate-agent/scripts/operate.sh cli stop --after 2
.agents/skills/operate-agent/scripts/operate.sh cli next-issue 122 --follow
.agents/skills/operate-agent/scripts/operate.sh cli handoff
.agents/skills/operate-agent/scripts/operate.sh cli recovery-retry att-2026-11-01-001
.agents/skills/operate-agent/scripts/operate.sh cli recovery-release att-2026-11-01-001 --saved-at shelf-303
.agents/skills/operate-agent/scripts/operate.sh cli errors-reset
.agents/skills/operate-agent/scripts/operate.sh cli command req-3f1c9a2b7d10
```

The helper prints the restated target (Managed Instance, context, Target
Repository, operation, effect, backend and capabilities from `identity`),
then the request ID and the Acknowledgement. Its consumer suite
(`tests/operate-helpers.sh`, same seam as the debug-agent suites: recorded
producer replies from the pinned contract tag, no copies) pins success,
rejection, `unsupported`, the ambiguous same-ID follow-up, contract
mismatch with no legacy fallback, malformed stdout, the pre-submission
refusal, the optional commands above (each with guards and request ID,
`next-issue` followed to each final state with `not_fulfilled` as not
done, the credential-shaped `--saved-at` refusal), and the legacy argv
below:

```bash
.agents/skills/operate-agent/tests/operate-helpers.sh
```

## 4. Legacy path ("legacy agentctl")

This section is legacy: it applies only to unlabelled instances, and goes
away when the legacy path is removed. Today's `agentctl` usage, unchanged:

```bash
docker exec -u agent -w /data <container> /usr/local/bin/agentctl status
docker exec -u agent -w /data <container> /usr/local/bin/agentctl stop [--after <n>] [--expect-repo=<TARGET_REPO>]
docker exec -u agent -w /data <container> /usr/local/bin/agentctl resume [--expect-repo=<TARGET_REPO>]
docker exec -u agent -w /data <container> /usr/local/bin/agentctl next issue <n> [--expect-repo=<TARGET_REPO>]
docker exec -u agent -w /data <container> /usr/local/bin/agentctl handoff now [--expect-repo=<TARGET_REPO>]
docker exec -u agent -w /data <container> /usr/local/bin/agentctl recovery retry <attempt-id>
docker exec -u agent -w /data <container> /usr/local/bin/agentctl recovery release <attempt-id> --saved-at <location>
docker exec -u agent -w /data <container> /usr/local/bin/agentctl errors reset
docker exec -u agent -w /data <container> /usr/local/bin/agentctl command <request-id>
```

Pass `--expect-repo=<TARGET_REPO>` when the Worker's `agent version:` is
0.8.0 or newer (with or without a leading `v`); on older ones check the
`repository:` line of `status` first. The legacy `recovery` and `errors` grammar takes no `--expect-repo`
flag; `errors reset` also answers to its `consecutive-errors reset` alias.
A mutating command prints a `request_id`;
`/usr/local/bin/agentctl command <request-id>` reads its outcome later (`accepted`,
`completed`, `superseded` or `not fulfilled`). The helper (`operate.sh`)
runs these for unlabelled instances: it picks the flag from the status
version, surfaces the printed request ID, and follows it with
`/usr/local/bin/agentctl command <same-id>` on `--follow`. `stop` here drains exactly as
on the contract path; it is never `docker stop`.

## 5. Report

Tell the user, in their language:

- the Managed Instance (and Forge Instance, context, Worker), the Target
  Repository and backend the command was checked against;
- the operation, its effect, the request ID and the Acknowledgement —
  `accepted` distinctly from `completed` / `superseded` /
  `not_fulfilled`, with the follow-up command when still `accepted`;
  report `not_fulfilled` as not done, never as success;
- for `recovery-release`, the location the work was secured at (never a
  credential — a refused `--saved-at` is reported without echoing it);
- for ambiguous outcomes, the request ID and what the same-ID
  `command` check showed — never a second submission;
- what remains (a Worker still draining, a `not_fulfilled` priority to
  re-decide, a stopped container left stopped).
