# Agent Forge

Agent Forge is a clean starting point for creating and operating dedicated
[simple-coding-agent](https://github.com/lbacik/simple-coding-agent) instances
for GitHub repositories. It follows the same workflow as the sibling
`../simple-coding-agent-env` project: create an agent with `create-agent`, build
its Docker image, start it with Docker Compose, change its Workers with
`manage-pool`, and investigate problems with `debug-agent`.

Each instance targets one repository and has its own toolchain, repository
profile and configuration. It runs one or more Workers (containers), each
with its own persistent Docker volume. The agent's source is fetched from
upstream at build time.

## Project layout

```text
agent-forge/
├── .agents/skills/
│   ├── create-agent/          # Instance scaffolding instructions and templates
│   ├── manage-pool/           # Add, remove, stop and resume Workers of an instance
│   └── debug-agent/           # Diagnostics instructions and helper scripts
├── .claude -> .agents        # Exposes the same skills to Claude Code
├── .gitignore
├── CONTEXT.md                # Domain glossary (Instance, Worker, Pool, ...)
├── README.md
├── docs/adr/                 # Architecture decisions
└── agent-instances/          # Local instances; ignored by Git
    └── agent-<name>/
        ├── Dockerfile
        ├── compose.yaml          # One service per Worker: agent, agent-2..N
        ├── simple-coding-agent-profile.yml
        ├── .env.example
        ├── .env
        ├── agent-entrypoint.sh   # Optional, for bundled services
        ├── compose.litellm.yaml  # Optional, joins every Worker to a LiteLLM gateway network
        └── .env.worker-<n>       # Optional, a Worker's own GITHUB_TOKEN
```

**Create all instances inside `agent-instances/`.** The entire directory is
ignored by Git, including generated configuration and secrets. There are no
preconfigured instances in this starting version; keep backups of local
configuration separately if needed.

## Prerequisites

- Docker with BuildKit and Docker Compose v2.17 or newer, for additional build
  contexts.
- A coding assistant with access to the included skills.
- Access to the target repository and a GitHub token with read/write permissions
  for its contents, issues, and pull requests.
- The model API credentials required by the generated configuration
  (`META_API_KEY` for the default Meta backend; from simple-coding-agent
  v0.3.2, `MODEL_API_KEY` with `MODEL_BASE_URL`/`MODEL_AUTH_MODE` selects
  another backend, see `.env.example`). For `muse-*` models `create-agent`
  recommends a LiteLLM gateway, which restores Meta prompt caching: the gateway
  runs separately on a shared Docker network, the agent holds only its master
  key as `MODEL_API_KEY`, and `COMPOSE_FILE` in `.env` adds
  `compose.litellm.yaml` to attach the agent to that network. Anthropic models
  connect directly.

## Workflow

### 1. Create an agent

Ask your coding assistant to use the
[`create-agent`](.agents/skills/create-agent/SKILL.md) skill, specifying the
target repository and destination. For example:

```text
Use create-agent to create an agent for https://github.com/owner/repository
in agent-instances/agent-repository/.
```

The skill inspects the target repository's stack and CI, prepares its Docker
toolchain, and writes a local profile containing dependency setup and validation
commands. The profile should mirror the repository's gating CI checks. Instances
that require services such as MySQL or Redis may also include an entrypoint to
start them.

Review the generated `.env` and supply any missing credentials before starting
the agent. `AGENT_SRC_REF` selects the upstream agent branch, tag, or commit and
defaults to `main`. Runtime versions are not pinned per instance: upstream at
`AGENT_SRC_REF` decides `claude-agent-sdk` (its `pyproject.toml`), and the
Claude Code CLI is the one bundled in that SDK release. To upgrade, move
upstream or `AGENT_SRC_REF` and rebuild; do not set `CLAUDE_AGENT_SDK_VERSION`
in `.env`.

**Conflict requeue (optional, off by default).** When the published pull
request of an issue falls behind its base branch and reports a conflict, the
issue can come back to the Queue on its own instead of waiting for a human.
To enable it, uncomment `MAX_CONFLICT_ATTEMPTS` in `.env` and set it to N:
`0` (the default) turns the path off entirely, and N is the number of
consecutive failed Conflict attempts on one issue before the Worker escalates
it with the `ready-for-human` label. A Conflict attempt is cheap: with no
model call, the Worker rebases the issue's `agent/issue-N` branch onto the
base, runs setup plus one profile check, and force-pushes only when green.
The Queue claims an issue carrying the `merge-conflict` label ahead of other
work; the Worker applies that label itself when it sees a conflicting branch,
and a human may also apply it by hand with the same effect. After N
consecutive failures the Worker adds `ready-for-human` and never removes it —
hand the issue back by removing the label, which requeues it with a fresh
budget. The setting is independent of `PR_AUTO_MERGE`: conflicts block manual
merges too. It needs an upstream agent that contains the feature
(`AGENT_SRC_REF` v0.6.0 or newer; `main` tracks upstream).

**Pools (several Workers).** An instance runs one Worker by default; ask
`create-agent` for N to get a Pool of N Workers taking issues from the same
Queue. A Pool is one instance and one Compose project, so it runs on one Docker
context with one model backend; Workers on another host or backend are a
separate instance (see `docs/adr/0002-one-pool-per-docker-context-without-swarm.md`).
In `compose.yaml` the first Worker is the service `agent` with the volume
`agent_data`; further Workers are `agent-2..N` with the volumes `data_2..N`.
They share one image, built once by the `agent` service, and the settings of
the `x-worker` anchor, including per-Worker limits (1.5 CPUs, 3g memory — an
estimate — and 1024 PIDs) that `WORKER_CPUS`, `WORKER_MEM_LIMIT` and
`WORKER_PIDS_LIMIT` in `.env` override.

Workers sharing one GitHub login are told apart by their Worker id
(`WORKER_ID`, `<short-name>-<n>`, e.g. `battles-2`), set per Worker in
`compose.yaml` together with the commit author `Claude Code (<worker-id>)`.
It is set when the instance has two or more Workers or shares its login with
another instance on the same repository; `create-agent` looks for such an
instance and asks. Worker ids need simple-coding-agent v0.7.0 or newer, and
two or more Workers on one login need v0.9.0 or newer (the startup recovery
fix of lbacik/simple-coding-agent#364). Never run Workers
of different Claim protocol versions on one login: stop and drain every
Worker on the login, upgrade and set `WORKER_ID` on all of them at once, and
only then add Workers. The `create-agent` skill describes the order in
`references/pools.md`; `manage-pool` carries it out for an existing instance.

**Contract discovery labels.** When the `AGENT_SRC_REF` the instance builds
from speaks the operator contract (its `agentctl` answers
`agentctl --contract 1`), every managed Worker service (`agent` and
`agent-2..N`) carries four Compose `labels:` — contract major `1`, the
Managed Instance name (`<short-name>`, or the Worker id `<short-name>-<n>`
for Worker n ≥ 2), exec user `agent` and backend `simple-coding-agent` — so
contract consumers route the instance to the contract path. The labels are
never baked into the image, and one-off containers are never labelled.
Until simple-coding-agent ships the contract (simple-coding-agent#334), no
ref qualifies and every instance renders without labels, staying on the
legacy path exactly as today. The minimum release tag will be recorded in
the `create-agent` skill once it exists.

### 2. Build

Run Compose commands from the instance directory:

```bash
cd agent-instances/agent-repository
docker compose config -q
docker compose build
```

Each instance builds independently. There is no root-level Compose deployment
or shared build command. Its repository profile is baked into the image, so
profile or Dockerfile changes require a rebuild.

### 3. Start

```bash
docker compose up -d
```

Check the container and its startup logs:

```bash
docker compose ps
docker compose logs --tail=100 -f
```

The generated `compose.yaml` sets `init: true` so that Docker's init reaps
processes orphaned by the agent's tools; without it, every attempt eventually
fails once the container runs out of process IDs. Instances created before
this setting need `init: true` added to their `agent` service, then
`docker compose up -d`.

The named `agent_data` volume (`data_2..N` for further Workers) stores the
working repository, state, and attempt logs under `/data` in the container.
These persist across container recreation.

After rebuilding an updated image, run `docker compose up -d` again to apply it.
To stop the deployment:

```bash
docker compose down
```

This preserves the named volumes. Adding `-v` deletes the volumes of every
Worker and their agent data.

To run an instance with an alternative configuration, such as `.env.claude` for
the Anthropic API, copy `.env`, change the differing settings and set
`AGENT_ENV_FILE=.env.claude` in the copy. Then pass the file to every command:

```bash
docker compose --env-file .env.claude build
docker compose --env-file .env.claude up -d
```

`--env-file` alone replaces `.env` only for interpolation in `compose.yaml`;
`AGENT_ENV_FILE` makes the container load the same file. Both configurations
share the container and the `agent_data` volume unless you also pass a separate
project name with `-p`.

An instance that uses a LiteLLM gateway needs no extra flags: `COMPOSE_FILE`
in its env file makes every `docker compose` command load
`compose.litellm.yaml` as well.

### 4. Manage a Pool

Ask your coding assistant to use the
[`manage-pool`](.agents/skills/manage-pool/SKILL.md) skill to change the
Workers of an existing instance. For example:

```text
Use manage-pool to add a Worker to agent-instances/agent-repository on the
rpi5 context.
```

It covers adding a Worker (on the shared login, or with its own GitHub
account in `.env.worker-<n>`), removing one, stopping and resuming one Worker
or the whole Pool, and `agentctl next issue` for a chosen Worker, including
the order above when a login gets its second Worker. Every change waits for
your go-ahead, a Worker holding a Claim is never removed, and volumes are
deleted only by you.

### 5. Debug problems

Ask your coding assistant to use the
[`debug-agent`](.agents/skills/debug-agent/SKILL.md) skill. Include the instance,
issue number when applicable, and Docker context if it runs on another host:

```text
Use debug-agent to investigate agent-instances/agent-repository.
Check the latest run for issue #42 on the orbstack context.
```

The skill examines startup logs, persisted state, attempt events, and validation
output to identify whether the problem comes from the target repository, the
instance configuration, or the upstream agent.

The bundled diagnostic helpers find instances in `agent-instances/` from their
own location, so they work from any working directory. For example, from the
project root:

```bash
.agents/skills/debug-agent/scripts/locate-agent.sh repository 42
```

They default to the `orbstack` Docker context; pass `--context <name>` for another
context.

## Continuous integration

Every pull request runs the template render check
([`render-check.yml`](.github/workflows/render-check.yml)). It renders the
`create-agent` templates with placeholder values — no secrets — and runs
`docker compose config` on four Compose variants to prove each result is a
valid Compose model: plain and LiteLLM without labels (a ref that does not
speak the operator contract, unchanged from today's layout), and an N=1
instance plus an N=2 Pool with the contract discovery labels kept on every
managed Worker service.

Run the same check locally (needs Docker with Compose v2.17 or newer):

```bash
.agents/skills/create-agent/tests/render-check.sh
```

The workflow only calls that script: to add an assertion about the rendered
Compose model (for example "service X carries label Y"), extend the script's
assertion section instead of editing the workflow.

Every pull request also runs the legacy helper check
([`legacy-helpers.yml`](.github/workflows/legacy-helpers.yml)). It parses
every skill script with its shebang shell, shellchecks them, and runs the
`debug-agent` helpers (`locate-agent.sh`, `fetch-run.sh`, `pool-status.sh`)
for an unlabelled container against a stubbed Docker — recorded replies, no
Docker host, no real agent, no secrets — asserting each helper's argv, stdout
and exit status.

Run the same check locally (needs only a POSIX shell, no Docker):

```bash
.agents/skills/debug-agent/tests/legacy-helpers.sh
```

The workflow only calls that script: to pin more behaviour, add a case to the
script plus its golden file under
`.agents/skills/debug-agent/tests/golden/`, or a new recorded reply under
`.agents/skills/debug-agent/tests/stub/replies/`, instead of editing the
workflow.

## Operator contract

Agent Forge follows major 1 of the
[agent operator contract](https://github.com/lbacik/agent-operator-contract),
pinned to tag `v1.0.4`. This section is the one place in the docs that names
the tag (the one place in the skills is `CONTRACT_TAG` in
`.agents/skills/debug-agent/scripts/lib/contract.sh`); everything else refers
to the contract by its major. The contract's terms are defined in the contract
repository's glossary at the pinned tag, and [CONTEXT.md](CONTEXT.md) maps them
to Forge's Instance, Worker and Pool. To move to a newer `v1.x.y`, change the
tag in both places; a new major also means reviewing that mapping.

`agentfleet` — the host-side client shipped by the contract — is installed on
the operator's host from the pinned tag. Forge ships no Python package and
vendors no library code. To install it (from the repository root; the tag is
read from the skills so it cannot drift from the pinned value):

```bash
tag=$(sed -n 's/^CONTRACT_TAG=//p' .agents/skills/debug-agent/scripts/lib/contract.sh | head -n 1)
uv tool install "agent-operator-contract @ git+https://github.com/lbacik/agent-operator-contract@$tag"
```

`locate-agent.sh` picks one of two paths per container. A container carrying
the `io.github.lbacik.agent-operator.contract` label is observed only through
`agentfleet`: the helper first checks that `agentfleet` is present and speaks
the expected contract major, and if not it stops with the install command —
it never falls back to reading the container's files. The label is only a
hint; compatibility is decided by `agentfleet`'s runtime `--contract` check,
and a `contract_mismatch`, `unsupported` or `agent_unreachable` reply is
reported as such, never retried through the legacy grammar. On the contract
path the helper prints `agentfleet identity` plus a Status Snapshot summary
(instance state and startup check, last Halt, Intake with pending stop, stop
plan and priority, current Attempt with native phase and budget Figures, last
finished Attempt, each with its `observed_at`); unknown Figures render as
`unavailable`/`not_applicable`, never `0`. A container without the label stays
on the legacy path: today's `locate-agent.sh` output (container, volume and
`state/*.json` files), unchanged. The `--context` flag (default `orbstack`) is
passed to `agentfleet` through the standard Docker context mechanism.

`pool-status.sh` answers "which Worker works on what" on the same path
selection: on a contract Instance it prints one block per Worker from its
Status Snapshot (instance state, Intake with pending stop or stop plan,
priority, current issue and native phase, each with its `observed_at`; a
stopped Worker is read through Offline Read, never reported as a gap), and
`--github` compares Claim markers only for Workers whose backend is
`simple-coding-agent`, skipping any other backend with a note. An unlabelled
Instance keeps today's `pool-status.sh` output, unchanged. `fleet.sh` answers
"what agents run on this host" for one Docker context (default `orbstack`,
`--context` for a remote host): one line per Managed Instance from
`agentfleet ls` (backend, Target Repository, contract, instance state and
Intake), plus a separate list of the unlabelled legacy containers on that
context, which `agentfleet` cannot manage.

Every pull request also runs the contract consumer suites
([`contract-helpers.yml`](.github/workflows/contract-helpers.yml) and
[`contract-attempts.yml`](.github/workflows/contract-attempts.yml)) from the
pinned tag — no copied fixtures. They install `agentfleet` from the tag named
in `contract.sh`, back it with the suite's replaying fake `agentctl` behind
the same stubbed Docker as the legacy regression check, and pin the contract
path: `contract-helpers.sh` pins `locate-agent.sh` (the prerequisite stop,
per-Worker name resolution, `--context` propagation, the snapshot summary, and
every failure class — success, rejection, `unsupported`, ambiguous outcome,
contract mismatch with no legacy fallback, malformed stdout);
`contract-attempts.sh` pins the Attempts listing and export (`locate-agent.sh`
with an issue number across `attempts ls` pages with the opaque cursor,
`fetch-run.sh` exporting Attempt Archives into the separate contract cache
with Sealed reuse after `sha256` verification, moving snapshots, torn-read and
Offline Read handling) and the log-layout reference, then runs the legacy
regression.

The pool and fleet consumer suite
([`contract-pool-fleet.yml`](.github/workflows/contract-pool-fleet.yml)) pins
contract-path `pool-status.sh` (every block field, Offline Read for a stopped
Worker, the `--github` skip for other backends, failure classes with no
legacy fallback, unlabelled output unchanged) and `fleet.sh` (Managed
Instances plus the separate legacy list, `--context` propagation), backed by
the same stubbed Docker.

Run the same checks locally (needs `agentfleet` from the pinned tag, no Docker):

```bash
.agents/skills/debug-agent/tests/contract-helpers.sh
.agents/skills/debug-agent/tests/contract-attempts.sh
.agents/skills/debug-agent/tests/contract-pool-fleet.sh
```

## Relationship to simple-coding-agent-env

The skills and templates originate from `../simple-coding-agent-env`. They
have been adapted to Agent Forge: every generated deployment goes to
`agent-instances/agent-<name>/`. The reference instances the skills mention
(for example `agent-jsonhub-web-terminal`, `agent-jsonhub-api`) live in the
sibling project and are read from there when it is available.

The operating workflow remains the same:

```text
create-agent → docker compose build → docker compose up -d → manage-pool → debug-agent
```
