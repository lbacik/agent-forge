# Pools of N Workers

Read this when an Instance gets N>=2 Workers, shares its Worker identity with
another Instance, or has a Worker with its own Worker identity. The rules
every Instance needs are in SKILL.md, "Pools"; terms are defined in
`CONTEXT.md`.

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

## Minimum upstream

- A Worker id needs `AGENT_SRC_REF` `v0.7.0` or newer, the Pool release of
  lbacik/simple-coding-agent#302.
- N>=2 Workers on one Worker identity need `v0.9.0` or newer, the first
  release with the startup recovery fix of lbacik/simple-coding-agent#364.
  Earlier tags can leave a Worker unable to start, with its Claim marker
  behind, when its Claim is gone.
- A pinned `AGENT_SRC_REF` older than that must be bumped first; ask the user.

## Hard rule and the order to N>=2

Never run Workers of different Claim protocol versions on one Worker
identity. A Worker without `WORKER_ID`, or older than `v0.7.0`, compares only
the login, so it takes another Worker's Claim for its own; a Worker that gains
`WORKER_ID` while holding a Claim without a Claim marker no longer recognises
it as its own. A Worker identity moves to N>=2 Workers in this order
(agent-forge#34):

1. An upstream release with the Pool support (above).
2. `agentctl stop` on every Worker acting as that identity, in every
   Instance. Let active attempts finish, then check that no issue in the
   repository is still assigned to the login.
3. Bump `AGENT_SRC_REF` to that release and set `WORKER_ID` on all of them,
   then rebuild and recreate them all at once.
4. Only then add Workers.

A new Instance with N>=2 on an identity nobody else uses starts all Workers
together, so step 3 is its first start. A new Instance on an identity another
Instance already uses must wait until steps 2–3 are done for that Instance.
`create-agent` never changes existing instances, so tell the user what the
other Instance needs.

## Changing N later

Adding or removing a Worker, or changing a Worker id, belongs to the
`manage-pool` skill (`.agents/skills/manage-pool/`, agent-forge#42); until it
exists, follow the order above by hand. Losing a Worker's `/data` or changing
its Worker id strands its Claim marker (`claimed-by:<worker-id>`) and the
assignment: remove both by hand, there is no automatic cleanup.

## Host capacity

A Worker mostly waits on the model, so the shared model or gateway rate limit
is the real ceiling, not the host. Rough maximums per host from
agent-forge#22: rpi5 2–3 Workers, a local OrbStack host 2. Ask the user
before rendering more.
