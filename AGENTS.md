# Agent Forge

This repository hosts configuration and skills for dedicated Docker Compose
instances of [simple-coding-agent](https://github.com/lbacik/simple-coding-agent).
The agent implementation is developed separately and fetched at image build
time. Each instance targets one GitHub repository.

## Instance location

Create every instance in `agent-instances/agent-<name>/`. The entire
`agent-instances/` directory is ignored by Git; keep generated deployments and
their secrets there.

The bundled skills originate from `../simple-coding-agent-env` and are adapted
to the `agent-instances/` layout. Reference instances they name are in the
sibling `../simple-coding-agent-env` project, if available. Treat it as
reference material; make this project's instance changes here.

## Creating instances

For requests to create or configure an agent for a repository, read and use
[create-agent](.agents/skills/create-agent/SKILL.md). It owns the scaffolding,
stack analysis, runtime pins, credentials, and validation workflow. For instances
with bundled services, also read its
[bundled-services reference](.agents/skills/create-agent/references/bundled-services.md).

Use the skill's templates and write a repository profile that mirrors the
target's gating CI checks. Keep the profile local to the instance. If the model
needs service configuration, align its container environment with the profile
as described by the skill.

## Building and starting

Run Compose commands from the selected instance directory:

```bash
cd agent-instances/agent-<name>
docker compose config -q
docker compose build
docker compose up -d
```

Run the build and start steps when requested or already authorized by the user.
After Dockerfile or baked-in profile changes, rebuild before recreating the
container. Validate changes using the skill's applicable checks and report which
checks were run, which passed, and which remain unverified. The repository root
has no shared application test suite or Compose deployment.

## Debugging instances

For startup failures, unsuccessful issue attempts, logs, state, or questions
about an agent's behavior, read and use
[debug-agent](.agents/skills/debug-agent/SKILL.md). Read its
[log-layout reference](.agents/skills/debug-agent/references/log-layout.md)
before inspecting attempt files.

The diagnostic helpers find `agent-instances/` from their own location, so they
work from any working directory. For example, from the project root:

```bash
.agents/skills/debug-agent/scripts/locate-agent.sh <name> [issue-number]
```

Use the Docker context selected by the user consistently for diagnosis and
operations. The helpers default to `orbstack`; pass `--context <name>` for another
context. Identify the instance, context, and relevant run in diagnostic reports,
and support the root cause with the specific logs or events.

Treat persistent agent data as read-only during diagnosis. State changes and
volume deletion require explicit user authorization. Keep credentials out of
tool output and reports.

## Change boundaries

Edit shared scaffolding and diagnostics in `.agents/skills/`; `.claude` is a
symlink to `.agents`, so both paths expose the same files. Edit deployment
configuration inside the selected `agent-instances/agent-<name>/` directory.
Upstream agent fixes belong in the separate `simple-coding-agent` checkout.

Keep [README.md](README.md) aligned with changes to the user workflow or instance
layout.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues (`lbacik/agent-forge`) via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
