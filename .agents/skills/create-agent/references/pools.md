# Pools of N Workers (simple-coding-agent only)

Read this when an Instance gets N>=2 Workers, shares its Worker identity with
another Instance, or has a Worker with its own Worker identity. The rules
every Instance needs are in SKILL.md, "Pools"; terms are defined in
`CONTEXT.md`. The coding-agent adapter never renders a Pool — exactly one
Worker per Target Repository and state volume — so this reference does not
apply to it; see `references/coding-agent.md` instead.

## Worker identities

- **Shared (the default Pool).** Every Worker acts as the `GITHUB_TOKEN` of
  the shared env file (`.env`, or the `AGENT_ENV_FILE` alternative). Each
  Worker sharing it gets a Worker id; `PEER_LOGINS` stays commented out,
  because a shared Worker identity's comments are already every Worker's own.
- **Own Worker identity.** The first Worker `agent` always uses the shared
  env file. A further Worker with its own GitHub account keeps the `env_file`
  list of its `agent-<n>` stanza; `.env.worker-<n>` holds only its
  `GITHUB_TOKEN`, which overrides the shared one (Docker Compose v2.24+ for
  `required: false`). Copy the token with shell tools, never printing it. A
  Worker whose identity no other Worker shares needs no Worker id: delete its
  Worker id block. Workers with different Worker identities on one Queue need
  `PEER_LOGINS` in `.env` listing all their logins (see `.env.example`); ask
  the user before setting it.

## Contract discovery labels

When `AGENT_SRC_REF` speaks the operator contract (minimum release `v0.9.0`,
the first release whose `agentctl` answers `agentctl --contract 1` — see
`SKILL.md`, "Pools", "Contract discovery labels" and "Minimum upstream"),
every Worker service this Pool renders carries all four discovery labels:
`agent` with the instance name `<short-name>`, each `agent-<n>` with its
Worker id `<short-name>-<n>`, and the backend label naming the engine backend
from step 0 (`simple-coding-agent`). `main` always qualifies, a release tag
`v0.9.0` or newer qualifies, a release tag older than `v0.9.0` stays on the
legacy path, and any other branch or commit SHA qualifies when that checkout
contains `simple_coding_agent/contract_adapter.py`. The labels are set
through Compose `labels:` only, never as an image `LABEL`, so one-off
containers stay unlabelled.
A Pool of N ≥ 2 Workers on the contract path requires `pool` in the
`identity.capabilities` the running instance reports; without it the backend
cannot run a Pool here. No backend advertises `pool` yet.

## Hard rule and the order to N>=2

Never run Workers of different Claim protocol versions on one Worker
identity. The reasons, the minimum upstream (`v0.9.0` for N>=2 on one
identity) and the order a login moves to N>=2 Workers (release, drain every
Worker on it, upgrade and set `WORKER_ID` on all at once, then add Workers)
are in `.agents/skills/manage-pool/references/first-pool-on-a-login.md`.

A new Instance with N>=2 on an identity nobody else uses starts all Workers
together, so its first start is the "upgrade all at once" step. A new
Instance on an identity another Instance already uses waits until that
Instance has been drained and upgraded. `create-agent` never changes
existing instances, so tell the user what the other Instance needs; the
`manage-pool` skill carries it out.

## Changing N later

Adding or removing a Worker of an existing Instance, and moving an existing
login to N>=2, belong to the `manage-pool` skill
(`.agents/skills/manage-pool/`). A Worker id never changes: a renamed Worker
is a removed one plus a new one. Losing a Worker's `/data` strands its Claim
marker (`claimed-by:<worker-id>`) and the assignment: remove both by hand,
there is no automatic cleanup.

## Host capacity

A Worker mostly waits on the model, so the shared model or gateway rate limit
is the real ceiling, not the host. Rough maximums per host from
agent-forge#22: rpi5 2–3 Workers, a local OrbStack host 2. Ask the user
before rendering more.
