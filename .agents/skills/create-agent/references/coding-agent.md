# coding-agent adapter

Read this when step 0 of `create-agent` chose the `coding-agent` backend,
or when the operator asks to upgrade an existing coding-agent Instance to
the derived-image layout ("Upgrading an existing coding-agent Instance"
below).

Terms are defined in `CONTEXT.md` (Instance, Worker, Worker identity) and in
the operator contract glossary (Managed Instance, Fleet, Target Repository,
Operator Capability, Status Snapshot).

Source facts below were read at coding-agent `v0.4.0` (`2626351`) unless
noted; the skill re-checks the HOWTOs against the chosen `CODING_AGENT_REF`
clone (step 3b) before scaffolding.

## What this adapter renders

An `agent-instances/agent-<name>/` directory holding a Compose deployment of
coding-agent's `worker` with its Workflow Configuration — a derived-image
Dockerfile, no stack block, no Forge-owned profile:

| File | Source |
|---|---|
| `compose.yaml` | `assets/compose.coding-agent.yaml.template` |
| `Dockerfile` | `assets/Dockerfile.coding-agent.template`, copied verbatim (the derived deployment image) |
| `workflow/workflow.yml` | `assets/workflow.coding-agent.yml.template` (`version: 3`, with a `skills:` block) |
| `workflow/prompts/*.md` | copied from the `CODING_AGENT_REF` checkout (see step 3b) |
| `workflow/skill-policy.json` | copied verbatim from the `CODING_AGENT_REF` checkout's `docker/deployment/` (see step 3b) |
| `.env.example` | `assets/env.coding-agent.example.template` |
| `.env` | same as `.env.example` + real secrets (ignored with all of `agent-instances/`) |

Keep the templates' `{{PLACEHOLDER}}` markers consistent: when one is renamed
or added, update every reference that names it (`grep -rn` the old name).

## Compose template

- **Build.** The image is a derived deployment image (this directory's
  `Dockerfile`, copied verbatim from
  `assets/Dockerfile.coding-agent.template`), built FROM the engine image
  the `engine` service produces from coding-agent's git repository at a
  configurable ref, analogous to `AGENT_SRC_REF`: the engine's
  `build.context` is
  `https://github.com/lbacik/coding-agent.git#${CODING_AGENT_REF:-main}`
  with `target: deployment`, and `CODING_AGENT_REF` in `.env` (default
  `main`) names the branch, tag or commit. Change it and rerun
  `docker compose build` to switch agent code. The toolchain is fixed by
  the image's Supported Toolchain Matrix (coding-agent ADR 0001), never per
  instance. The derived services reach the base through an
  `additional_contexts` entry with a `service:` source (`engine:
  service:engine`), so one `docker compose up --build -d worker` builds the
  base first with no extra step and no shared image tag that could clash
  with another instance on the same context. The `service:` source is part
  of `additional_contexts`, which needs Compose 2.17 or newer — the same
  minimum the simple-coding-agent template already requires. (The
  alternative — a prebuilt base image tag the Dockerfile names — would need
  a separate prior build step and a per-instance tag; the `service:`
  reference keeps the ordering inside Compose.)
- **Project.** The file sets no `name:`: the Compose project is the directory
  name, because the project name is the Instance identity on the Docker
  context. coding-agent's own fixed `name: coding-agent` is not copied.
- **Services.** `worker` (labelled with the four discovery labels,
  `backend` = `coding-agent`) runs `agent run` with the full v3 flags (see
  "The derived image" below); `agent` and `validate` are unlabelled
  one-off seats (`docker compose run --rm ...`) on the same derived image,
  so `validate` and `startup-check` see the same toolchains and the same
  baked package as the Worker. `engine` is the build-only base image (never
  run, never labelled). All three runtime seats share one state volume at
  coding-agent's state path (`/var/lib/coding-agent`, read at the ref).
  `agent` stays a bare seat: the Workflow Configuration is baked into the
  image, so commands that read it need no mount (see "Validation").
