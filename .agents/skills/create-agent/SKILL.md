---
name: create-agent
description: Create a new, dedicated agent instance (compose.yaml, .env, .env.example plus, per backend, a Dockerfile with a local repository profile or a Workflow Configuration) for a GitHub repository, in this agent-forge project (always under `agent-instances/agent-<name>/`). The engine backend is simple-coding-agent by default, coding-agent on request. Use this whenever the user gives a repository URL or owner/repo and wants an agent "for" it — e.g. "create an agent for https://github.com/x/y", "set up simple-coding-agent for my Go service", "przygotuj agenta dla ...", "new agent instance like agent-jsonhub-api" — even if they don't say "create-agent" explicitly. Also use it, through its coding-agent adapter reference, when the user explicitly asks to upgrade an existing coding-agent instance to the v3 derived-image layout, e.g. "upgrade the sandbox agent to v3".
---

# create-agent

Scaffold one `agent-instances/agent-<name>/` directory in this repo that builds
and runs one engine backend against a single target repository:
[simple-coding-agent](https://github.com/lbacik/simple-coding-agent) by
default, [coding-agent](https://github.com/lbacik/coding-agent) on request.
`agent-instances/` is ignored by Git, so
the instance and its secrets never get committed. Never create an instance
anywhere else.

`create-agent` never changes an existing Instance, except for an explicitly
requested upgrade of a coding-agent Instance to the derived-image layout:
that procedure lives in `references/coding-agent.md`, "Upgrading an existing
coding-agent Instance", and none of the new-instance steps below apply to it.

The reference implementations live in the sibling project
`../simple-coding-agent-env/` (top-level `agent-*/` there). Read them before
generating anything, they carry lessons that are not repeated here. Treat them
as read-only reference material. If that project isn't available, say so and
work from the templates alone:

- `../simple-coding-agent-env/agent-jsonhub-web-terminal/` — the **default shape**: no bundled services,
  agent runs directly as the `agent` user, profile baked into the image and
  selected with `PROFILE_PATH`.
- `../simple-coding-agent-env/agent-jsonhub-api/` — the **bundled-services shape**: MySQL + Redis inside the
  image, a root `agent-entrypoint.sh` that starts them and drops to `agent`
  with `gosu`. Read `references/bundled-services.md` before using this shape.
  (Its profile still lives in the target repo — new agents should not copy that;
  keep the profile local as in web-terminal.)

The output is these files in `agent-instances/agent-<name>/`, depending on the
backend chosen in step 0:

| File | Source |
|---|---|
| `Dockerfile` | simple-coding-agent only: `assets/Dockerfile.template` + a stack block |
| `compose.yaml` | `assets/compose.yaml.template` (simple-coding-agent, one service per Worker) or `assets/compose.coding-agent.yaml.template` (coding-agent: build-only `engine` base, labelled `worker` and optional `worker-2`, unlabelled `agent` and `validate` seats on the derived image) |
| `Dockerfile` | coding-agent only: `assets/Dockerfile.coding-agent.template`, copied verbatim (the derived deployment image) |
| `simple-coding-agent-profile.yml` | simple-coding-agent only: written from the target repo's CI |
| `workflow/workflow.yml` | coding-agent only: `assets/workflow.coding-agent.yml.template`, with the selected Workflows (`implement`, `triage` or both) |
| `workflow/prompts/*.md` | coding-agent only: `implement`'s copied from the `CODING_AGENT_REF` checkout, `triage`'s copied verbatim from `assets/prompts/` |
| `workflow/skill-policy.json` | coding-agent only: the reference bundle's copied verbatim from the `CODING_AGENT_REF` checkout's `docker/deployment/`; any other bundle's drafted with `agent draft-skill-policy` and completed with operator-approved decisions |
| `.env.example` | `assets/env.example.template` (simple-coding-agent) or `assets/env.coding-agent.example.template` (coding-agent) |
| `.env` | same as `.env.example` + real secrets (ignored with all of `agent-instances/`) |
| `agent-entrypoint.sh` | only for the bundled-services shape (simple-coding-agent only) |
| `compose.litellm.yaml` | only for the LiteLLM backend (simple-coding-agent only): `assets/compose.litellm.yaml.template`, every Worker listed |
| `compose.coding-agent.litellm.yaml` | only for a coding-agent gateway pin (a LiteLLM gateway `url` naming a Docker service): `assets/compose.coding-agent.litellm.yaml.template`, the Workers using such a pin only |
| `.env.worker-<n>` | only for a Worker with its own Worker identity (its own `GITHUB_TOKEN`; simple-coding-agent only) |

The whole point of the profile is that the agent's `check:` must be red exactly
when the target repo's CI gate would be red. Everything else follows from that.

## Pools

An Instance runs N Workers (default 1): one image and one profile, each Worker
its own Compose service with its own `/data` volume. Terms are defined in
`CONTEXT.md` (Instance, Worker, Pool, Worker identity, Worker id, Claim). Read
`references/pools.md` when N>=2, when another Instance shares this one's
Worker identity or targets the same repository with the same backend, or
when a Worker has its own identity. An Instance of another backend on the
same repository is a pairing, not a Pool (step 1, "Pairing with another
backend").

- **One context, one backend.** A Pool is one Instance, one Compose project,
  so it runs on one Docker context with one model backend
  (`docs/adr/0002-one-pool-per-docker-context-without-swarm.md`). Workers on
  another host or behind another backend are a separate Instance.
- **Layout.** The first Worker is service `agent` with volume `agent_data`,
  the only one with `build:`; Workers 2..N are `agent-2..N` with volumes
  `data_2..N` and `pull_policy: never`, so one build serves all. (A
  coding-agent Instance instead runs at most one Worker per Workflow, as
  services `worker` and `worker-2`; see `references/coding-agent.md` and
  `docs/adr/0005-coding-agent-pool-one-worker-per-workflow.md`.) Shared
  settings live in the `x-worker` anchor. Workers are not identical replicas
  (own `/data`, own Worker id), so don't use `--scale` or `container_name`.
- **Worker id scheme.** `<short-name>-<n>`, where `<short-name>` is the
  instance directory without `agent-` (`agent-jsonhub-api-sid` worker 2 →
  `jsonhub-api-sid-2`; the first Worker is `<short-name>-1`; an existing
  Instance named before the backend suffix keeps its unsuffixed short
  name in its Worker ids). Only `[a-z0-9-]`, at
  most 32 characters (upstream refuses anything else at startup). If
  `<short-name>-<N>` is longer, refuse it and ask the user for a shorter
  short-name; it also names the directory, which keeps ids unique across
  Instances.
- **When a Worker id is rendered.** For every Worker that shares its Worker
  identity with another Worker: N>=2 on the shared `GITHUB_TOKEN`, or
  another Instance of the same backend on the same `TARGET_REPO` that the
  user says acts as the same login. An Instance of another backend ignores
  a Worker id's Claim marker, so a pairing with one renders no Worker
  id. A Worker joining a contract Pool through an allowed same-backend match
  gets one too, even as the sole Worker (N=1), whatever its Worker
  identity. Such a Worker's stanza sets `WORKER_ID` and the commit
  author `Claude Code (<worker-id>)`. N=1 on an identity of its own, outside
  any contract Pool, runs without one. Worker ids stay unique across all
  Workers of the contract Pool, across Instances.
- **Contract discovery labels.** Every managed Worker service (`agent` and
  `agent-2..N`) carries four Compose `labels:` when `AGENT_SRC_REF` speaks
  the operator contract (its `agentctl` answers `agentctl --contract 1`):
  `io.github.lbacik.agent-operator.contract` = `1`,
  `io.github.lbacik.agent-operator.instance` = the Managed Instance name,
  `io.github.lbacik.agent-operator.exec-user` = `agent` (the non-root user
  the engine image runs as),
  `io.github.lbacik.agent-operator.backend` = the engine backend chosen in
  step 0 (`simple-coding-agent`, or `coding-agent` with the adapter in
  `references/coding-agent.md`). The
  first Worker's instance name is `<short-name>`; Worker n ≥ 2 uses its
  Worker id `<short-name>-<n>`. Both must match
  `^[a-z0-9][a-z0-9-]{0,62}$`: refuse a short name that would produce a
  non-matching name — for N Workers check `<short-name>-<N>` too — and ask
  the user for another. When a Worker id is rendered, its own scheme (above)
  still applies on top. The labels are set through Compose `labels:` only,
  never as an image `LABEL`, so one-off containers (`docker compose run`)
  are never labelled (contract consumers ignore one-offs anyway). The legacy
  role image label in the Dockerfile belongs to simple-coding-agent's own
  discovery and is not touched. (The coding-agent adapter in
  `references/coding-agent.md` labels `worker` and `worker-2` the same way,
  `worker-2` with the instance name `<short-name>-2`, and renders no Worker
  id.)
- **Minimum upstream.** A Worker id needs `AGENT_SRC_REF` `v0.7.0` or newer
  (lbacik/simple-coding-agent#302); N>=2 on one identity needs `v0.9.0` or
  newer, the first release with the startup recovery fix of
  lbacik/simple-coding-agent#364. Joining a contract Pool from another
  Instance needs `v0.9.0` or newer too — the first release advertising
  `pool` — even at N=1. Contract discovery labels need `v0.9.0` or
  newer, the first release whose `agentctl` answers `agentctl --contract 1`
  (lbacik/simple-coding-agent#334): `main` always speaks the contract, a
  release tag `v0.9.0` or newer speaks it (semantic version comparison), a
  release tag older than `v0.9.0` does not, and any other branch or commit
  SHA speaks it when that checkout contains the upstream contract adapter
  (`simple_coding_agent/contract_adapter.py`), otherwise it does not.
- **Hard rule.** Never run Workers of different Claim protocol versions on
  one Worker identity. Moving an identity to N>=2 follows the order in
  `references/pools.md` (release, stop and drain every Worker on it, upgrade
  and set `WORKER_ID` on all at once, then add Workers). Changing N later
  belongs to the `manage-pool` skill.

## Workflow

Ask the user whenever something below is genuinely ambiguous (use
AskUserQuestion, with a recommended option first). Don't ask about things you
can determine by reading the repository.

### 0. Choose the engine backend

- Ask first which engine backend to deploy (use AskUserQuestion, with the
  recommended option first): `simple-coding-agent` (default) or
  `coding-agent`. This is the deployment adapter (engine image, discovery
  labels, contract capabilities) — not the model route, which is chosen in
  step 1: `references/model-backend.md` for `simple-coding-agent`,
  `references/coding-agent.md` ("Model") for `coding-agent`.
- The backend selects the deployment adapter; target identification, token
  verification and the report stay shared.
- The backend also fixes the mandatory suffix of the new Instance's short
  name (step 1). This table is the only place that maps a backend to its
  suffix; a new backend adds a row:

  | Backend | Suffix |
  |---|---|
  | `simple-coding-agent` | `sid` |
  | `coding-agent` | `rex` |
- `coding-agent`: continue with the coding-agent adapter in
  `references/coding-agent.md` — a derived-image Dockerfile, no stack block,
  no Forge-owned profile, the Workflows the operator selects (`implement`,
  `triage` or both) and at most one Worker per Workflow. Steps 1–2 and 6
  stay shared; steps 3, 5, 7 and 8 branch per backend as marked below.
- `simple-coding-agent`: continue below; the flow is otherwise unchanged.

### 1. Identify the target

- Parse the URL / `owner/repo`. That is `TARGET_REPO`.
- Ask which Docker context the instance will run on (default `orbstack`
  when the user names none). That is the target context for the Fleet check
  below and for every `agentfleet` and `docker` command in this skill
  (`DOCKER_CONTEXT=<ctx>` on the command's environment).
- Propose a directory name `agent-instances/agent-<short-name>`, where the
  short name is `<project>-<suffix>`. `<project>` is the product name, not
  always the GitHub repo name (look at how the existing instances, in
  `agent-instances/` and in `../simple-coding-agent-env/`, are named, e.g.
  `lbacik/globaldb` → project `jsonhub-api`). `<suffix>` comes from the
  backend chosen in step 0 (the table there), e.g. `agent-jsonhub-api-sid`
  for simple-coding-agent or `agent-jsonhub-api-rex` for coding-agent.
  Confirm `<project>` with the user if the repo name is not obviously the
  right one. The user may change `<project>`, never drop or change the
  suffix. The short name `<project>-<suffix>` is what every rule below
  calls `<short-name>`: the directory, the Managed Instance name, the Worker
  ids `<short-name>-<n>` and the commit author. Existing Instances keep
  their names (no suffix) and are never renamed.
- Refuse to overwrite an existing `agent-instances/agent-*` directory; ask
  instead. Create `agent-instances/` itself if it doesn't exist yet.
- Number of Workers N: 1 unless the user asks for more. For coding-agent,
  N follows the Workflow selection in `references/coding-agent.md`
  ("Workflow selection", asked here): 1, or 2 with both Workflows and one
  Worker each, never more. Check the Worker id
  scheme and the contract instance-name pattern in "Pools" against the short
  name (`<short-name>` and `<short-name>-<N>` must each match
  `^[a-z0-9][a-z0-9-]{0,62}$`); refuse a short name that fails either and
  ask for another.
- Fleet check, before scaffolding anything, on the target context. A Target
  Repository holds at most one Instance per engine backend, apart from a
  contract Pool (`docs/adr/0003-one-instance-per-backend-without-label-checks.md`):
  only an existing Instance of the **same** backend as the one chosen in
  step 0 can refuse the new one. An Instance of another backend never
  refuses, on any Docker context. The Fleet check never reads or compares
  selection labels: not the label settings in any `.env`, not the Selection
  or Pickup Labels in any `workflow/workflow.yml`. Keeping two backends'
  Queues apart, or deliberately not, is the operator's responsibility. First
  make sure `agentfleet` is present and speaks the expected contract major,
  as `../debug-agent/scripts/lib/contract.sh` (`require_agentfleet`) does:
  if it is missing or speaks another major, stop with its install command
  and read nothing from the containers.

  ```bash
  DOCKER_CONTEXT=<ctx> agentfleet ls
  ```

  lists the Fleet members on the target context. Then read `identity` of
  every Managed Instance — including stopped ones, through Offline Read
  inside `agentfleet` (never `docker cp`, never a throwaway container):

  ```bash
  DOCKER_CONTEXT=<ctx> agentfleet identity <name>
  ```

  (`--json` for machine reading.) Compare each identity's Target Repository
  case-insensitively with `TARGET_REPO` (lowercase both sides before
  comparing), and take its engine backend from the same identity:

  ```bash
  DOCKER_CONTEXT=<ctx> agentfleet identity <name> --json \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r["repository"].lower(), r["backend"])'
  ```

  Then scan legacy Instances' env files for the same repository — file names
  only, reading just the `TARGET_REPO` line so no token is read into the
  output or printed (the `-i` makes the comparison case-insensitive, as in
  the Fleet check above; the pattern also tolerates an `export` prefix and
  spaces around `=`):

  ```bash
  grep -liE "^[[:space:]]*(export[[:space:]]+)?TARGET_REPO[[:space:]]*=[\"']?<owner>/<repo>[\"']?[[:space:]]*$" agent-instances/*/.env ../simple-coding-agent-env/agent-*/.env 2>/dev/null
  ```

  (The sibling path covers reference instances when that project is
  available; it may match instances that run on another context, so confirm
  with the user before treating such a match as a clash.)
  Take each env-scan match's backend from the
  `io.github.lbacik.agent-operator.backend` discovery label in the
  `compose.yaml` next to it, never from its `.env` settings:

  ```bash
  grep -hoE 'io\.github\.lbacik\.agent-operator\.backend: *"?[a-z-]+' <dir>/compose.yaml | head -n 1
  ```

  A labelled match is a Managed Instance: when `agentfleet` already listed
  it on the target context, its `identity` decides, as above. A match with
  no discovery label is an unlabelled legacy Instance, and that is always
  simple-coding-agent, because the coding-agent adapter always renders the
  labels. For a match in `../simple-coding-agent-env`, confirm the backend
  read from its files with the user in the same question as its context
  above; when it is another backend, that one question is also the pairing
  confirmation below.
  List the Fleet's instance names to check the short name against:

  ```bash
  DOCKER_CONTEXT=<ctx> agentfleet ls --json \
    | python3 -c 'import json,sys; [print(i["name"]) for i in json.load(sys.stdin)["instances"]]'
  ```

- Refusals from the Fleet check (same backend only):
  - Another instance of the backend chosen in step 0 targeting the same
    repository — found running or stopped through `agentfleet identity`
    (Offline Read), or as an unlabelled legacy Instance through the env
    scan above — refuses the new one: stop and tell the user which instance
    holds the repository. A same-backend match is allowed only when both
    sides form a contract Pool:
    - every existing Managed Instance of that backend on that Target
      Repository on the target Docker context reports `pool` in
      `identity.capabilities` (`agentfleet identity`, including stopped ones
      through Offline Read), **and**
    - the new Instance will advertise `pool`: the `simple-coding-agent`
      backend at an `AGENT_SRC_REF` that speaks the contract (`main`, a tag
      `v0.9.0` or newer, or a branch/SHA whose checkout contains
      `simple_coding_agent/contract_adapter.py` — the same rule as the
      contract discovery labels; minimum upstream `v0.9.0`), with a Worker
      id rendered for every one of its Workers.
    Otherwise refuse as today and name the instance holding the repository.
    An unlabelled legacy match from the `TARGET_REPO` env scan cannot report
    capabilities, so it always refuses a new simple-coding-agent Instance,
    regardless of ref. An existing same-backend Instance that lacks `pool`
    in `identity.capabilities` refuses too: tell the user to give its
    Workers Worker ids first with the `manage-pool` skill (upgrading it to
    `v0.9.0` or newer when needed) — `create-agent` never changes existing
    Instances (the one exception, an explicitly requested coding-agent
    upgrade, is in `references/coding-agent.md`).
    `coding-agent` never advertises `pool`, so a second coding-agent
    Instance on a repository that already has one always refuses.
  - A short name already present in the Fleet of the target context is
    refused even for another repository: the Managed Instance name
    (`<short-name>`, or `<short-name>-<n>` for Worker n ≥ 2) must be unique
    there. Ask for another short name.
  - When a same-backend match is allowed through `pool` above, fall
    through to the shared-login question: for each matching Instance, ask
    the user whether that Instance's `GITHUB_TOKEN` acts as the same GitHub
    login as this one's. Never compare or print the tokens.
    - Same login: the Pools reference's "Hard rule and the order to N>=2"
      applies across Instances — the other Instance must already be drained
      and upgraded to the same Claim protocol before the new one starts.
      Tell the user what the other Instance needs; `manage-pool` carries it
      out.
    - Different logins: there is no shared-identity Claim hazard, but
      `PEER_LOGINS` must list every login working the Queue on both
      Instances. Ask before setting it, and tell the user the other Instance
      needs the same list.
    N stays 1 unless the user asks for more, also when the new Instance
    joins a contract Pool — and that single Worker still gets a Worker id.
- Pairing with another backend. When an Instance of a different backend
  holds the repository (a Managed Instance on any context, an unlabelled
  legacy Instance, or a sibling-project match), it does not refuse and does
  not enter the Pool rules or the shared-login question above. Before
  scaffolding, name each such Instance to the user — instance name,
  backend, and Docker context (or path, for a match found only on disk) —
  and ask once (AskUserQuestion) to confirm the pairing. If the user
  declines, stop. Record the pairing for the report (step 8). Read no
  tokens and no label configuration for it.
- Engine ref (which commit the image builds from) defaults to `main`. If the
  user names a tag — e.g. "build it against tag v1.4.0" — use that instead;
  see step 3. It's not a one-time choice: it lands in `.env` as an ordinary
  setting (`AGENT_SRC_REF` for simple-coding-agent, `CODING_AGENT_REF` for
  coding-agent), so it can be changed later (and the image rebuilt) without
  touching any other file.
- Ask which model the agent should use. For simple-coding-agent, recommend
  its route as `references/model-backend.md` ("Choosing the route") says;
  read it now. Offer the model an existing instance uses as an option. The
  choice decides the `.env` model settings, `MAX_BUDGET_USD` and whether
  `compose.litellm.yaml` is generated (step 5). For coding-agent, choose
  every pin the declared Workflows use as `references/coding-agent.md`
  ("Model") says — `main` for `implement`, `triage` and its Advisor pin
  `triage-advisor` for `triage` — each a direct `provider:` pin (Anthropic,
  OpenAI at the documented ref) or a LiteLLM `gateway:` pin (the Meta
  `muse-*` route through the gateway), and confirm each pin's prices and
  token keys with the operator. The choices decide each pin's route line,
  which model keys each Worker gets in `compose.yaml` and which stay active
  in `.env`, and whether `compose.coding-agent.litellm.yaml` is generated
  (step 5). A gateway pin puts the whole Instance on the gateway's Docker
  context.

### 2. Get the target's source

Prefer a local checkout if the user has one (ask if they mentioned one or if
`git remote -v` of a likely path matches). Otherwise shallow-clone into the
scratchpad:

```bash
git clone --depth 1 git@github.com:<owner>/<repo>.git <scratchpad>/target   # user's own credentials
```

If that fails for a private repo, fall back to the `GITHUB_TOKEN` of an
existing instance's `.env` (`agent-instances/agent-*/.env`, else
`../simple-coding-agent-env/agent-*/.env`) without printing it (e.g. via
`gh repo clone` with `GH_TOKEN` set in the command's environment).

### 3. Get the agent's source (`AGENT_SRC_REF`, simple-coding-agent)

This step is the `simple-coding-agent` deployment adapter. For `coding-agent`
see step 3b instead. Generated agents build from
`https://github.com/lbacik/simple-coding-agent.git#<AGENT_SRC_REF>`, not the
local checkout. `AGENT_SRC_REF` defaults to `main`; if the user names a tag
(or branch/commit) of `simple-coding-agent` to pin instead, use that value
verbatim — it goes straight into the git URL fragment, which Docker's git
context resolves like `git checkout <ref>` (works for tags, branches and
commit SHAs alike). Don't ask for one unprompted; only use a non-`main` ref
when the user gave it. A rendered Worker id needs a minimum ref ("Pools",
"Minimum upstream"): if a pinned ref is older, ask the user to bump it.
Contract discovery labels need a ref whose `agentctl` speaks the contract
("Pools", "Minimum upstream": `v0.9.0` is the minimum release, `main` always
qualifies, release tags compare semantically against `v0.9.0`, other
branches/SHAs qualify when the checkout contains
`simple_coding_agent/contract_adapter.py`): render the instance with labels
when the cloned ref qualifies, without them when it does not. A pinned tag
older than `v0.9.0` stays on the legacy path — tell the user bumping to
`v0.9.0` or newer moves it to the contract path.

Shallow-clone that same ref into the scratchpad and read, at that commit
(`git clone --depth 1 --branch <AGENT_SRC_REF> ...` — for a bare commit SHA,
clone without `--depth 1` or `--branch` and `git checkout <sha>` instead,
since shallow clones can't fetch an arbitrary commit by SHA):

- `simple_coding_agent/config.py` — the profile's allowed keys in
  `load_repository_profile` (currently
  `setup, check, base_branch, timeout, setup_timeout, env, model_instructions`);
  an unknown key makes the agent refuse the profile. Do **not** copy runtime versions from it:
  the Dockerfile derives them at build time (see "Runtime versions" in step 5).
  To upgrade the agent and its runtime, move upstream or `AGENT_SRC_REF` and
  rebuild.
- `simple_coding_agent/command_runner.py` — profile commands run with a
  minimal environment: only `PATH` (os.defpath + `PROFILE_EXTRA_PATH`) plus the
  profile's `env:`. No HOME, no shell profile, credentials stripped.
- `Dockerfile`, `scripts/install-skills.sh`, `.env.example` — for anything that
  changed since the templates here were written. If upstream diverged from
  `assets/Dockerfile.template` in a way that matters (new COPY paths, new
  runtime step), follow upstream and tell the user.
- `docker/managed-settings.json` — the template copies it to
  `/etc/claude-code/managed-settings.json` (Meta model pricing; without it
  `total_cost_usd` is 50-250x too high). Refs older than upstream PR #143
  (including tags up to v0.2.3) don't have it, and the `COPY` fails the
  build. For such a ref, drop that step and tell the user that USD figures
  use the CLI's default-model rates.

### 3b. Get the agent's source (`CODING_AGENT_REF`, coding-agent)

This step is the `coding-agent` deployment adapter (step 0 chose it; the
rest of steps 3–4 above do not apply — there is no stack block and no
Forge profile). Generated agents build from
`https://github.com/lbacik/coding-agent.git#<CODING_AGENT_REF>`, not a local
checkout. `CODING_AGENT_REF` defaults to `main`; if the user names a tag (or
branch/commit) to pin instead, use that value verbatim — it goes straight
into the git URL fragment, which Docker resolves like `git checkout <ref>`.
Don't ask for one unprompted.

Shallow-clone that same ref into the scratchpad and read, at that commit:

- `compose.yaml` and `compose.gateway-example.yaml` — the deployment this
  adapter mirrors (services, hardening, state path `/var/lib/coding-agent`,
  the worker's `run` flags, workflow mount) and the worker env wiring for a
  gateway pin (`LITELLM_PROXY_API_KEY`, never a `LITELLM_PROXY_URL`
  variable). If the ref's hardening, flag or mount layout diverged from
  `assets/compose.coding-agent.yaml.template` in a way that matters, follow
  the ref and tell the user.
- `Dockerfile` — the `deployment` stage this adapter derives FROM (its
  baked roots, preparation commands and verification). The instance
  Dockerfile replays that sequence against the instance's `workflow/`
  starting from empty bundle and store directories; if the ref's sequence
  diverged in a way that matters, follow the ref and tell the user.
- `src/coding_agent/provider/config.py` — the code-owned direct
  (`provider`, `model`, `endpoint`) pins and their prices. Only a pair from
  that table (Anthropic and OpenAI at the documented ref) may go into a
  direct pin; anything else refuses startup. Every pin, direct or gateway,
  declares its own `context-window-tokens`, `context-threshold-tokens` and
  `output-cap-tokens` (see `src/coding_agent/provider/pinned_model.py`,
  the recommended values in `docs/ops/workflow-configuration.md` and the
  "Gateway pins" section below).
- `docs/ops/workflow-configuration.md` and `docker/deployment/workflow.yml`
  (or their equivalents at the ref) — the `version: 4` file shape the
  template mirrors: `version: 4`, the three token keys on every pin, the
  `effective-tokens` meter in every `limits` block, the `skills:` Skill
  Bundle declaration, and the reviewed `skill-policy.json` beside the
  YAML. A ref older than coding-agent 0.4.7 accepts only `version: 3`:
  render this template only at 0.4.7 or later. Re-check the
  "Gateway pins" and "Recommended gateway configuration" sections (gateway
  shape, the pin-violation guarantee, the Provider Capability Assertion) and
  the contract's pin-violation rows (§12, §16.3: the Attempt ends
  `interrupted` and the Worker halts). The template keeps
  the Forge step graph (`preflight → process → validate → self-review →
  push → open-pr`, plus `explain-blocked`, the reserved `ai-handoff` and
  `hard-handoff`); do not adopt the reference's smaller `implement` graph
  or its `review` workflow.
- `docker/deployment/skill-policy.json` (or its equivalent at the ref) —
  the reviewed policy for the reference Skill Bundle selection. For the
  reference bundle (`implement` alone), copy it verbatim into the
  instance's `workflow/` (step 5); Forge keeps no copy of its own. Any
  other bundle (one with `triage`) gets its policy drafted and completed in
  step 5 ("Drafting the skill policy" in `references/coding-agent.md`). The
  skill writes only the decisions the operator approved and never approves
  on its own (`docs/adr/0004-forge-drafts-skill-policy-operator-approves.md`);
  a different bundle membership or source ref means drafting and reviewing
  again.
- Every prompt file the rendered Workflow Configuration names. For
  `implement`, at the documented ref that is
  `docker/deployment/prompts/implement-policy.md` and
  `examples/prompts/handoff.md` (`handoff.md` lives only under
  `examples/prompts/` at the ref) — copy each verbatim into the instance's
  `workflow/prompts/` (step 5), recording the source path per file. For
  `triage`, copy `assets/prompts/triage-policy.md` and
  `assets/prompts/triage-advisor.md` verbatim from this skill. They carry
  no placeholders. `config validate` stats every named prompt file, so a
  named file must exist next to `workflow.yml`.
- With `triage` selected, whether the ref is `v0.5.0` or newer
  (`references/coding-agent.md`, "Workflow selection"): refuse `triage` at
  an older ref and say why.
- `src/coding_agent/agentctl.py` (the contract CLI) — whether it documents
  a private-IPC socket directory needing the worker's operator tmpfs, and
  which Operator Capabilities the Worker advertises. If the ref documents no
  such directory, drop that tmpfs entry from the rendered `compose.yaml`.

Then run the target checkout checks in `references/coding-agent.md` ("Target
checkout checks") against the step-2 checkout at its default branch (the
revision that becomes `target.base_branch` in step 5), before
writing anything: confirm `docs/agents/project-profile.yml` exists there,
and that its declared toolchain is inside the Supported Toolchain Matrix at
the chosen `CODING_AGENT_REF`. A missing Project Profile is reported (searched
location and revision) and scaffolding continues only on the operator's
explicit decision (AskUserQuestion). An out-of-matrix runtime requirement is
reported as an Unsupported Environment naming the offending runtime and the
supported range, and the skill asks before scaffolding anyway. When the
profile is present and the toolchain matches, proceed without prompting.
Never write a Forge-owned profile on this path.

### 4. Analyze the target stack (simple-coding-agent)

For `coding-agent`, skip this step: there is no stack block and no profile,
and the target checkout checks already ran in step 3b.

Read, in roughly this order:

1. `.github/workflows/*` (or other CI) — find the **gating** jobs. Look for
   `continue-on-error`, "advisory" / "watcher" comments, jobs only on
   `schedule`, and which workflow a release depends on. Gating checks go into
   `check:`; advisory ones (dependency audits, "is a newer SDK out") do not,
   because they go red for reasons outside the repo.
2. `AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md` / README — the "validation"
   commands the maintainers expect from an agent.
3. The repo's own `Dockerfile` and version files (`.nvmrc`, `.tool-versions`,
   `go.mod`, `pyproject.toml` `requires-python`, `composer.json` platform…) —
   exact runtime versions. Match CI's version, and note any comment saying why
   a newer one breaks things.
4. CI `services:` and env — does the test suite need a database, Redis, a
   browser, etc.? Env vars CI sets for tests go into the profile's `env:`.

Summarize what you found to the user in a few lines (stack, runtime version,
setup commands, check commands, services) and ask about anything unresolved,
for example:

- a check that is slow or flaky — include it or not?
- a service tests need — bundle it in the image (bundled-services shape) or
  skip those tests?
- several plausible runtime versions.
- Node: the claude-code CLI itself needs Node ≥ 20, and the image has one
  Node. If the target needs a different Node major, one Node has to satisfy
  both; if impossible, say so.

### 5. Generate the files

For `coding-agent`, generate the deployment from
`references/coding-agent.md` instead of this step: `compose.yaml` from
`assets/compose.coding-agent.yaml.template` (the derived image is tagged
`coding-agent:<short-name>`, the `engine` base
`coding-agent-engine:<short-name>`; the engine's git URL reads the ref from
`CODING_AGENT_REF` in `.env` — nothing to fill in here), `Dockerfile` copied
verbatim from `assets/Dockerfile.coding-agent.template`,
`workflow/workflow.yml`
from `assets/workflow.coding-agent.yml.template` with the prompt files
(step 3b: `implement`'s from the ref checkout, `triage`'s from
`assets/prompts/`) and `workflow/skill-policy.json` (the reference
bundle's copied verbatim from the ref checkout's `docker/deployment/`, any
other bundle's drafted and completed as "Drafting the skill policy" in
`references/coding-agent.md` says), and
`.env`/`.env.example` from
`assets/env.coding-agent.example.template` with the real secrets —
plus `compose.coding-agent.litellm.yaml` from
`assets/compose.coding-agent.litellm.yaml.template` when a Worker uses a
gateway pin whose `url` names a Docker service (no placeholders; keep the
entries of exactly those Workers).
Leave
`WORKER_CPUS`, `WORKER_MEM_LIMIT` and `WORKER_PIDS_LIMIT` commented out (the
`x-agent` defaults). No
`{{...}}` or prompt-file gap may remain: every prompt the YAML names must
exist next to it, and a policy copied for the reference bundle must be
byte-identical to the one at the ref. The rest of this step is
simple-coding-agent only.

On the `coding-agent` path, fill the template's placeholders from the
operator's choices. The Workflow selection (`references/coding-agent.md`,
"Workflow selection") decides which `workflow-implement-*` and
`workflow-triage-*` ranges stay in `workflow.yml` (markers deleted either
way), `{{SKILL_INCLUDE}}`, the `{{WORKFLOWS}}` build argument and each
Worker's `{{WORKER_WORKFLOW}}` / `{{WORKER_2_WORKFLOW}}` in `compose.yaml`
(for a single Worker, delete every `worker-2-begin` … `worker-2-end` range).
Then: the Target Repository, its default branch, and every declared pin
(`{{MAIN_*}}` for `implement`, `{{TRIAGE_*}}` and `{{ADVISOR_*}}` for
`triage`): its route line (`{{<PREFIX>_ROUTE}}`: `provider: <provider>` or
`gateway: {kind: litellm, url: <url>}`), model, endpoint, effort, key
variable, confirmed prices and its three token keys (on a direct pin they
default to the upstream recommendation for the model — 1,000,000 / 80,000 /
32,000 for `claude-sonnet-5`, 1,050,000 / 100,000 / 32,000 for
`gpt-5.6-luna`; on a gateway pin all three are asked, never defaulted).
For `implement`: the Selection Label, the Attempt Ceiling (all four
meters, `{{LIMIT_EFFECTIVE_TOKENS}}` for the `effective-tokens` meter), the
reserved `ai-handoff` effective-tokens allowance
(`{{HANDOFF_EFFECTIVE_TOKENS}}`, see below), and the two non-reserved Step
Allowances (`{{PROCESS_LIMIT_COST_USD}}` default 12,
`{{SELF_REVIEW_LIMIT_COST_USD}}` default 3; each is shared by all
executions of its step). For `triage`: its Attempt Ceiling
(`{{TRIAGE_LIMIT_*}}`, checked against the Admission hold of both the
triage pin and the Advisor pin, as "The `triage` Workflow" in the reference
says). In each Worker stanza of `compose.yaml`, keep exactly the model key
lines of that Worker's own pins (its Workflow's pin, plus the Advisor pin
for `triage`). In `.env` (and `.env.example`), leave every key some pin
names active and the others commented out; when a Worker uses a gateway pin
with a service-name `url`, additionally uncomment `COMPOSE_FILE` and set
`GATEWAY_NETWORK` to the gateway's network (a host-URL gateway needs no
overlay). The `implement` limits below apply only when `implement` is
declared. The mapping of every
simple-coding-agent `.env` budget, turn, timeout and retry key to its
coding-agent counterpart lives in `references/coding-agent.md` ("Limits:
where simple-coding-agent's settings went"): point the operator there when
they look for a missing `.env` key, and keep budgets out of `.env` — the
Effective Configuration digest stays the only budget authority. When asking
the operator for the Attempt Ceiling, first show the resulting Work Pool per
meter — the ceiling minus the reserved
`ai-handoff` allowance (`cost-usd: 1`, `effective-tokens: 150000` or the
pin's Admission floor below, `tool-calls: 30`, `wall-clock-minutes: 5`),
computed separately for each of the four meters —
and list the non-reserved Step Allowances that must fit inside it (`process`,
`self-review`), so the operator sees up front whether the ceiling leaves room
(for example, a 5 USD ceiling leaves a 4 USD Work Pool on the cost meter that
the default 12 USD `process` allowance does not fit). Then check the Work Pool
fit before writing anything: the Work Pool is the Attempt Ceiling minus the
reserved `ai-handoff` allowance, per meter, and every non-reserved Step
Allowance must fit in it on every meter it sets — otherwise
`config validate` refuses the file. When an allowance does not fit (or the
ceiling is not larger than the reserve on some meter), stop before writing the
Workflow Configuration, name each step with its allowance and the Work Pool,
and ask the operator for new allowances or a higher ceiling; never scale or
clamp allowances by yourself, and never change the `ai-handoff` reserve
beyond the floor rule that follows. Version 4 also requires every limit that
declares `effective-tokens` or `cost-usd` to hold one maximal Admission
hold: `effective-tokens` >= Usable Threshold + `output-cap-tokens`, where the
Usable Threshold is `context-threshold-tokens` minus 2,000 (the code-owned
safety margin plus request overhead), and `cost-usd` >= Usable Threshold ×
`input` (max(`input`, `cache-write`) on a gateway pin) + `output-cap-tokens`
× `output`, both priced per MTok. Render `{{HANDOFF_EFFECTIVE_TOKENS}}` as
150000, or as that floor when the pin's threshold needs more (a gateway pin
with a 400,000 threshold and a 32,000 cap needs 430,000), and tell the
operator which. Check the same floor on the Attempt Ceiling, the Work Pool
and every Step Allowance that declares the meter (`process` and
`self-review` declare only `cost-usd`); when one falls short, stop and ask
as above. A Skill Bundle other than the reference one (any bundle with
`triage`) gets its `skill-policy.json` drafted and completed with the
operator's decisions before the image builds; the skill writes only the
decisions the operator approved and never approves on its own.

**Dockerfile** — start from `assets/Dockerfile.template`. Replace the
placeholders, and put the target's toolchain in the `STACK` block (language
runtime, package manager, system libs). Keep the header comment honest: what
the target is, what its CI gate is, why this toolchain/version, what is
deliberately absent. The existing Dockerfiles comment every non-obvious
choice (e.g. why Node 22 and not 23); do the same, because the next person
upgrading needs the reason, not just the value.

**Profile** (`simple-coding-agent-profile.yml`) — a YAML mapping:

```yaml
setup: [...]        # install deps, reset bundled services
check: [...]        # the CI gate, same order as CI (fastest/most fundamental first)
base_branch: main   # the repo's actual default branch
timeout: 600        # seconds for the whole check sequence
setup_timeout: 300
env:
  PATH: "/usr/local/bin:/usr/bin:/bin"   # plus toolchain dirs if needed
  HOME: "/home/agent"                    # writable cache; also where git finds the image's identity
  # CI's test env vars
model_instructions: |   # guidance appended to the model's prompt, see below
  ...
```

Rules that come from how CommandRunner works:

- Commands run via `sh -c`, one at a time, first non-zero exit stops the list.
- Set `PATH` explicitly to include every toolchain directory the commands need
  (e.g. `/usr/local/go/bin`, `~/.cargo/bin` spelled out as `/home/agent/.cargo/bin`).
- Use CI's own non-interactive flags (`npm ci`, `composer install --no-interaction`,
  `pip install -e '.[dev]'`, `go mod download`…).
- No commands that need root — daemons are started by the entrypoint, the
  profile only waits for them and resets them.
- Header comment: which CI files it mirrors, what was left out and why.

**Model instructions.** `model_instructions` (a string; `AGENT_SRC_REF`
v0.4.1+, older refs refuse a profile carrying it) is the one profile key the
model reads: the agent appends it to every starting prompt, continuations
included, under "Repository guidance". It is
guidance, weighed against the issue and the target's `AGENTS.md`, so state
explicitly when it takes precedence. The prompt already lists the `check:`
commands and the `env:` names; spend the text on what the model can't see:

- **Branch rule, in every profile.** The agent checks out
  `agent/issue-<number>`, counts only commits on it, and pushes and opens the
  pull request itself; its hook blocks the model's push. A model that follows
  an issue or `AGENTS.md` asking for its own branch (`feat/*`, "push and open
  a PR") commits there, and the attempt ends `no_changes` with the work
  stranded in the clone (`agent-jsonhub-web-ui` #94). Copy this block
  verbatim:

  ```yaml
  model_instructions: |
    Branch and publication rules for this agent. They override any branch, push
    or pull-request instruction in the issue, its comments or AGENTS.md:

    - Work and commit on the branch that is checked out when you start
      (`agent/issue-<number>`). Do not create, switch or rename branches
      (`git checkout -b`, `git switch`, `git branch -m`), even if the issue names
      a branch. Only commits on this branch count; commits anywhere else are
      discarded and the attempt ends as "no changes".
    - Do not push and do not open a pull request. The agent runs the completion
      gate, pushes this branch and opens the pull request against `main` itself.
    - If the issue asks for a branch name or for something to be stated in the
      pull request, put that information in your final summary instead.
  ```

  Replace `main` with the profile's `base_branch`, and name the target's own
  conflicting rule when it has one (e.g. "including its rule 10").
- **What the gate implies**, after the branch rule: why a command is guarded
  (an empty-repo bootstrap), where the toolchain's environment lives (a venv
  outside the checkout), which tests must skip because the image lacks a
  service or tool. `agent-instances/agent-dashboard/` is an example.

Comment the block in the profile with the reason for each rule, as for every
other key.

**Runtime versions.** Upstream at `AGENT_SRC_REF` is the single source. No
version numbers are copied into the instance:

- `claude-agent-sdk` is decided only by upstream's `pyproject.toml` (installed
  by `pip install -e .`). Never pin it in the Dockerfile or `.env`; upstream
  pins it exactly, so an instance pin would be overwritten anyway.
- The Claude Code CLI is the one bundled inside that SDK release. The agent
  runs and verifies only that binary, so the image installs no separate
  `@anthropic-ai/claude-code`, and `CLAUDE_CODE_VERSION` has no effect
  (upstream PR #189). Refs older than that PR still need the npm-installed
  CLI and the `/etc/agent-runtime.env` entrypoint of the earlier templates;
  for such a ref, tell the user and build from a newer one instead.
- Upgrade: move upstream or change `AGENT_SRC_REF`, then `docker compose build`
  (and recreate the container).

**compose.yaml** — `assets/compose.yaml.template`, image tag
`simple-coding-agent:<short-name>`. Its `agent-src` context URL reads the ref
from `AGENT_SRC_REF` in `.env` (`${AGENT_SRC_REF:-main}`) — nothing to fill in
here; the actual ref is set in `.env.example`/`.env` below. Fill the
`x-worker` anchor's `environment:` block as described next. Keep its
`init: true` in every shape, bundled-services included: the agent doesn't
reap orphaned processes as PID 1 (the template comment explains it). Then
render the Workers (see "Pools"):

- Keep a Worker's Worker id block only when that Worker gets a Worker id;
  otherwise delete it.
- Repeat the `agent-<n>` stanza and its `data_<n>` volume for n = 2..N,
  replacing `<n>`; for N=1 delete both. Delete the stanza's `env_file` unless
  that Worker has its own Worker identity (`references/pools.md`).
- Render the contract discovery labels ("Pools", "Contract discovery
  labels") only when `AGENT_SRC_REF` speaks the contract (`main`, a release
  tag `v0.9.0` or newer, or another branch/SHA whose checkout contains
  `simple_coding_agent/contract_adapter.py`); otherwise delete
  both labels blocks — the rendered model (a tag older than `v0.9.0`, or a
  ref without the adapter) is then unchanged from today.
  Never set them as an image `LABEL`; ad hoc `docker compose run`
  containers are never labelled.
- If the anchor's `environment:` block was deleted, delete every
  `<<: *worker-environment` line too.
- No `{{...}}` or `<n>` may remain.

Leave the resource limits (`cpus`, `mem_limit`, `pids_limit`) as they are;
they are tuned through `WORKER_*` in `.env` (below).

**compose.litellm.yaml** (LiteLLM only) — list every Worker of `compose.yaml`
the same way: one `agent-<n>` entry per further Worker, none for N=1.

**The model's shell environment.** The profile's `env:` reaches only
CommandRunner. While the model works, its Bash tool inherits the *container*
environment: `.env`, compose `environment:` and Dockerfile `ENV`. Anything the
container doesn't set falls back to the target repo's own defaults (a
committed `.env`, `config/*.yml`, `settings.py`…). When those defaults point
somewhere else, the model develops against one environment and the final check
runs in another. That's a *split environment*, and it shows up late as an
`incomplete` outcome. `agent-paysubscriptions` #38: the repo's `.env` has a
PostgreSQL `DATABASE_URL`, and only the profile pointed at the bundled MySQL.
The model had no database, wrote a migration with PostgreSQL quoting, and the
final `migrations:migrate` failed.

Go through every key in the profile's `env:` and compare it with the value the
target repo's defaults would give the model:

- **Copy it** into compose `environment:` when the default points at a
  service the image doesn't have or a different one (`DATABASE_URL`,
  `REDIS_URL`, a broker DSN), when the variable is missing from the defaults
  and the app fails to boot or a service fails to build without it, or when
  the default is known to break (a CI comment such as "the Doctrine transport
  rejects these options"). Use the same value as the profile.
- **Leave it to the defaults** when it selects a CI-only mode that would
  mislead interactive work. For example, `APP_ENV=prod`/`APP_DEBUG=0` makes a
  kernel serve a stale cache after edits, and a test runner usually forces
  its own env anyway. Also leave out keys the defaults already set to an
  equivalent value, `PATH` and `HOME` (the Dockerfile sets them), and
  anything secret.

Put the list in the `x-worker` anchor's `environment:`, not in `.env`: the
values aren't secret, and a versioned file keeps them next to their reasons.
Write it as a mapping (`KEY: value`), not a list (`- KEY=value`): each Worker
id block merges it with `<<: *worker-environment`, which only works on a
mapping. Comment
each entry with why the default isn't enough, and say that it must match the
profile, which stays the source of truth. If nothing needs copying, drop the
block and say so in the report.

**.env.example / .env** — `assets/env.example.template`. For `.env`:

- Copy `GITHUB_TOKEN`, the model credential (`META_API_KEY`, or
  `MODEL_API_KEY` — see the next item), `MAX_BUDGET_USD`, `MAX_TURNS`,
  `MAX_BUDGET_TOKENS`, `SOFT_THRESHOLD_PERCENTAGE` from an
  existing instance's `.env`: `agent-instances/agent-*/.env` first, else
  `../simple-coding-agent-env/agent-*/.env`. If they disagree, ask which to
  use. If there is none, ask the user to fill those values in. An instance
  that predates the token settings may lack the last two: use
  `MAX_BUDGET_TOKENS=4000000` and `SOFT_THRESHOLD_PERCENTAGE=0.3` (the
  upstream default 0.2 leaves too few tokens for the handoff turns). Copy with
  shell tools (grep/sed into the file) so secrets never appear in your output;
  when showing the result, redact values.
- Model backend: set up the route chosen in step 1 as described in
  `references/model-backend.md` ("Settings per route"). The template defaults
  to Meta (`META_API_KEY`, `MODEL_*` commented out); for another route,
  uncomment the matching template block and copy its values from a source
  instance that uses the same route, else ask. Set `MAX_BUDGET_USD` by that
  reference's "Budget" rule.
- `TARGET_REPO`, `PROFILE_PATH=/opt/agent-profile/simple-coding-agent-profile.yml`,
  and `AGENT_SRC_REF` (from step 3 — `main` unless the user pinned a tag).
- Conflict requeue is opt-in and off by default: leave `MAX_CONFLICT_ATTEMPTS`
  commented out (`0`) unless the user asks for it. With N > 0, every poll
  reads the open pull requests and the Queue claims an issue carrying the
  `merge-conflict` label ahead of other work — the Worker applies the label
  itself on a conflicting `agent/issue-N` branch, and a human may also apply
  it by hand. The Conflict attempt that follows rebases the branch onto the
  base and force-pushes only when setup plus one profile check are green, with
  no model call; after N consecutive failed Conflict attempts the Worker adds
  `ready-for-human` and never removes it, so a human hands the issue back by
  removing the label. The setting is independent of `PR_AUTO_MERGE` (conflicts
  block manual merges too) and needs `AGENT_SRC_REF` v0.6.0+. Say in the report
  whether it was left off or set to N.
- Resource limits: leave `WORKER_CPUS`, `WORKER_MEM_LIMIT` and
  `WORKER_PIDS_LIMIT` commented out (the `x-worker` defaults), except for the
  bundled-services shape (see its reference). Never put `WORKER_ID` in
  `.env`; it belongs to each Worker's stanza in `compose.yaml`.
- A Worker with its own Worker identity: `.env.worker-<n>`, as
  `references/pools.md` describes.
- Ask before adding any other setting the user didn't ask for.
- Alternative configurations (e.g. `.env.claude` for the Anthropic backend):
  only if the user asks. Copy `.env`, change what differs and set
  `AGENT_ENV_FILE=.env.claude` in the copy; leave `AGENT_ENV_FILE` unset in
  `.env`. `--env-file` alone only swaps the interpolation file, while
  compose's `env_file: ${AGENT_ENV_FILE:-.env}` decides what the container
  loads. Every command then takes `--env-file .env.claude`. Without `-p` both
  configurations share one container and the `agent_data` volume. A LiteLLM
  alternative (`.env.litellm`) also carries `COMPOSE_FILE` and
  `GATEWAY_NETWORK`, and needs `compose.litellm.yaml` in the instance.

### 6. Verify the token

A fine-grained PAT only works for repositories it was granted. Plain `GET`s
cannot prove that: a public repository answers `200` to every valid token,
even one with no grant on it. Probe the write grant instead, without
printing the token:

```bash
for e in issues pulls git/blobs; do
  curl -s -o /dev/null -w "$e %{http_code}\n" -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Content-Type: application/json" -d '{}' \
    "https://api.github.com/repos/<owner>/<repo>/$e"
done
```

The empty bodies are safe: GitHub checks the permission before it validates
the body, so a token without the grant gets `403`, while a token with it
fails body validation (`422`) — nothing is created either way. Never use
`POST .../git/refs` as a probe: it validates the body first, so it answers
`422` with or without the grant.

- All three `422` → write access OK (a fine-grained PAT's permission set
  applies to every repo it covers, so write access here matches the other
  agents that use it). Note that the `permissions` field of `GET /repos`
  reflects the *user's* rights, not the token's, so it proves nothing.
- Any `403` → the token lacks that permission or the repository was never
  granted to it: add the repo to the token (Settings → Developer settings →
  Fine-grained tokens → Repository access); contents, pull requests and
  issues need read & write.
- Any `401` → the token itself is invalid, expired or revoked: fix the
  token, not the grant.
- Any `404` → the repository name is wrong, or the token cannot see the
  repository at all (a private repository it was not granted, or any
  repository hidden from a token with no access to it): fix the name or
  grant the token access to it.
- Anything else → report the code and stop; do not treat it as success.

### 7. Validate

For `coding-agent`, validate as `references/coding-agent.md` ("Validation")
says — `docker compose config -q`, `docker compose build` (which runs
`config validate` once per declared Workflow, `prepare-skill-bundle --mode
install` and `verify-skill-bundle` inside the derived image and fails when
any of them fails), secret-free `config validate --workflow <id>` through
the built `agent` seat once per declared Workflow (no secrets set, no
mount: the package is baked in), `startup-check --repo`
with the instance's token, the token write-scope check of step 6, and the
optional `validate` run against a target checkout — and report which passed
and which remain unverified. The rest of this step is simple-coding-agent
only.

- Profile: load it with the agent's own loader from the cloned agent source
  (`python3 -c "from simple_coding_agent.config import load_repository_profile; ..."`
  with that clone on `sys.path`; needs PyYAML).
- `docker compose config -q` in `agent-instances/agent-<name>/` (with
  `--env-file` for an alternative configuration). Check that
  `docker compose config` shows, on every Worker service, `init: true`, the
  `cpus` / `mem_limit` / `pids_limit` limits and its own volume; with a
  Worker id, a distinct `WORKER_ID` and the matching `GIT_AUTHOR_NAME` per
  Worker; and `build:` on `agent` only. When the ref speaks the contract,
  every managed Worker service carries all four discovery labels with its
  own instance name; otherwise no service carries an `agent-operator` label.
  For LiteLLM, also check that it lists
  the gateway network on every Worker.
- The split-environment check: in the built image, as `agent` in a target
  clone and *without* the profile's `env:`, run the app's config dump or
  boot command (e.g. `php bin/console debug:dotenv`, `manage.py diffsettings`,
  or `env | grep` for a plain env app). Every service URL it prints must point
  at what the image actually runs.
- Offer (don't just do — it takes minutes) to run `docker compose build` and
  then the profile's `setup` + `check` inside the built image against the
  target clone. That's the only real proof the profile is green on a clean
  tree; if the user declines, say clearly that it wasn't run.
- Once the container runs (only if the user starts it), confirm the init
  process: `docker inspect --format '{{.HostConfig.Init}}' <dir>-agent-1`
  prints `true`, and `docker exec <dir>-agent-1 cat /proc/1/cmdline` starts
  with `/sbin/docker-init`. Further Workers' containers are
  `<dir>-agent-<n>-1`. With a Worker id, `docker exec -u agent <container>
  git var GIT_AUTHOR_IDENT` names `Claude Code (<worker-id>)`.
- Once the operator starts a contract instance (a ref whose `agentctl`
  speaks the contract, so every Worker service carries the discovery
  labels), confirm each Managed Instance through `agentfleet` on the target
  context — never by reading the container's files:

  ```bash
  DOCKER_CONTEXT=<ctx> agentfleet identity <managed-name>
  DOCKER_CONTEXT=<ctx> agentfleet status <managed-name>
  ```

  `<managed-name>` is `<short-name>` for the first Worker and the Worker id
  `<short-name>-<n>` for Worker n ≥ 2. The instance is ready when
  `instance.state` is anything other than `starting`. A Pool of N ≥ 2
  Workers on the contract path requires `pool` in `identity.capabilities`;
  without it, stop and tell the user the backend cannot run a Pool here.
- LiteLLM backend: with the built image, offer the gateway check from
  `references/model-backend.md` ("Verifying the gateway"). Prompt caching
  can only be confirmed on the first real attempt; say so.

### 8. Report

Tell the user in their language: the engine backend chosen in step 0, files
created, and — for simple-coding-agent — stack decisions and the reasons
for them (runtime version, included/excluded checks, bundled services), the
model and its route (and, for LiteLLM, the gateway network), and the Workers
(N, their Worker ids or why none was rendered, the resource limits);
for coding-agent — the Workflow Configuration (Target Repository, the
declared Workflows, `implement`'s Selection Label and limits, `triage`'s
limits, every pin with its route — direct `provider:` pin or LiteLLM
`gateway:` pin — and confirmed prices, plus the gateway network overlay,
the Workers it attaches and `GATEWAY_NETWORK` when a service-name `url` was
pinned), the Skill Bundle and its policy (copied verbatim for the reference
bundle, or drafted: how many placeholders, each decision the operator
approved, and whether any remain), the derived deployment image
(`Dockerfile` copied verbatim from the asset, built FROM the `deployment`
target at the ref, baking and verifying the instance's `workflow/`
package), the Workers (`worker` and, in a two-Worker Pool, `worker-2`, each
with its Workflow, Managed Instance name and model keys), and for two
Workers this statement, translated into the user's language without
changing its meaning: "The two Workers are two Managed Instances on one
Target Repository. coding-agent does not advertise the `pool` capability,
so this departs from the operator contract's rule that an adapter refuses
a second instance for the same repository on the host; they run different
Workflows and take from different Queues (docs/adr/0005)." Also report that
no
Forge-owned profile was generated (the repository-owned
`docs/agents/project-profile.yml` stays the only profile), the rule that any
edit under `workflow/` needs `docker compose build` before the container is
recreated, and the target checkout check result (Project Profile found at its
searched location and revision, toolchain matrix match at the chosen ref, or
the reported miss / Unsupported Environment with the operator's decision). In
both cases:
the target Docker context and the Fleet check result — which Fleet was listed
and that no other instance holds the repository, or which one does (a
same-backend contract Pool, or a confirmed pairing with another backend);
for each confirmed pairing, this statement, filled in and translated into
the user's language without changing its meaning: "Instance `<name>`
(backend `<backend>`) also works `<owner>/<repo>`. agent-forge does not check
whether the two Instances' selection labels overlap. Keeping them apart, or
deliberately not, is your responsibility. On one shared GitHub login,
overlapping labels can cause double work, because the Claim cannot tell the
two engines apart." (no token and no label configuration is read to write
it); which
engine ref the image builds from (`AGENT_SRC_REF` or `CODING_AGENT_REF`:
`main`, or the pinned tag — and if pinned, that rebuilds won't pick up new
agent code until the ref in `.env` is bumped or changed back to `main`, then
rebuilt — no other file needs editing); whether the contract discovery labels
were rendered and why in terms of the rule (for simple-coding-agent, e.g.
"`main` speaks the contract", "`v0.9.1` is newer than `v0.9.0`", "`v0.8.2`
is older than `v0.9.0` so the instance stays on the legacy path", or the
branch/SHA checkout does or does not contain the contract adapter; for
coding-agent, the `worker` is always labelled); token check result, what was
and wasn't validated, and the start command
(`cd agent-instances/agent-<name> && docker compose up --build -d` —
`docker compose up --build -d worker` for coding-agent, plus `worker-2` in
a two-Worker Pool).
The instance is ignored by Git, so there is nothing to commit there.
Once the operator starts a contract instance, extend the report with
`agentfleet identity` (engine backend, Target Repository, contract major,
Operator Capabilities) and readiness from the Status Snapshot
(`instance.state`: ready when anything other than `starting`) for every
Managed Instance — `<short-name>` and each `<short-name>-<n>`. Name a Pool
(N ≥ 2) on the contract path only with `pool` in `identity.capabilities`
(a coding-agent Pool of one Worker per Workflow is the exception, stated
as above).
For coding-agent, report identity and readiness as unverified until the
contract producer ships (step 4).
