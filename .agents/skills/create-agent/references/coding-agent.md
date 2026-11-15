# coding-agent adapter

Read this when step 0 of `create-agent` chose the `coding-agent` backend.
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

## Model

Model and provider are chosen within the providers coding-agent's Workflow
Configuration supports at the ref — Anthropic and OpenAI at the documented
ref (`anthropic / claude-sonnet-5 / messages`,
`openai / gpt-5.6-luna / responses`); any other pair refuses startup. The
model-backend reference (Meta, LiteLLM) is simple-coding-agent only and does
not apply here: there is no gateway pin and no Meta route for this backend.
Prices (`prices-usd-per-mtok`: `input`, `output`, `cache-read`,
`cache-write`) come from the operator — confirm them (defaults are the
code-owned table's public list pricing) — because the pin's configured prices
are the Worker's only cost authority.

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