- **Hardening** mirrors coding-agent's deployment at the ref: read-only root
  filesystem and a writable `/tmp` on every service, `init: true`,
  `restart: "no"` and `stop_grace_period: 60s` on the worker (above the
  Workflow Configuration's `worker.shutdown-grace-seconds`, default 30 s),
  plus the exec-user-only operator-socket tmpfs
  (`/var/lib/coding-agent/operator:uid=1000,gid=1000,mode=0700`) that
  coding-agent's contract `agentctl` documents for private IPC. The tmpfs
  must be owned by the exec user (`agent`, uid/gid 1000) with mode 0700: a
  plain tmpfs arrives root-owned and the Worker cannot chmod it, so startup
  refuses the socket bind. The listener enforces 0700 on the directory and
  0600 on the socket; there is no network listener and no published port. If
  the chosen ref's `agentctl` documents no such socket directory, drop that
  second tmpfs entry.
- **Resource limits** (`cpus: ${WORKER_CPUS:-1.5}`,
  `mem_limit: ${WORKER_MEM_LIMIT:-3g}`, `pids_limit: ${WORKER_PIDS_LIMIT:-1024}`)
  live on the shared `x-agent` anchor, so `worker`, `agent` and `validate`
  all inherit the same values, overridable in `.env` (leave the `WORKER_*`
  variables commented out to keep the defaults). This is a Forge addition,
  not part of the hardening mirrored from coding-agent's own deployment:
  upstream's `compose.yaml` sets no resource limits. It is a deployment
  concern and stays out of the Workflow Configuration: the workflow
  `limits` (cost, tokens, tool calls, wall clock) budget an Attempt and do
  not bound host resources.
- **Exactly one Worker** per Target Repository and state volume. There is no
  `agent-2..N` stanza, Pool rendering never applies, and `manage-pool` does
  not apply to this backend. A second instance for the same repository is
  refused by the shared Fleet check (step 1): this backend never advertises
  the `pool` Operator Capability.

## The derived image

The instance Dockerfile implements upstream's "External builders: the Agent
Forge sequence" (`docs/ops/workflow-configuration.md` at the documented
ref, `v0.4.0` / `2626351`), the same sequence upstream's `deployment` build
target performs:

1. **Assembly.** The image builds `FROM` the `deployment` target output,
   which already carries the toolchains and the generated Supported
   Toolchain Matrix. It bakes the instance's `workflow/` package —
   `workflow.yml`, `prompts/` and the reviewed `skill-policy.json` — over
   the reference package at `/etc/coding-agent`. The prompts directory is
   replaced wholesale, not merged: the reference package ships
   `review-policy.md` beside `implement-policy.md`, while the instance ships
   `implement-policy.md` and `handoff.md`.
2. **Preparation.** As the runtime user (`agent`) with no Worker GitHub or
   model secret set: `agent config validate`, then
   `agent prepare-skill-bundle --mode install --config
   /etc/coding-agent/workflow.yml --policy
   /etc/coding-agent/skill-policy.json --bundle-dir
   /opt/coding-agent/skill-bundle --home /home/agent`. Preparation starts
   from empty bundle and store directories (the inherited generated records
   and the inherited managed store are removed first): upstream's own
   `deployment` stage only ever prepares onto fresh directories, so the
   derived build reproduces those conditions rather than relying on
   re-preparation over the reference install. Toolchains and matrix are
   untouched.
3. **Final-root verification.** `agent verify-skill-bundle --config …
   --policy … --bundle-dir … --home …` runs after the last relevant `COPY`,
   so the build — not startup — fails on a byte-edited copy or a declared
   member the install cannot provide.
4. **The rendered `run` invocation.** The `worker` starts with the upstream
   rendered form:
   `agent run --config /etc/coding-agent/workflow.yml --workflow
   ${WORKFLOW:-implement} --state-dir /var/lib/coding-agent
   --toolchain-matrix /opt/coding-agent/toolchain-matrix.json --policy
   /etc/coding-agent/skill-policy.json --bundle-dir
   /opt/coding-agent/skill-bundle --skill-home /home/agent`.
   The legacy `--skills-home` / `--skill-bundle-dir` options are gone: v3
   exits 2 on them.

Because the package is baked into the image, **any edit under `workflow/`
needs `docker compose build` before the container is recreated** — the same
rule as a profile change for simple-coding-agent. `CODING_AGENT_REF` keeps
its meaning: change it and rebuild to switch agent code.

## Workflow Configuration

A `workflow/` directory in the instance holds `workflow.yml` (a `version: 3`
Workflow Configuration), the prompt files it names, and the reviewed
`skill-policy.json`, baked into the derived image at `/etc/coding-agent`:

- `version: 3` is the only accepted format since coding-agent 0.3.0: a
  `version: 2` file is refused with a migration diagnostic before any Claim
  (see `docs/ops/v3-breaking-change-notice.md` at the ref). Point the editor
  `$schema` at `schemas/workflow-v3.schema.json`.

- `target.repository` is the Target Repository, `target.base_branch` its
  default branch. Read the default branch from the target checkout or
  `gh repo view --json defaultBranchRef`.
- `target.token_env` and each model's `api-key-env` name environment
  variables only; values live only in `.env`. `config validate` refuses a
  value that looks like a secret where a name belongs.
