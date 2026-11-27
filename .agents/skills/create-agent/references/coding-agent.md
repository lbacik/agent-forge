# coding-agent adapter

Read this when step 0 of `create-agent` chose the `coding-agent` backend,
or when the operator asks to upgrade an existing coding-agent Instance to
the derived-image layout ("Upgrading an existing coding-agent Instance"
below).

Terms are defined in `CONTEXT.md` (Instance, Worker, Worker identity) and in
the operator contract glossary (Managed Instance, Fleet, Target Repository,
Operator Capability, Status Snapshot).

Source facts below were read at coding-agent `v0.4.0` (`2626351`) unless
noted; the `triage` Workflow, the Advisor, `input.comments` and
`draft-skill-policy` were read at `v0.5.0` (`38fa92e`). The skill re-checks
the HOWTOs against the chosen `CODING_AGENT_REF` clone (step 3b) before
scaffolding.

## What this adapter renders

An `agent-instances/agent-<name>/` directory holding a Compose deployment of
coding-agent's `worker` with its Workflow Configuration — a derived-image
Dockerfile, no stack block, no Forge-owned profile:

| File | Source |
|---|---|
| `compose.yaml` | `assets/compose.coding-agent.yaml.template` |
| `Dockerfile` | `assets/Dockerfile.coding-agent.template`, copied verbatim (the derived deployment image) |
| `workflow/workflow.yml` | `assets/workflow.coding-agent.yml.template` (`version: 4`, with a `skills:` block and the selected Workflows) |
| `workflow/prompts/*.md` | `implement`: copied from the `CODING_AGENT_REF` checkout (see step 3b); `triage`: copied verbatim from `assets/prompts/` |
| `workflow/skill-policy.json` | the reference bundle (`implement` alone): copied verbatim from the `CODING_AGENT_REF` checkout's `docker/deployment/`; any other bundle: drafted and completed with operator-approved decisions ("Drafting the skill policy") |
| `compose.coding-agent.litellm.yaml` | `assets/compose.coding-agent.litellm.yaml.template`, only when a Worker uses a gateway pin whose `url` names a Docker service |
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
- **Services.** `worker` and, in a two-Worker Pool, `worker-2` (each
  labelled with the four discovery labels, `backend` = `coding-agent`) run
  `agent run` with the full v3 flags (see "The derived image" below);
  `agent` and `validate` are unlabelled one-off seats
  (`docker compose run --rm ...`) on the same derived image, so `validate`
  and `startup-check` see the same toolchains and the same baked package as
  the Workers. `engine` is the build-only base image (never run, never
  labelled). So that a bare `docker compose up -d` starts the Workers
  alone, `engine` has `scale: 0` and `agent` and `validate` are in the
  `tools` profile. Naming a service (`docker compose run --rm validate`)
  enables its profile, so the one-off commands need no `--profile`. `engine`
  must not take a profile: an inactive profile drops it from the model, and
  then the `service:engine` build context fails to resolve and every
  command fails, `docker compose config` included. `scale: 0` is a plain
  Compose Specification field and needs no swarm.
  `docker compose config --services` lists `engine` and the Worker
  services; add `--profile '*'` to list the one-off seats too. `worker`,
  `agent` and `validate` share the state volume `state` at coding-agent's
  state path (`/var/lib/coding-agent`, read at the ref); `worker-2` has its
  own, `state_2`.
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
  `limits` (cost, effective tokens, tool calls, wall clock) budget an Attempt and do
  not bound host resources.
- **At most one Worker per Workflow** (`docs/adr/0005-coding-agent-pool-one-worker-per-workflow.md`).
  A single Worker is service `worker`; with both Workflows declared, the
  operator may run a second Worker, `worker-2` (the template's marked
  stanza), on the Workflow `worker` does not run. Each Worker has its own
  state volume (`state`, `state_2`), its own Managed Instance name
  (`<short-name>`, `<short-name>-2`) and its own `--workflow`; no Worker id
  and no Claim marker are rendered. Two Workers on one Workflow are
  refused: this backend never advertises the `pool` Operator Capability and
  leaves no Claim marker, so they would race on one Queue. Running two
  Workers departs from the operator contract's rule that an adapter without
  `pool` refuses a second Managed Instance on the same Target Repository
  and host; the creation report says so. `manage-pool` adds or removes
  `worker-2` later ("coding-agent Instances" there). A second coding-agent
  Instance for the same repository is still refused by the shared Fleet
  check (step 1). An Instance of another
  backend on that repository (for example a simple-coding-agent Instance
  implementing the issues a coding-agent `triage` Workflow hands it) does
  not refuse: the operator confirms the pairing once, and the report states
  that keeping the two Instances' selection labels apart is the operator's
  responsibility (SKILL.md, step 1, "Pairing with another backend";
  `docs/adr/0003-one-instance-per-backend-without-label-checks.md`).
