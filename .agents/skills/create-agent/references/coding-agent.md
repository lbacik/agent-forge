# coding-agent adapter

Read this when step 0 of `create-agent` chose the `coding-agent` backend.
Terms are defined in `CONTEXT.md` (Instance, Worker, Worker identity) and in
the operator contract glossary (Managed Instance, Fleet, Target Repository,
Operator Capability, Status Snapshot).

Source facts below were read at coding-agent `9a13c34` unless noted; the skill
re-checks the HOWTOs against the chosen `CODING_AGENT_REF` clone (step 3b)
before scaffolding.

## What this adapter renders

An `agent-instances/agent-<name>/` directory holding a Compose deployment of
coding-agent's `worker` with its Workflow Configuration — no instance
Dockerfile, no stack block, no Forge-owned profile:

| File | Source |
|---|---|
| `compose.yaml` | `assets/compose.coding-agent.yaml.template` |
| `workflow/workflow.yml` | `assets/workflow.coding-agent.yml.template` |
| `workflow/prompts/*.md` | copied from the `CODING_AGENT_REF` checkout (see step 3b) |
| `.env.example` | `assets/env.coding-agent.example.template` |
| `.env` | same as `.env.example` + real secrets (ignored with all of `agent-instances/`) |

Keep the templates' `{{PLACEHOLDER}}` markers consistent: when one is renamed
or added, update every reference that names it (`grep -rn` the old name).

## Compose template

- **Build.** The image builds from coding-agent's git repository at a
  configurable ref, analogous to `AGENT_SRC_REF`:
  `build.context` is `https://github.com/lbacik/coding-agent.git#${CODING_AGENT_REF:-main}`,
  and `CODING_AGENT_REF` in `.env` (default `main`) names the branch, tag or
  commit. Change it and rerun `docker compose build` to switch agent code.
  The toolchain is fixed by the image's Supported Toolchain Matrix
  (coding-agent ADR 0001), never per instance.
- **Project.** The file sets no `name:`: the Compose project is the directory
  name, because the project name is the Instance identity on the Docker
  context. coding-agent's own fixed `name: coding-agent` is not copied.
- **Services.** `worker` (labelled with the four discovery labels,
  `backend` = `coding-agent`) runs `agent run` with the Workflow
  Configuration and Workflow id; `agent` and `validate` are unlabelled
  one-off seats (`docker compose run --rm ...`). All three share one state
  volume at coding-agent's state path (`/var/lib/coding-agent`, read at the
  ref). `agent` stays a bare seat: commands that read the Workflow
  Configuration mount `./workflow` explicitly (see "Validation").
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
- **Exactly one Worker** per Target Repository and state volume. There is no
  `agent-2..N` stanza, Pool rendering never applies, and `manage-pool` does
  not apply to this backend. A second instance for the same repository is
  refused by the shared Fleet check (step 1): this backend never advertises
  the `pool` Operator Capability.

## Workflow Configuration

A `workflow/` directory in the instance holds `workflow.yml` (and the prompt
files it names), mounted read-only at `/etc/coding-agent`:

- `target.repository` is the Target Repository, `target.base_branch` its
  default branch. Read the default branch from the target checkout or
  `gh repo view --json defaultBranchRef`.
- `target.token_env` and each model's `api-key-env` name environment
  variables only; values live only in `.env`. `config validate` refuses a
  value that looks like a secret where a name belongs.
- One `implement` Workflow with its Selection Label and limits (all four
  meters: `cost-usd`, `tokens`, `tool-calls`, `wall-clock-minutes`). The
  steps mirror coding-agent's own `examples/workflows.yaml` `implement`
  chain at the ref; re-check them against the `CODING_AGENT_REF` clone when
  it moves.
- **Selection Label.** Suggest `agent:implement`. Reject a label that breaks
  coding-agent's rules and ask for another: `ready-for-human`, `wontfix` or
  any `wayfinder:*` label (contract W-CFG-12; an input carrying `wontfix` or
  `wayfinder:*` is never claimed, P-SEL-4). `config validate` additionally
  refuses a Selection Label that also appears in the same Workflow's filters
  or as an end label of any Workflow in the file.
- The prompt files the steps name (`prompts/implement-policy.md`,
  `prompts/handoff.md`) are copied verbatim from the `CODING_AGENT_REF`
  checkout (step 3b): `config validate` stats every prompt file, so a named
  file must exist next to `workflow.yml`. No `{{...}}` may remain in any
  rendered file.

## Model

Model and provider are chosen within the providers coding-agent's Workflow
Configuration supports at the ref — Anthropic and OpenAI at `9a13c34`
(`anthropic / claude-sonnet-5 / messages`,
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
`simple-coding-agent-profile.yml` is written, no Dockerfile `STACK` block is
rendered, and nothing is baked into the image under
`/opt/agent-profile/` — the repository-owned profile is the only profile,
and the Worker pins it at Claim time. At scaffolding time, run both checks
below against the target checkout and report before writing anything. When
both pass, scaffold without further prompts; when either fails, ask the
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
2. `config validate` through the `agent` one-off seat, with the token
   variable the YAML names and the model's key variable set (they reach the
   container from `.env`):

   ```bash
   docker compose run --rm -v ./workflow:/etc/coding-agent:ro agent config validate \
     --config /etc/coding-agent/workflow.yml --workflow implement
   ```

   Offline and static: no Attempt is opened and no value is printed.
3. `startup-check --repo` with the instance's token (non-mutating, no write
   performed):

   ```bash
   docker compose run --rm agent startup-check --repo <owner>/<repo> --token-env GITHUB_TOKEN
   ```
4. The existing token write-scope check (step 6 of the skill): the
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

Start only the worker (`docker compose up -d worker`: `agent` exits at once
and `validate` needs `TARGET_PROJECT`). Once the operator starts it, the
creation report carries, for the Managed Instance `<short-name>`:

```bash
DOCKER_CONTEXT=<ctx> agentfleet identity <short-name>
DOCKER_CONTEXT=<ctx> agentfleet status <short-name>
```

`identity` shows `backend: coding-agent`, the Target Repository and
capabilities `next-issue` and `stop-after`; readiness is `instance.state`
other than `starting`. Until coding-agent ships the contract producer
(step 4), this part is reported as unverified.
