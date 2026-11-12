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
  (`/var/lib/coding-agent/operator`) that coding-agent's contract `agentctl`
  documents for private IPC. The listener enforces 0700 on the directory and
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
own Project Profile, read at the Base Revision, stays the only profile. At
scaffolding time, check the target checkout and report before writing
anything:

- The checkout contains its own Project Profile. A missing profile is
  reported and the operator decides.
- The runtime versions the profile declares are inside the image's Supported
  Toolchain Matrix (`/opt/coding-agent/toolchain-matrix.json` in the image,
  generated at build time from the toolchains the build produced — Python
  with uv, PHP with Composer, Node with pnpm). An out-of-matrix requirement
  is reported as an Unsupported Environment, and the skill asks before
  scaffolding anyway.

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
4. The existing token-scope check (step 6 of the skill): the fine-grained PAT
   must reach contents, pull requests and issues of the Target Repository.
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