- **Name.** The short name is `<project>-<suffix>`, with this backend's
  suffix from the backend suffix table in SKILL.md, step 0 (for example
  `agent-instances/agent-jsonhub-api-rex/` with the Managed Instance
  `jsonhub-api-rex`, and `jsonhub-api-rex-2` for `worker-2`).

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
   the prompts of its own Workflows.
2. **Preparation.** As the runtime user (`agent`) with no Worker GitHub or
   model secret set: `agent config validate --workflow <id>` once per
   Workflow id in the `WORKFLOWS` build argument (compose.yaml's
   `build.args`, rendered as the declared ids, space-separated), then
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
4. **The rendered `run` invocation.** Each Worker starts with the upstream
   rendered form, its own Workflow written into its stanza:
   `agent run --config /etc/coding-agent/workflow.yml --workflow
   <implement|triage> --state-dir /var/lib/coding-agent
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

A `workflow/` directory in the instance holds `workflow.yml` (a `version: 4`
Workflow Configuration), the prompt files it names, and the reviewed
`skill-policy.json`, baked into the derived image at `/etc/coding-agent`:

- `version: 4` is the only accepted format since coding-agent 0.4.7: a
  `version: 3` (or `version: 2`) file is refused with a migration diagnostic
  before any Claim, at build time in the derived image's `config validate`
  step. Version 4 declares `context-window-tokens`,
  `context-threshold-tokens` and `output-cap-tokens` on every pin and names
  the token meter `effective-tokens` in every `limits` block (a `tokens`
  key is refused as unknown). Point the editor `$schema` at
  `schemas/workflow-v4.schema.json`. An existing `version: 3` Instance moves
  with "Moving an Instance from `version: 3` to `version: 4`" below.

- `target.repository` is the Target Repository, `target.base_branch` its
  default branch. Read the default branch from the target checkout or
  `gh repo view --json defaultBranchRef`.
- `target.token_env` and each model's `api-key-env` name environment
  variables only; values live only in `.env`. `config validate` refuses a
  value that looks like a secret where a name belongs.
- `skills:` declares the Skill Bundle membership, one entry from
  `git+https://github.com/mattpocock/skills.git` at
  `3cca18b368ae95cdbdebbff572ccafa662551015`. `implement` adds the
  reference deployment's selection (`docker/deployment/workflow.yml` at the
  ref: `implement, tdd, code-review, codebase-design`); `triage` adds
  `triage, grilling, domain-modeling` (all three exist at that commit; the
  triage skill invokes the other two). The template's `{{SKILL_INCLUDE}}`
  renders the members of the declared Workflows, `implement`'s first. There
  is no implicit bundle: a missing `skills` field means an empty bundle,
  every static `skill:` reference must name a declared member, and every
  member needs a reviewed entry in `skill-policy.json`. The whole
  declaration is the bundle whatever `--workflow` a Worker selects. The
  template keeps the Forge step graph for `implement` (`preflight → process
  → validate → self-review → push → open-pr`, plus `explain-blocked`, the
  reserved `ai-handoff` and `hard-handoff`); it does not adopt the
  reference's smaller `implement` graph or its `review` workflow.
- `skill-policy.json` covers exactly that bundle. For the reference bundle
  (`implement` alone) it is copied verbatim from the `CODING_AGENT_REF`
  checkout's `docker/deployment/` into the instance's `workflow/`, byte for
  byte; Forge keeps no copy of its own. Any other bundle (one with
  `triage`) gets a policy drafted with `agent draft-skill-policy` and
  completed with the operator's decisions ("Drafting the skill policy"
  below). The skill writes only the decisions the operator approved and
  never approves on its own (`docs/adr/0004-forge-drafts-skill-policy-operator-approves.md`);
  a changed bundle membership or source ref means drafting and reviewing
  again. (Secret-free `config validate` passes even when the policy file
  is missing, but the derived-image build does not:
  `prepare-skill-bundle --mode install` and the final-root
  `verify-skill-bundle` fail the build on a missing, unresolved or
  mismatched policy — still check the file is there, and byte-identical
  for the reference bundle, when scaffolding.)