- `skills:` declares the Skill Bundle membership: the reference
  deployment's selection (`docker/deployment/workflow.yml` at the ref —
  `git+https://github.com/mattpocock/skills.git` at
  `3cca18b368ae95cdbdebbff572ccafa662551015` with `include: [implement,
  tdd, code-review, codebase-design]`). There is no implicit bundle: a
  missing `skills` field means an empty bundle, every static `skill:`
  reference must name a declared member, and every member needs a reviewed
  entry in `skill-policy.json`. The template keeps the Forge step graph
  (`preflight → process → validate → self-review → push → open-pr`, plus
  `explain-blocked`, the reserved `ai-handoff` and `hard-handoff`); it does
  not adopt the reference's smaller `implement` graph or its `review`
  workflow.
- `skill-policy.json` is copied verbatim from the `CODING_AGENT_REF`
  checkout's `docker/deployment/` into the instance's `workflow/`; Forge
  keeps no copy of its own. The skill never writes or approves policy
  entries: a different bundle membership or source ref means the operator
  re-reviews the policy first. (Secret-free `config validate` passes even
  when the policy file is missing, but the derived-image build does not:
  `prepare-skill-bundle --mode install` and the final-root
  `verify-skill-bundle` fail the build on a missing or mismatched policy —
  still check the file is there and byte-identical when scaffolding.)
- One `implement` Workflow with its Selection Label and Attempt Ceiling
  (all four meters: `cost-usd`, `tokens`, `tool-calls`,
  `wall-clock-minutes`). The Work Pool is the ceiling minus the reserved
  `ai-handoff` allowance (`cost-usd: 1`, `tokens: 150000`, `tool-calls: 30`,
  `wall-clock-minutes: 5`), per meter, and every non-reserved Step
  Allowance (`process`, `self-review`) must fit in it on every meter it
  sets — otherwise `config validate` refuses the file (for example, a 5 USD
  ceiling leaves a 4 USD Work Pool that the default 12 USD `process`
  allowance does not fit). When an allowance does not fit, or the ceiling is
  not larger than the reserve on some meter, the skill stops before writing
  the Workflow Configuration, names each step with its allowance and the
  Work Pool, and asks the operator for new allowances or a higher ceiling;
  it never scales or clamps allowances itself, and the reserve stays as is.
- **Selection Label.** Suggest `agent:implement`. Reject a label that breaks
  coding-agent's rules and ask for another: `ready-for-human`, `wontfix` or
  any `wayfinder:*` label (contract W-CFG-12; an input carrying `wontfix` or
  `wayfinder:*` is never claimed, P-SEL-4). `config validate` additionally
  refuses a Selection Label that also appears in the same Workflow's filters
  or as an end label of any Workflow in the file.
- The prompt files the steps name (`prompts/implement-policy.md` from
  `docker/deployment/prompts/`, `prompts/handoff.md` from
  `examples/prompts/` — `handoff.md` lives only there at the documented ref)
  are copied verbatim from the `CODING_AGENT_REF` checkout (step 3b),
  recording the source path per file: `config validate` stats every prompt
  file, so a named file must exist next to `workflow.yml`. No `{{...}}` may
  remain in any rendered file.

## Limits: where simple-coding-agent's settings went

Read at coding-agent `v0.4.0` (`2626351`); the skill re-reads the
code-owned rows below against the chosen `CODING_AGENT_REF` before treating
them as current. Budgets live only in the Workflow Configuration: the
Effective Configuration digest is the only budget authority, and neither the
`env.coding-agent.example.template` nor any rendered `.env` gains a budget,
turn, timeout or retry key. Each row carries one layer: **workflow** (set in
the Workflow Configuration), **code** (a coding-agent constant, not
configurable — never copied as configuration), **deployment** (compose),
**n/a** (no equivalent by design).

