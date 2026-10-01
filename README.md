# Agent Forge

Agent Forge is a clean starting point for creating and operating dedicated
[simple-coding-agent](https://github.com/lbacik/simple-coding-agent) instances
for GitHub repositories. It follows the same workflow as the sibling
`../simple-coding-agent-env` project: create an agent with `create-agent`, build
its Docker image, start it with Docker Compose, and investigate problems with
`debug-agent`.

Each instance targets one repository and has its own toolchain, repository
profile, configuration, and persistent Docker volume. The agent's source is
fetched from upstream at build time.

## Project layout

```text
agent-forge/
├── .agents/skills/
│   ├── create-agent/          # Instance scaffolding instructions and templates
│   └── debug-agent/           # Diagnostics instructions and helper scripts
├── .claude -> .agents        # Exposes the same skills to Claude Code
├── .gitignore
├── README.md
└── agent-instances/          # Local instances; ignored by Git
    └── agent-<name>/
        ├── Dockerfile
        ├── compose.yaml
        ├── simple-coding-agent-profile.yml
        ├── .env.example
        ├── .env
        └── agent-entrypoint.sh   # Optional, for bundled services
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
  (`META_API_KEY` in the current template).

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
defaults to `main`. Runtime version pins in the Dockerfile and `.env` must match
the selected upstream version.

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

The named `agent_data` volume stores the working repository, state, and attempt
logs under `/data` in the container. These persist across container recreation.

After rebuilding an updated image, run `docker compose up -d` again to apply it.
To stop the deployment:

```bash
docker compose down
```

This preserves the named volume. Adding `-v` deletes the volume and its agent
data.

### 4. Debug problems

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

## Relationship to simple-coding-agent-env

The skills and templates originate from `../simple-coding-agent-env`. They
have been adapted to Agent Forge: every generated deployment goes to
`agent-instances/agent-<name>/`. The reference instances the skills mention
(for example `agent-jsonhub-web-terminal`, `agent-jsonhub-api`) live in the
sibling project and are read from there when it is available.

The operating workflow remains the same:

```text
create-agent → docker compose build → docker compose up -d → debug-agent
```