- The declared Workflows (see "Workflow selection" below). `implement` has
  its Selection Label and Attempt Ceiling
  (all four meters: `cost-usd`, `effective-tokens`, `tool-calls`,
  `wall-clock-minutes`). The Work Pool is the ceiling minus the reserved
  `ai-handoff` allowance (`cost-usd: 1`, `effective-tokens: 150000` or the
  pin's Admission floor, `tool-calls: 30`, `wall-clock-minutes: 5`), per meter, and every non-reserved Step
  Allowance (`process`, `self-review`) must fit in it on every meter it
  sets — otherwise `config validate` refuses the file (for example, a 5 USD
  ceiling leaves a 4 USD Work Pool that the default 12 USD `process`
  allowance does not fit). When an allowance does not fit, or the ceiling is
  not larger than the reserve on some meter, the skill stops before writing
  the Workflow Configuration, names each step with its allowance and the
  Work Pool, and asks the operator for new allowances or a higher ceiling;
  it never scales or clamps allowances itself, and the reserve stays as is
  apart from the Admission floor.
- **Admission floor** (contract §3, version 4). Every limit that declares
  `effective-tokens` or `cost-usd` — the Attempt Ceiling, the Work Pool, the
  `ai-handoff` reserve and any Step Allowance declaring the meter — must hold
  one maximal Admission hold: `effective-tokens` >= Usable Threshold +
  `output-cap-tokens`, `cost-usd` >= Usable Threshold × `input`
  (max(`input`, `cache-write`) on a gateway pin) + `output-cap-tokens` ×
  `output`, per MTok. The Usable Threshold is `context-threshold-tokens`
  minus the code-owned 1,000 safety margin and 1,000 request overhead. The
  `ai-handoff` effective-tokens reserve renders as 150000, or as that floor
  when the pin's threshold needs more: 150000 holds a direct pin at the
  recommended 80,000 / 32,000, while a gateway pin at 400,000 / 32,000
  needs 430,000.
- **Selection Label** (`implement`). Suggest `agent:implement`. Reject a
  label that breaks coding-agent's rules and ask for another:
  `ready-for-human`, `wontfix` or any `wayfinder:*` label (contract
  W-CFG-12; an input carrying `wontfix` or `wayfinder:*` is never claimed,
  P-SEL-4). `config validate` additionally refuses a Selection Label that
  also appears in the same Workflow's filters or as an end label of any
  Workflow in the file. With `triage` declared too, that rules out
  `ready-for-agent` and `needs-info` (its end labels), and the skill also
  rejects `needs-triage` (`triage`'s own Selection Label, which would put
  both Workers on one Queue). So a `triage` Worker never hands an issue to
  the `implement` Worker of the same Instance by label: a human moves a
  `ready-for-agent` issue to the `implement` label, or a simple-coding-agent
  Instance paired on the repository takes `ready-for-agent` (ADR 0003).
- The prompt files the steps name are rendered next to `workflow.yml`:
  `implement`'s (`prompts/implement-policy.md` from
  `docker/deployment/prompts/`, `prompts/handoff.md` from
  `examples/prompts/` — `handoff.md` lives only there at the documented ref)
  are copied verbatim from the `CODING_AGENT_REF` checkout (step 3b),
  recording the source path per file; `triage`'s
  (`prompts/triage-policy.md`, `prompts/triage-advisor.md`) are copied
  verbatim from this skill's `assets/prompts/`. `config validate` stats
  every prompt file, so a named file must exist next to `workflow.yml`. No
  `{{...}}` may remain in any rendered file.

## Workflow selection

Ask the operator (AskUserQuestion, recommended option first) which
Workflows the Workflow Configuration declares — `implement` (default),
`triage`, or both — and which Workflow each Worker runs:

- one Workflow: one Worker, `worker`, running it;
- both Workflows: either one Worker (`worker`, running the Workflow the
  operator names; the other stays declared for a later `worker-2`) or two
  Workers (`worker` on `implement`, `worker-2` on `triage`, unless the
  operator swaps them). Never two Workers on one Workflow
  (`docs/adr/0005-coding-agent-pool-one-worker-per-workflow.md`).

`triage` needs `CODING_AGENT_REF` `v0.5.0` or newer, the first release
with `input.comments` and the `advisor` tool group. `main` qualifies; a
release tag qualifies by semantic version comparison; any other branch or
SHA qualifies when its checkout's `docs/ops/workflow-configuration.md`
documents both `input.comments` and the `advisor` tool group. Otherwise
refuse `triage` and say why: that ref's `config validate` refuses
`input.comments` and the `advisor` group, so the image would not build.
Offer `v0.5.0` (or `main`) instead, or `implement` alone.

The choices fix what gets rendered:

| Choice | Rendered |
|---|---|
| Workflows declared | The `workflow-implement-*` and `workflow-triage-*` ranges of the Workflow Configuration template kept or deleted (markers deleted either way); `{{SKILL_INCLUDE}}`; the `WORKFLOWS` build argument (`{{WORKFLOWS}}` in compose.yaml: the declared ids, space-separated, `implement` first) |
| Each Worker's Workflow | `{{WORKER_WORKFLOW}}` (and `{{WORKER_2_WORKFLOW}}`) in compose.yaml; for a single Worker every `worker-2-begin` … `worker-2-end` range is deleted (the stanza and the `state_2` volume), for two Workers only the marker lines |
| Pins | `main` for `implement`; `triage` and `triage-advisor` for `triage` (see "Model") |
| Keys | Each Worker's model key lines, and every key some pin names in `.env` (see "Model") |

The Workflow is the Worker's own configuration: it is written into the
Worker's stanza (`--workflow`), not into `.env`. Changing it later means
editing that stanza and recreating the container (`docker compose up -d
<service>`); no rebuild is needed while the Workflow stays declared.

## The `triage` Workflow

The template's `triage` Workflow (rendered as is; only its Attempt Ceiling
and pins are filled in) takes issues labelled `needs-triage`, runs the
`triage` skill against the checkout, and ends with the issue labelled
`ready-for-agent`, `needs-info` or `ready-for-human`:

- `input: {type: issue, label: needs-triage, exclude: [needs-info,
  ready-for-human, wontfix]}`. Re-triage happens when a human swaps
  `needs-info` back to `needs-triage`.
- One agent step, `triage`: instructions `skill: triage` and `prompt:
  prompts/triage-policy.md`; tools `workspace-read`, `workspace-write`,
  `shell`, `advisor`; `advisor: {model: triage-advisor, prompt:
  prompts/triage-advisor.md}`; `input.comments` as a required input (the
  issue's Trusted Comments pinned at Claim, so re-triage sees the earlier
  notes and the reporter's answers).
- Three results, each with one `document`: `ready {brief}` ends
  `completed` (end label `ready-for-agent`), `blocked {notes}` ends
  `blocked` (`needs-info`), `human {recommendation}` ends `unfinished`
  (`ready-for-human`; also used for a `wontfix`, already-implemented or
  split recommendation, because coding-agent cannot close, split or
  categorise an issue). `failed` and `internal-failure` also get
  `ready-for-human`, and so do the runtime-only `interrupted` and `drift`
  (both Workflows declare them: without end labels the runtime removes
  `needs-triage` and applies nothing, so the issue leaves every queue
  unlabelled). `withdrawn` stays unlabelled: a human removed the label or
  closed the issue.
- Every result path runs `post-comment` of that result's document, then
  `commit-and-push`, then, on `pushed`, `open-pull-request` with `draft:
  true` and the same document as the body (a draft gets the non-closing
  `Part of #N`, never `Closes #N`), then the Workflow End; on
  `no-changes` it goes straight to the Workflow End. The draft pull
  request carries what the skill wrote (`CONTEXT.md`, ADRs,
  `.out-of-scope/`).
- No `check-readiness` and no `run-validation`: triage changes no code.
- `defaults.routes` send `error` and `limit-exceeded` to `hard-handoff`, a
  single `commit-and-push` that ends `unfinished` (and `failed` on its own
  `error` or `limit-exceeded`), as `implement`'s Hard Handoff does. There
  is no AI-assisted Handoff and no Reserved Step, so the Work Pool is the
  whole Attempt Ceiling.
- **Attempt Ceiling.** Ask the operator for all four meters (suggest
  `cost-usd: 10`, `effective-tokens: 3000000`, `tool-calls: 300`,
  `wall-clock-minutes: 45`; placeholders `{{TRIAGE_LIMIT_*}}`). Every limit
  declaring `effective-tokens` or `cost-usd` must hold one maximal
  Admission hold of the triage pin **and** of the Advisor pin (Usable
  Threshold + output cap, and that hold priced at the pin's prices;
  `config validate` names the Advisor pin when it is the larger one).
  Check before writing, and stop and ask when the ceiling falls short.

The policy prompts are Forge assets (`assets/prompts/`), copied verbatim:
they answer the interactive parts of the skill and never rewrite it
(coding-agent ADR 0007). `triage-policy.md` makes an agent brief (`ready`)
the goal: an exploration or not-yet-designed issue is grilled into a spec
here, and `human` is kept for `wontfix`, split, work an AFK agent cannot do,
or a decision the Advisor could not make. Advisor calls stay small (at
most three questions, evidence quoted) because each call has coding-agent's
code-owned 8-round bound, and an unanswered call is asked again smaller,
never read as "cannot decide". It tells the model there is no
maintainer to wait for (questions go to the Advisor through
`ask_advisor`), that the runtime applies the labels from the result, that
the result is `ready`, `blocked` or `human` with a document following the
skill's agent-brief, triage-notes or recommendation template, that
categories cannot be applied and an issue can be neither closed nor split,
that the files grilling or domain-modeling write are committed and
land in the draft pull request, and that a re-triage document opens with a
`**Supersedes:**` line, because readers get every earlier triage document
too. `triage-advisor.md` makes the Advisor the
maintainer's proxy with authority to make design decisions: it decides
from the issue, its comments, the repository's own docs and ADRs and the
code, and says "cannot decide" only for a reporter-only fact, a decision
that would reverse a recorded one, or one outside the repository's
authority. It batches its reads and reports by its sixth round, with
provisional decisions marked "not verified" when the reads run short.

## Drafting the skill policy

Any bundle other than the reference one (in practice: one with `triage`)
needs its own `skill-policy.json`
(`docs/adr/0004-forge-drafts-skill-policy-operator-approves.md`). Draft it
after `workflow/workflow.yml` and the prompts are rendered and before the
derived image builds, against the same `CODING_AGENT_REF` and source ref
the image will use:

1. **Build the engine base** on the Instance's Docker context (the heavy
   part of every build; the derived build reuses it):

   ```bash
   docker compose build engine
   ```