| simple-coding-agent `.env` | coding-agent | Layer |
|---|---|---|
| `MAX_BUDGET_USD` | Workflow `limits.cost-usd`: the Attempt Ceiling on the Workflow, the Step Allowance on a step | workflow |
| `MAX_BUDGET_TOKENS` | `limits.tokens`. Effective tokens exclude prompt-cache reads (`src/coding_agent/runtime/ceilings.py`) | workflow |
| `MAX_TURNS` | `limits.tool-calls`. Plus the code-owned `MAX_AGENT_ITERATIONS = 30` tool-loop backstop per Step Execution (see the caveat below) | workflow + code |
| `SOFT_THRESHOLD_PERCENTAGE`, `HANDOFF_RESERVE_TURNS` | The Reserved Step `ai-handoff` (`reserved: true`, allowance on all four meters) | workflow |
| `MODEL_TIMEOUT` | `limits.wall-clock-minutes` (the whole Attempt, operations included) | workflow |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` / `MAX_CONTEXT_TOKENS` | `context-threshold-tokens` / `output-cap-tokens` — gateway pins only (see below); on a direct pin the context window is code-owned. Companion backstop `MAX_HANDOFFS_PER_STEP = 5` (`src/coding_agent/runtime/context_handoff.py`) | workflow (gateway) + code (direct) |
| `POLL_INTERVAL` | `worker.poll-interval-seconds` (default 60 s) | workflow |
| `MODEL_STREAM_IDLE_TIMEOUT_MS` | 300 s per model request, capped by the remaining wall-clock time (`DEFAULT_CODE_OWNED_MODEL_TIMEOUT_SECONDS` in `src/coding_agent/runtime/step_limits.py`) | code |
| `PUBLISH_TIMEOUT` | 600 s per operation command (`OPERATION_TIMEOUT_SECONDS` in `src/coding_agent/runtime/step_operations.py`; the per-command timeout in `src/coding_agent/runtime/step_limits.py` is likewise 600 s) | code |
| `MAX_RETRIES` | Provider retry, 3 attempts (`DEFAULT_MAX_ATTEMPTS` in `src/coding_agent/provider/retry.py`); GitHub in-place retry, bounded at 3 attempts / 5 minutes (`src/coding_agent/github/errors.py`) | code |
| `MAX_CONSECUTIVE_ERRORS` | `MAX_CONSECUTIVE_INFRASTRUCTURE_FAILURES = 3` (`src/coding_agent/worker/run.py`): that many consecutive infrastructure failures halt the Worker | code |
| `MAX_AUTO_CONTINUATIONS` | None by design ("No Continuation across Attempts"): `unfinished` is an end label, not a resume | n/a |
| `MAX_CONFLICT_ATTEMPTS`, `PR_AUTO_MERGE`, `PR_MERGE_METHOD` | None: the only publishing operation is `open-pull-request` (draft flag fixed `false` in the template), so there is nothing to merge automatically and no conflict requeue | n/a |
| `WORKER_CPUS` / `WORKER_MEM_LIMIT` / `WORKER_PIDS_LIMIT` | Compose `x-agent` anchor in `assets/compose.coding-agent.yaml.template` (#103) | deployment |

Every **code** value above is a constant at the stated ref, to be re-read
when `CODING_AGENT_REF` moves — not a setting to copy anywhere.

- **Gateway-only context fields.** `context-threshold-tokens` and
  `output-cap-tokens` exist only on gateway pins (`V2ModelDecl` in
  `src/coding_agent/workflow/v2_schema.py`; the pin policy in
  `src/coding_agent/provider/config.py` resolves a direct pin's output cap
  and context window from the code-owned tables). Supporting LiteLLM gateway
  pins is #102's scope: for a direct pin — the only pin this adapter renders
  today — the context window stays code-owned. Do not set these fields on the
  pins the template renders.
- **`MAX_AGENT_ITERATIONS` caveat** ([lbacik/coding-agent#427](https://github.com/lbacik/coding-agent/issues/427)).
  Until that issue is resolved, the backstop of 30 model responses per Step
  Execution (`MAX_AGENT_ITERATIONS` in
  `src/coding_agent/runtime/graph/agent_step.py` — "the tool loop exceeded
  its iteration backstop") ends the step with `error`. The template's
  `defaults.routes` send `error` to `hard-handoff`, which commits and pushes
  with no AI note, and the backstop can bind long before `tool-calls` does.
  The validated workaround is to route `error` to the AI-assisted handoff
  step on the work step (`routes: {error: ai-handoff}` on `process`), so an
  exhausted tool loop still leaves a handoff note. The template keeps the
  `hard-handoff` default — an `error` is also what infrastructure failures
  produce, and those should not spend the reserved AI-assisted handoff — and
  the operator opts into the workaround per instance when the workload is
  tool-loop-heavy. (`MAX_HANDOFFS_PER_STEP = 5`, in
  `src/coding_agent/runtime/context_handoff.py`, likewise stays code-owned.)

## Model

The Attempt's one Pinned Model is either a direct `provider:` pin or a
`gateway:` pin through a Model Gateway (coding-agent
`docs/ops/workflow-configuration.md`, "Gateway pins", at the ref): exactly
one of `provider` or `gateway` is present. `MODEL_*` / `MODEL_BASE_URL` do
not apply on this backend — for the simple-coding-agent routes see
`references/model-backend.md` instead.

A direct pin's (`provider`, `model`, `endpoint`) triple must come from the
code-owned table in coding-agent's `src/coding_agent/provider/config.py` at
the ref — Anthropic and OpenAI at the documented ref
(`anthropic / claude-sonnet-5 / messages`,
`openai / gpt-5.6-luna / responses`); any other pair refuses startup. The
context window and the per-request output cap stay in code; `effort` is low,
medium or high.

A gateway pin carries its own output cap and context-window threshold:

```yaml
models:
  main:
    gateway: {kind: litellm, url: http://litellm:4000}
    model: muse-spark-1.3-contributor   # the gateway's L1 alias
    endpoint: responses
    effort: medium
    api-key-env: LITELLM_PROXY_API_KEY
    output-cap-tokens: 32000
    context-threshold-tokens: 300000
    prices-usd-per-mtok: {input: 0.10, output: 0.20, cache-read: 0.002, cache-write: 0.10}
```

- `gateway.kind` is the gateway kind, from a closed code-owned list: today
  only `litellm`. `gateway.url` is the gateway's literal `http` or `https`
  URL — prefer the service name on the shared gateway network
  (`http://litellm:4000`), which stays the same across Docker contexts; a
  host URL is also accepted. There is no `url-env` at the documented ref
  (proposed upstream in `lbacik/coding-agent#428`, not available yet), so the
  address is baked into the image; never render a `LITELLM_PROXY_URL`
  variable.
- `model` is the gateway's own L1 alias: pin the name the gateway reports in
  `x-litellm-model-group`. The pin key is the label
  `litellm:<model>@responses`. `endpoint` is `responses` (the endpoint the
  code-owned table admits for the gateway kind) and `effort` is low, medium
  or high.
- `output-cap-tokens` and `context-threshold-tokens` are the pin's own
  output cap and context-window threshold. A direct pin naming either key is
  refused. The threshold triggers Context-Window Handoffs (coding-agent ADR
  0013): the Handoff continues the same Step Execution against its Step
  Allowance and Attempt Ceiling, and Handoffs per step are bounded by the
  code-owned `MAX_HANDOFFS_PER_STEP` (`5` at the documented ref). The
  threshold must exceed the code-owned safety margin plus request overhead
  (`1000 + 1000` at the documented ref). Ask the operator for both values;
  never default them.
- Prices (`prices-usd-per-mtok`: `input`, `output`, `cache-read`,
  `cache-write`) come from the operator — confirm them, never default them
  — because the pin's configured prices are the Worker's only cost
  authority (a gateway response header such as `x-litellm-response-cost` is
  never read, not even as evidence). For a Meta model, which has no
  cache-write premium, set `cache-write` equal to `input`: a gateway
  response that reports no `cache_write_tokens` is priced at max(`input`,
  `cache-write`).

The template renders exactly one variant: the skill substitutes the direct
placeholders and deletes the gateway block, or deletes the direct block and
uncomments the gateway block (see the markers in
`assets/workflow.coding-agent.yml.template`). A direct-pin render carries no
`gateway:`, `output-cap-tokens` or `context-threshold-tokens` key. No
`{{...}}` may remain in either variant.

The model's key variable reaches only the `worker` service: on a direct pin
`ANTHROPIC_API_KEY` or `OPENAI_API_KEY`, on a gateway pin
`LITELLM_PROXY_API_KEY` — whichever the Workflow Configuration names in
`models.<id>.api-key-env` (see the conditional lines in
`assets/compose.coding-agent.yaml.template`). It is never added to the
`agent` or `validate` seats' environment, and the template sets no
`env_file:` (as in upstream's `compose.yaml`), which would copy every `.env`
key into every seat. `.env` still feeds Compose interpolation; secret-free
`config validate` needs no environment and `startup-check` needs only
`GITHUB_TOKEN`, which the shared anchor passes explicitly. The key is set, commented and
documented next to the other model keys in
`assets/env.coding-agent.example.template`.

A gateway `url` naming a Docker service needs the gateway network overlay:
`assets/compose.coding-agent.litellm.yaml.template` attaches `worker` — and
only `worker` — to the external network named by `GATEWAY_NETWORK`, enabled
from the env file (`COMPOSE_FILE=compose.yaml:compose.coding-agent.litellm.yaml`,
`GATEWAY_NETWORK` from `.env`, never hard-coded). Do not reuse
`compose.litellm.yaml` here: it attaches services named `agent` and
`agent-<n>`, and on this backend `agent` is the unlabelled one-off seat, not
the Worker. A host-URL `gateway.url` needs no overlay. The skill never starts
or configures the gateway itself; it only joins its network.

Recommend the operator configure the gateway so the pinned name has no
fallbacks or retries (`num_retries: 0`), and set no key's
`metadata.disable_fallbacks: false` (coding-agent
`docs/ops/workflow-configuration.md`, "Recommended gateway configuration";
`compose.gateway-example.yaml` at the ref shows the worker wiring). That is
a recommendation; the per-response assertion is the guarantee: a response
whose `x-litellm-model-group` differs from the pin, or whose attempted
fallbacks or retries read above `0`, is a pin violation — the Attempt ends
`interrupted` with reason `pin-violation` and the Worker halts at once with
a non-zero exit (contract §12, §16.3), as on a Credential Failure. Every
request also carries the per-request suppression (`disable_fallbacks: true`,
`num_retries: 0`); the Worker's own provider retry is then the only retry.
The Worker never reads the gateway's configuration.

A model that refuses a forced tool, or that accepts an invalid effort,
cannot be pinned: the startup Provider Capability Assertion (coding-agent
ADR 0009) refuses the pin with no Attempt opened. The probe binds its tool
with a forced `tool_choice` naming it and then proves the effort reaches the
wire by sending the same request with a deliberately invalid effort, which a
gateway must refuse naming the effort.

## Target checkout checks (no Forge profile)

There is no Forge-owned profile for this backend: the Target Repository's
own Project Profile, read at the Base Revision, stays the only profile. No
`simple-coding-agent-profile.yml` is written and no Dockerfile `STACK` block
is rendered — what the derived image bakes instead is the instance's
`workflow/` package with its prepared Skill Bundle (see "The derived
image"), never a Forge-owned profile — and the Worker pins the
repository-owned profile at Claim time. At scaffolding time, run both
checks below against the target checkout and report before writing anything.
When both pass, scaffold without further prompts; when either fails, ask the
operator (AskUserQuestion) and continue only on an explicit decision to
proceed.

### 1. The Project Profile exists

The canonical location is `docs/agents/project-profile.yml` in the Target
Repository at the Base Revision (the default branch that becomes
`target.base_branch` in step 5). Read it from the target checkout used in
step 2 — the working tree at that branch, or
`git show <base>:docs/agents/project-profile.yml` — never from prose
fallbacks (`AGENTS.md`, `CLAUDE.md`, `docs/agents/*` other than the profile
itself): upstream resolves no Readiness Fact from prose.

- When the file is present, record that the Project Profile was found (and
  its `schema`, `language` and `toolchain` for the next check) and move on
  to check 2.
- When it is absent, report the miss naming the searched location and the
  revision (for example: "no `docs/agents/project-profile.yml` at
  `<base>` of `<owner>/<repo>`"), and ask the operator whether to scaffold
  anyway. Scaffolding continues only on the operator's explicit decision —
  without a profile the Worker cannot reach readiness, so say so in the
  report.

### 2. The declared toolchain is inside the Supported Toolchain Matrix

The profile declares one toolchain: `language` selects the runtime key
(`python` → `python`, `php` → `php`, `typescript` → `node`), and
`toolchain.<runtime>` plus `toolchain.package_manager` name the required
runtime version and package manager. The image provides exactly the
Supported Toolchain Matrix — Python with uv, PHP with Composer, Node with
pnpm — published at `/opt/coding-agent/toolchain-matrix.json`, generated at
build time from the toolchains the build actually produced (never
hand-copied). At scaffolding time the matrix belongs to the chosen
`CODING_AGENT_REF`: read the supported versions from a matrix that ref
generates when one is available (`scripts/generate-toolchain-matrix.py`, or
`CODING_AGENT_TOOLCHAIN_MATRIX` / `--toolchain-matrix`) — otherwise from
that ref checkout's `Dockerfile` `ARG` pins (`PYTHON_IMAGE`, `PHP_VERSION`,
`NODE_VERSION`, `UV_VERSION`, `COMPOSER_VERSION`, `PNPM_VERSION`), the build
inputs the generated matrix records. A generated matrix wins over the pins
when both exist.

Compare the profile against that matrix the way the Worker will at runtime:

- A declared version is satisfied by prefix match on dotted segments:
  declared `3.13` is satisfied by an image carrying `3.13.9`, while declared
  `3.1` is not satisfied by `3.13.9`.
- The declared package manager name must equal the matrix's for that
  runtime (`uv` for Python, `composer` for PHP, `pnpm` for Node).
- A runtime the matrix does not carry at all is a mismatch.

When every declared requirement is satisfied, record the match and scaffold
without prompting. Otherwise report the requirement as an Unsupported
Environment, naming the offending runtime and the supported range (for
example: "profile declares `python 3.12`, image matrix at `<ref>` carries
`3.13.9` with `uv <uv-version>`"), and ask the operator whether to scaffold
anyway. Scaffolding continues only on the operator's explicit decision —
no answer at scaffolding time can make that image satisfy the profile, only
a different deployment can, so say so in the report.

## Validation

Run in the instance directory, in this order, and report which passed and
which remain unverified:

1. `docker compose config -q` (with no secret set).
2. `docker compose build` (with no secret set). The derived-image build
   runs, as the runtime user, `agent config validate`, then
   `agent prepare-skill-bundle --mode install`, then `agent
   verify-skill-bundle` against the final roots — and fails when any of
   them fails (a byte-edited prompt or an undeclared skill fails here, the
   same refusal `run` would raise at startup). The build needs network
   access for the skill install; it needs no Worker GitHub or model secret.
3. Secret-free `config validate` through the built `agent` one-off seat,
   with no secrets set (neither the token variable the YAML names nor the
   model's key variable is needed — validation is static):

   ```bash
   docker compose run --rm agent config validate \
     --config /etc/coding-agent/workflow.yml --workflow implement
   ```

   Offline and static: no Attempt is opened and no value is printed. No
   mount is needed: the package the build verified is baked into the image.
4. `startup-check --repo` with the instance's token (non-mutating, no write
   performed):

   ```bash
   docker compose run --rm agent startup-check --repo <owner>/<repo> --token-env GITHUB_TOKEN
   ```
5. The existing token write-scope check (step 6 of the skill): the
   fine-grained PAT must hold write access to contents, pull requests and
   issues of the Target Repository (empty-body write probes, `422` on all
   three).
   `startup-check` passing does not replace it: it checks the identity and
   push permission, not the issue scope the Queue needs.

The skill may offer coding-agent's `validate` service against a target
checkout, as it offers a build-and-check run today (that is the only real
proof the checkout's profile is green on a clean tree; if the operator
declines, say clearly that it was not run):

```bash
TARGET_PROJECT=<checkout> docker compose run --rm validate [--skip-bootstrap] [--targeted <tests>]
```

## Readiness

Build first, then start only the worker (`docker compose up --build -d
worker`: `agent` exits at once and `validate` needs `TARGET_PROJECT`).
Any edit under `workflow/` needs `docker compose build` before the
container is recreated — the package is baked into the image, so a
recreated container without a rebuild keeps running the old package. Once
the operator starts it, the creation report carries, for the Managed
Instance `<short-name>`:

```bash
DOCKER_CONTEXT=<ctx> agentfleet identity <short-name>
DOCKER_CONTEXT=<ctx> agentfleet status <short-name>
```

`identity` shows `backend: coding-agent`, the Target Repository and
capabilities `next-issue` and `stop-after`; readiness is `instance.state`
other than `starting`. Until coding-agent ships the contract producer
(step 4), this part is reported as unverified.

## Upgrading an existing coding-agent Instance

Read this when the operator explicitly asks to move an Instance created
before the derived-image layout (a `version: 2` Workflow Configuration
mounted from `./workflow`, an image built straight from coding-agent's
repository with no `Dockerfile` in the instance) to the layout above. This
is the one case where `create-agent` changes an existing Instance; the
new-instance flow (Fleet check, directory refusal, credential questions)
does not run. Why it is needed: rebuilt against a v3 ref, the old Worker
refuses its mounted `version: 2` file with a migration diagnostic; built
at a ref that has the derived Dockerfile but without `target: deployment`,
the image is the bare base stage, with no toolchains and no skills.

The sequence follows coding-agent's "Upgrading: drain, backup and
rollback" (`docs/ops/workflow-configuration.md`, read at `v0.4.1`
(`3ce858f`); re-read it at the new `CODING_AGENT_REF`, it wins over this
summary). Run every command from the instance directory, on the
Instance's Docker context (`DOCKER_CONTEXT=<ctx>`), and stop at the first step that fails. Keep
secrets out of the output: compare `.env` key names, never values.

1. **Drain check.** Close Intake with the old release through
   [operate-agent](../../operate-agent/SKILL.md) (`stop`, a drain — never
   `docker stop`). The drain is done when the state is quiescent: Intake
   stopped, no active Attempt, no unfinished or unconfirmed Claim and no
   unsettled lifecycle work. A terminal outcome alone does not prove
   finalisation is complete. Read it from the Status Snapshot
   (`agentfleet status <short-name>`); when the old release answers no
   Status Snapshot, read it from the Worker's state with the read-only
   [debug-agent](../../debug-agent/SKILL.md) helpers. When neither shows a
   quiescent state, stop and ask. An open Attempt or a pending recovery
   must be finished with the old release first: the new Worker refuses to
   recover records it did not write. Only then stop the `worker` service,
   and only that service:

   ```bash
   docker compose stop worker
   ```

2. **Tag the old image** so a rollback has something to run. The new
   build reuses the tag `coding-agent:<short-name>`, so tag first, with a
   name that records the old layout and the commit it was built from (the
   pinned SHA or tag in the old `.env`; for a branch whose built commit is
   not recorded, the image's creation date from
   `docker image inspect -f '{{.Created}}'` instead). The tagged image also
   keeps the old release's prepared Skill Bundle records:

   ```bash
   docker image tag coding-agent:<short-name> coding-agent:<short-name>-v2-<short-sha>
   ```

3. **Back up while stopped**, to a directory **outside the instance
   directory**, e.g.
   `agent-instances/backups/agent-<short-name>-<YYYY-MM-DD>-pre-v3/`. The
   derived build uses `.` (the instance directory) as its build context, so
   a backup inside it would be sent to the builder and could be baked into
   the image, secrets and state included. Back up the state volume and the
   operator inputs together — one without the other is not a restore
   point: `compose.yaml`, `.env`, `.env.example`, `workflow/`, and
   `compose.coding-agent.litellm.yaml` when the Instance has the gateway
   overlay. The volume is `<project>_state`, where the Compose project is
   the instance directory name. Check that it exists first: `docker run -v`
   creates a missing volume empty, which would make an empty backup with
   no error. Streaming the archive through stdout works on a remote context
   too:

   ```bash
   set -e
   B=../backups/agent-<short-name>-<YYYY-MM-DD>-pre-v3
   docker volume inspect agent-<short-name>_state >/dev/null
   mkdir -p "$B" && cp -p compose.yaml .env .env.example "$B"/ && cp -Rp workflow "$B"/
   docker run --rm -v agent-<short-name>_state:/state:ro alpine \
     tar czf - -C /state . > "$B/state.tgz"
   ```

4. **Re-render the template-owned files** from the current templates and
   the new `CODING_AGENT_REF` checkout, following "What this
   adapter renders", "Workflow Configuration" and "Model" above and the
   skill's step 3b:
   `compose.yaml` (plus the gateway overlay when the old Instance had one),
   `Dockerfile`, `workflow/workflow.yml`, the prompt files,
   `workflow/skill-policy.json` and `.env.example`. Take the values from
   the old files instead of asking again: the Target Repository and base
   branch, the short name, the model and its route, and the Workflow
   settings (Selection Label, Attempt Ceiling, Step Allowances). The
   "Workflow Configuration" rules still apply: when an old allowance does
   not fit the Work Pool, stop and ask. The prompts come from the ref:
   `implement-policy.md` from `docker/deployment/prompts/` and `handoff.md`
   from `examples/prompts/`. Older Instances copied `implement-policy.md`
   from `examples/prompts/`; do not carry that copy over. Keep `.env` as
   is, except for keys the new `.env.example` requires that `.env` lacks
   (compare key names only), and point `CODING_AGENT_REF` at the new ref.
   No `{{...}}` may remain.

5. **Validate**, in this order, as in "Validation" above; stop at the first
   failure and roll back (step 6 below):

   1. `docker compose config -q`
   2. `docker compose build` — prepares and verifies the Skill Bundle
   3. `docker compose run --rm agent config validate --config /etc/coding-agent/workflow.yml --workflow implement`
   4. `docker compose run --rm agent startup-check --repo <owner>/<repo> --token-env GITHUB_TOKEN`
   5. `docker compose up -d --no-build worker`

   The token is unchanged, so the token write-scope check (the skill's
   step 6) need not be repeated unless `.env` gained a new token.

6. **Rollback** when any validation step fails or the new Worker refuses
   to start. Before the new Worker has written state, restore and restart
   the old release. Restoring wipes the state volume and replaces it with
   the backup, so get the operator's explicit authorization for that first,
   even inside a requested upgrade. Run it as one script (`B` is the
   backup directory from the backup step):

   ```bash
   set -e
   B=../backups/agent-<short-name>-<YYYY-MM-DD>-pre-v3
   test -f "$B/state.tgz"
   docker compose stop worker
   cp -p "$B"/compose.yaml "$B"/.env "$B"/.env.example . && rm -rf workflow && cp -Rp "$B"/workflow .
   rm -f Dockerfile
   docker run --rm -i -v agent-<short-name>_state:/state alpine \
     sh -c 'find /state -mindepth 1 -delete && tar xzf - -C /state' < "$B/state.tgz"
   docker image tag coding-agent:<short-name>-v2-<short-sha> coding-agent:<short-name>
   docker compose up -d --no-build worker
   ```

   Restore the gateway overlay too when it was backed up. Once the new
   Worker has written state or landed GitHub effects (an Attempt, a
   Claim), restoring the old volume needs those effects reconciled first
   (upstream's "Roll back only compatibly"): never attach the old Worker
   blindly, and never delete history or reset state to get past a
   refusal.

7. **After the upgrade**, read the first startup logs
   (`docker compose logs worker`): the Worker verifies the baked package
   and passes its live checks with no refusal, and startup recovery has
   nothing to recover (`startup-recovery skipped` after a clean drain).
   Operator Commands the old release left in flight need no manual action:
   they are settled at startup (a `next-issue` left `accepted` ends
   `not_fulfilled`); read one back with `operate-agent`'s `command
   <request-id>` if needed. Then reopen Intake through
   [operate-agent](../../operate-agent/SKILL.md) (`resume`). Keep the
   backup and the old image tag until the upgraded Worker has finished an
   Attempt.