2. **Install and draft in a one-off container** on that image. The
   `workflow/` directory goes in through stdin as a tar stream, so this
   works on a remote context too (a bind mount would name a path on the
   remote host). The install runs against the reference policy baked into
   the engine image (`/etc/coding-agent/skill-policy.json` at the same
   ref) and is expected to end with "has no matching approved review" for
   the new members: the store is installed by then, and the draft reads it
   and carries forward every review that still matches. The review report
   goes to stderr, the draft to stdout; keep both outside the instance
   directory (in the skill's scratchpad):

   ```bash
   COPYFILE_DISABLE=1 tar -C workflow -cf - . | docker run --rm -i --entrypoint sh \
     coding-agent-engine:<short-name> -c '
       set -e
       w=$(mktemp -d) home=$(mktemp -d) bundle=$(mktemp -d) out=$(mktemp)
       tar -xf - -C "$w"
       if ! agent prepare-skill-bundle --mode install --config "$w/workflow.yml" \
         --policy /etc/coding-agent/skill-policy.json \
         --bundle-dir "$bundle" --home "$home" 2>"$w.err" >&2; then
         cat "$w.err" >&2
         if grep FAILED "$w.err" | grep -qv "has no matching approved review"; then
           echo "install failed: see above" >&2; exit 1
         fi
       fi
       agent draft-skill-policy --config "$w/workflow.yml" --home "$home" \
         --policy /etc/coding-agent/skill-policy.json --out "$out" >&2
       cat "$out"' \
     >"<scratchpad>/skill-policy.draft.json" 2>"<scratchpad>/skill-policy.report.txt"
   ```

   The only prepare failure tolerated is "has no matching approved
   review" for a member; any other failure (the install itself) stops the
   command with "install failed", and so does a failing
   `draft-skill-policy`. Then stop and show the report file.

3. **Review with the operator.** Show the review report. Every JSON `null`
   in the draft is a placeholder decision; reviews that still match the
   reference policy (the four `implement` members at the reference commit)
   carry forward unchanged and need none. For each placeholder, propose a
   decision with its reason and ask the operator (AskUserQuestion, up to
   four questions per call, the proposal first). Ask per decision — one per
   file, one per reference, one per review — never one approval for a
   whole member or the whole draft: a file's disposition decides what
   reaches a model's context.
   - A file's `disposition` and `reason`: `inject` delivers the file with
     the skill's activation (companion files the skill tells the model to
     read, such as `AGENT-BRIEF.md`, `OUT-OF-SCOPE.md`, `ADR-FORMAT.md`,
     `CONTEXT-FORMAT.md`); `not-delivered` installs it but never delivers
     it (administrative files such as `agents/openai.yaml`).
   - A reference's `classification` and `reason`: `not-a-skill-reference`
     for text that only looks like a skill reference (paths, examples) or
     invokes a declared member (that member then also goes into the
     review's `requires`); `unavailable-nonrequired-reference` for a skill
     outside the bundle, such as `/setup-matt-pocock-skills`, which also
     needs a `target` (the skill's name) and a `notice` the model sees.
     A report line marked "merge by hand" names a reference whose drafted
     `text` cuts a shared token: include the corrected text in that
     reference's decision.
   - A review's `reason`, and its `requires` when the report lists
     candidates (the triage skill invokes `grilling` and
     `domain-modeling`).

   Write a decision into the draft only after the operator approved it, in
   the form the operator approved; never fill a placeholder on your own.
4. **Write the policy.** When no `null` remains, save the completed draft
   as `workflow/skill-policy.json`. The derived-image build proves it:
   `prepare-skill-bundle --mode install` and the final-root
   `verify-skill-bundle` refuse an unresolved, inconsistent or mismatched
   policy ("Validation", step 2). When the operator stops before every
   placeholder is resolved, write no `workflow/skill-policy.json`, say the
   image cannot build yet, and keep the draft with the decisions made so
   far in the report.

The reference bundle needs no drafting: copy
`docker/deployment/skill-policy.json` from the ref checkout verbatim (the
command would carry every review forward unchanged).

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
| `MAX_BUDGET_TOKENS` | `limits.effective-tokens`. Effective tokens exclude prompt-cache reads (`src/coding_agent/runtime/ceilings.py`) | workflow |
| `MAX_TURNS` | `limits.tool-calls`. Plus the code-owned `MAX_AGENT_ITERATIONS = 30` tool-loop backstop per Step Execution (see the caveat below) | workflow + code |
| `SOFT_THRESHOLD_PERCENTAGE`, `HANDOFF_RESERVE_TURNS` | The Reserved Step `ai-handoff` (`reserved: true`, allowance on all four meters) | workflow |
| `MODEL_TIMEOUT` | `limits.wall-clock-minutes` (the whole Attempt, operations included) | workflow |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` / `MAX_CONTEXT_TOKENS` | `context-threshold-tokens` / `output-cap-tokens`, with `context-window-tokens` for the window — declared on every pin since `version: 4` (see below). Companion backstop `MAX_HANDOFFS_PER_STEP = 5` (`src/coding_agent/runtime/context_handoff.py`) | workflow + code |
| `POLL_INTERVAL` | `worker.poll-interval-seconds` (default 60 s) | workflow |
| `MODEL_STREAM_IDLE_TIMEOUT_MS` | 300 s per model request, capped by the remaining wall-clock time (`DEFAULT_CODE_OWNED_MODEL_TIMEOUT_SECONDS` in `src/coding_agent/runtime/step_limits.py`) | code |
| `PUBLISH_TIMEOUT` | 600 s per operation command (`OPERATION_TIMEOUT_SECONDS` in `src/coding_agent/runtime/step_operations.py`; the per-command timeout in `src/coding_agent/runtime/step_limits.py` is likewise 600 s) | code |
| `MAX_RETRIES` | Provider retry, 3 attempts (`DEFAULT_MAX_ATTEMPTS` in `src/coding_agent/provider/retry.py`); GitHub in-place retry, bounded at 3 attempts / 5 minutes (`src/coding_agent/github/errors.py`) | code |
| `MAX_CONSECUTIVE_ERRORS` | `MAX_CONSECUTIVE_INFRASTRUCTURE_FAILURES = 3` (`src/coding_agent/worker/run.py`): that many consecutive infrastructure failures halt the Worker | code |
| `MAX_AUTO_CONTINUATIONS` | None by design ("No Continuation across Attempts"): `unfinished` is an end label, not a resume | n/a |
| `MAX_CONFLICT_ATTEMPTS`, `PR_AUTO_MERGE`, `PR_MERGE_METHOD` | None: the only publishing operation is `open-pull-request` (draft flag `false` for `implement`, `true` for `triage`), so there is nothing to merge automatically and no conflict requeue | n/a |
| `WORKER_CPUS` / `WORKER_MEM_LIMIT` / `WORKER_PIDS_LIMIT` | Compose `x-agent` anchor in `assets/compose.coding-agent.yaml.template` (#103) | deployment |

Every **code** value above is a constant at the stated ref, to be re-read
when `CODING_AGENT_REF` moves — not a setting to copy anywhere.

- **Context fields on every pin.** Since `version: 4` (coding-agent 0.4.7)
  every pin, direct or gateway, declares `context-window-tokens`,
  `context-threshold-tokens` and `output-cap-tokens`; the code-owned table
  in `src/coding_agent/provider/config.py` admits the (`provider`, `model`,
  `endpoint`) triple only and carries no token budget. The safety margin,
  request overhead and handoff cap stay code-owned.
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

Every declared Workflow brings its pins: `implement` the `main` pin (the
Attempt's one Pinned Model), `triage` the `triage` pin and the
`triage-advisor` pin its step's Advisor answers on (the maintainer proxy,
typically a stronger model, for example muse for `triage` and Opus as the
Advisor). Ask the operator for each pin as below — its model and route,
its prices and its three token keys — and confirm each separately. Each
pin is either a direct `provider:` pin or a `gateway:` pin through a Model
Gateway (coding-agent `docs/ops/workflow-configuration.md`, "Gateway
pins", at the ref): exactly one of `provider` or `gateway` is present, and
each pin chooses its own route, so one Instance may use both
(`docs/adr/0002-one-pool-per-docker-context-without-swarm.md`). A pin
routed through the LiteLLM gateway puts the whole Instance on the
gateway's Docker context. `MODEL_*` / `MODEL_BASE_URL` do not apply on
this backend — for the simple-coding-agent routes see
`references/model-backend.md` instead.

A direct pin's (`provider`, `model`, `endpoint`) triple must come from the
code-owned table in coding-agent's `src/coding_agent/provider/config.py` at
the ref — Anthropic and OpenAI at the documented ref
(`anthropic / claude-sonnet-5 / messages`,
`openai / gpt-5.6-luna / responses`); any other pair refuses startup.
`effort` is low, medium or high. Its three token keys default to the
upstream recommendation (`docs/ops/workflow-configuration.md` at the ref):
1,000,000 / 80,000 / 32,000 for `claude-sonnet-5` and 1,050,000 / 100,000
/ 32,000 for `gpt-5.6-luna` (window / threshold / output cap). The threshold
counts provider-reported tokens since the anchored measure (coding-agent ADR
0031).

A gateway pin carries the same three keys, always asked from the operator:

```yaml
models:
  main:
    gateway: {kind: litellm, url: http://litellm:4000}
    model: muse-spark-1.3-contributor   # the gateway's L1 alias
    endpoint: responses
    effort: high                        # muse always runs at high and reports it
    api-key-env: LITELLM_PROXY_API_KEY
    context-window-tokens: 1000000
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
  or high — at `v0.5.0` it must be the effort the gateway reports (Meta
  `muse-spark-1.3-contributor` runs at `high`; any other effort refuses
  startup).
- `context-window-tokens`, `output-cap-tokens` and
  `context-threshold-tokens` are the pin's own Model Context Window, output
  cap and context-window threshold; `context-threshold-tokens +
  output-cap-tokens` must not exceed the window. The threshold triggers Context-Window Handoffs (coding-agent ADR
  0013): the Handoff continues the same Step Execution against its Step
  Allowance and Attempt Ceiling, and Handoffs per step are bounded by the
  code-owned `MAX_HANDOFFS_PER_STEP` (`5` at the documented ref). The
  threshold must exceed the code-owned safety margin plus request overhead
  (`1000 + 1000` at the documented ref). Ask the operator for all three
  values; never default them. A threshold above 152,000 with a 32,000 cap
  raises the `ai-handoff` effective-tokens reserve above 150000 (see the
  Admission floor under "Workflow Configuration").
- Prices (`prices-usd-per-mtok`: `input`, `output`, `cache-read`,
  `cache-write`) come from the operator — confirm them, never default them
  — because the pin's configured prices are the Worker's only cost
  authority (a gateway response header such as `x-litellm-response-cost` is
  never read, not even as evidence). For a Meta model, which has no
  cache-write premium, set `cache-write` equal to `input`: a gateway
  response that reports no `cache_write_tokens` is priced at max(`input`,
  `cache-write`).

Every pin has the same placeholders in the template, prefixed by the pin
(`MAIN_`, `TRIAGE_`, `ADVISOR_`): `ROUTE`, `MODEL`, `ENDPOINT`, `EFFORT`,
`API_KEY_ENV`, the three token keys and the four prices. `{{<PREFIX>_ROUTE}}`
renders as the pin's one route line: `provider: <provider>` for a direct
pin (with `endpoint` `messages` for Anthropic, `responses` for OpenAI), or
`gateway: {kind: litellm, url: <url>}` for a gateway pin (with `endpoint`
`responses`). A direct pin carries no `gateway:` key and a gateway pin no
`provider:` key; both carry the three token keys. Pins of an undeclared
Workflow are deleted with its `workflow-*` range. No `{{...}}` may remain.

Each Worker gets the key variables of its own pins and no others: its
Workflow's pin, plus the Advisor pin for `triage` — `ANTHROPIC_API_KEY` or
`OPENAI_API_KEY` for a direct pin, `LITELLM_PROXY_API_KEY` for a gateway
pin, whichever `models.<id>.api-key-env` names. In each Worker stanza of
`assets/compose.coding-agent.yaml.template`, keep exactly those model key
lines and delete the others. No key is added to the `agent` or `validate`
seats' environment, and the template sets no `env_file:` (as in upstream's
`compose.yaml`), which would copy every `.env` key into every seat. `.env`
still feeds Compose interpolation; secret-free `config validate` needs no
environment and `startup-check` needs only `GITHUB_TOKEN`, which the shared
anchor passes explicitly. In `.env` (and `.env.example`) every key some pin
names is set and the others stay commented out, as documented next to the
model keys in `assets/env.coding-agent.example.template`.

A gateway `url` naming a Docker service needs the gateway network overlay:
`assets/compose.coding-agent.litellm.yaml.template` attaches the Workers
that use such a pin — and only those, never a one-off seat — to the
external network named by `GATEWAY_NETWORK`, enabled from the env file
(`COMPOSE_FILE=compose.yaml:compose.coding-agent.litellm.yaml`,
`GATEWAY_NETWORK` from `.env`, never hard-coded). Keep the overlay's
`worker` entry and `worker-2` block only for a Worker whose pins include a
gateway pin. Do not reuse `compose.litellm.yaml` here: it attaches services
named `agent` and `agent-<n>`, and on this backend `agent` is the
unlabelled one-off seat, not a Worker. A host-URL `gateway.url` needs no
overlay. The skill never starts or configures the gateway itself; it only
joins its network.

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
   runs, as the runtime user, `agent config validate` once per declared
   Workflow (the `WORKFLOWS` build argument), then
   `agent prepare-skill-bundle --mode install`, then `agent
   verify-skill-bundle` against the final roots — and fails when any of
   them fails (a byte-edited prompt, an undeclared skill or a policy with
   an unresolved placeholder fails here, the same refusal `run` would
   raise at startup). The build needs network access for the skill
   install; it needs no Worker GitHub or model secret.
3. Secret-free `config validate` through the built `agent` one-off seat,
   once per declared Workflow, with no secrets set (neither the token
   variable the YAML names nor any model key variable is needed —
   validation is static):

   ```bash
   for workflow in <declared ids>; do
     docker compose run --rm agent config validate \
       --config /etc/coding-agent/workflow.yml --workflow "$workflow"
   done
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

Build first, then start only the Workers (`docker compose up --build -d
worker`, plus `worker-2` in a two-Worker Pool: `agent` exits at once and
`validate` needs `TARGET_PROJECT`). Any edit under `workflow/` needs
`docker compose build` before the containers are recreated — the package
is baked into the image, so a recreated container without a rebuild keeps
running the old package. Once the operator starts them, the creation
report carries, for each Managed Instance (`<short-name>`, and
`<short-name>-2` for `worker-2`):

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
   settings (Selection Label, Attempt Ceiling, Step Allowances). The old
   Instance declares `implement` alone, so the reference policy and the
   `implement` prompts apply; the Worker's Workflow (the old `.env`'s
   `WORKFLOW`, default `implement`) goes into the `worker` stanza's
   `--workflow`, and the old `WORKFLOW` line is dropped from `.env`. The
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
   3. `docker compose run --rm agent config validate --config /etc/coding-agent/workflow.yml --workflow <id>`, once per declared Workflow
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

## Moving an Instance from `version: 3` to `version: 4`

Read this when an Instance already on the derived-image layout moves its
`CODING_AGENT_REF` to coding-agent 0.4.7 or later. Without it the build
fails at the instance Dockerfile's `agent config validate` step with
`unsupported version 3: must be 4`, before anything is installed or
written. Upstream treats this as a coordinated upgrade, not a restart (its
"Upgrading: drain, backup and rollback"; the new release refuses to
recover records it did not write), so the drain, image tag, backup,
validation, rollback and after-upgrade steps of "Upgrading an existing
coding-agent Instance" above apply unchanged — name the backup and image
tag `-pre-v4` / `-wf3-<short-sha>`. Only step 4 differs: instead of
re-rendering, edit the existing `workflow/workflow.yml` in place and keep
every other file:

1. `version: 3` → `version: 4`, and the `$schema` comment to
   `schemas/workflow-v4.schema.json`.
2. On the pin, add `context-window-tokens` (and, on a direct pin,
   `context-threshold-tokens` and `output-cap-tokens`, which it newly
   declares). Take the direct-pin values from the upstream recommendation
   and ask the operator for a gateway pin's window; keep an existing
   gateway threshold and cap unless the operator changes them.
3. Rename `tokens` to `effective-tokens` in the Workflow `limits` and in
   every step `limits`. The meter now excludes prompt-cache reads; tell
   the operator the same number is a looser budget than before.
4. Check the Admission floor ("Workflow Configuration" above): an
   `ai-handoff` reserve of 150000 does not hold a gateway threshold above
   152,000 with a 32,000 cap. Raise only that reserve to the floor, show
   the operator the resulting Work Pool, and stop and ask if an allowance
   no longer fits.

For the reference bundle, `skill-policy.json` and the `implement` prompts
still come byte-identical from the new ref; compare them and re-copy a file
that changed. The `triage` prompts come from this skill's
`assets/prompts/`. A drafted policy (a bundle with `triage`) is drafted
again against the new ref ("Drafting the skill policy"): reviews whose
members did not change carry forward, and only new placeholders go to the
operator.
