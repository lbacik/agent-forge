---
name: create-agent
description: Create a new, dedicated simple-coding-agent instance (Dockerfile, compose.yaml, .env, .env.example and a local repository profile) for a GitHub repository, in this agent-forge project (always under `agent-instances/agent-<name>/`). Use this whenever the user gives a repository URL or owner/repo and wants an agent "for" it — e.g. "create an agent for https://github.com/x/y", "set up simple-coding-agent for my Go service", "przygotuj agenta dla ...", "new agent instance like agent-jsonhub-api" — even if they don't say "create-agent" explicitly.
---

# create-agent

Scaffold one `agent-instances/agent-<name>/` directory in this repo that builds
and runs [simple-coding-agent](https://github.com/lbacik/simple-coding-agent)
against a single target repository. `agent-instances/` is ignored by Git, so
the instance and its secrets never get committed. Never create an instance
anywhere else.

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

The output is always these files in `agent-instances/agent-<name>/`:

| File | Source |
|---|---|
| `Dockerfile` | `assets/Dockerfile.template` + a stack block |
| `compose.yaml` | `assets/compose.yaml.template` |
| `simple-coding-agent-profile.yml` | written from the target repo's CI |
| `.env.example` | `assets/env.example.template` |
| `.env` | same as `.env.example` + real secrets (ignored with all of `agent-instances/`) |
| `agent-entrypoint.sh` | only for the bundled-services shape |

The whole point of the profile is that the agent's `check:` must be red exactly
when the target repo's CI gate would be red. Everything else follows from that.

## Workflow

Ask the user whenever something below is genuinely ambiguous (use
AskUserQuestion, with a recommended option first). Don't ask about things you
can determine by reading the repository.

### 1. Identify the target

- Parse the URL / `owner/repo`. That is `TARGET_REPO`.
- Propose a directory name `agent-instances/agent-<short-name>` (look at how
  the existing instances, in `agent-instances/` and in
  `../simple-coding-agent-env/`, are named — they use the product name, not always the GitHub repo name, e.g.
  `lbacik/globaldb` → `agent-jsonhub-api`). Confirm it with the user if the
  repo name is not obviously the right short name.
- Refuse to overwrite an existing `agent-instances/agent-*` directory; ask
  instead. Create `agent-instances/` itself if it doesn't exist yet.
- `AGENT_SRC_REF` (which commit of `simple-coding-agent` the image builds
  from) defaults to `main`. If the user names a tag — e.g. "build it against
  tag v1.4.0" — use that as `AGENT_SRC_REF` instead; see step 3. It's not a
  one-time choice: it lands in `.env` as an ordinary setting, so it can be
  changed later (and the image rebuilt) without touching any other file.

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

### 3. Get the agent's source (`AGENT_SRC_REF`)

Generated agents build from
`https://github.com/lbacik/simple-coding-agent.git#<AGENT_SRC_REF>`, not the
local checkout. `AGENT_SRC_REF` defaults to `main`; if the user names a tag
(or branch/commit) of `simple-coding-agent` to pin instead, use that value
verbatim — it goes straight into the git URL fragment, which Docker's git
context resolves like `git checkout <ref>` (works for tags, branches and
commit SHAs alike). Don't ask for one unprompted; only use a non-`main` ref
when the user gave it.

Shallow-clone that same ref into the scratchpad and read, at that commit
(`git clone --depth 1 --branch <AGENT_SRC_REF> ...` — for a bare commit SHA,
clone without `--depth 1` or `--branch` and `git checkout <sha>` instead,
since shallow clones can't fetch an arbitrary commit by SHA):

- `simple_coding_agent/config.py` — the profile's allowed keys in
  `load_repository_profile` (currently
  `setup, check, base_branch, timeout, setup_timeout, env`); an unknown key
  makes the agent refuse the profile. Do **not** copy runtime versions from it:
  the Dockerfile derives them at build time (see "Runtime versions" in step 5).
  To upgrade the agent and its runtime, move upstream or `AGENT_SRC_REF` and
  rebuild. The Dockerfile reads `_DEFAULT_CLAUDE_CODE_VERSION` from `config.py`
  with a `sed` pattern tied to its current `NAME = "x"` formatting; if upstream
  reformats it, the build fails loudly and the pattern needs updating.
- `simple_coding_agent/command_runner.py` — profile commands run with a
  minimal environment: only `PATH` (os.defpath + `PROFILE_EXTRA_PATH`) plus the
  profile's `env:`. No HOME, no shell profile, credentials stripped.
- `Dockerfile`, `scripts/install-skills.sh`, `.env.example` — for anything that
  changed since the templates here were written. If upstream diverged from
  `assets/Dockerfile.template` in a way that matters (new COPY paths, new
  runtime step), follow upstream and tell the user.
- `docker/managed-settings.json` — the template copies it to
  `/etc/claude-code/managed-settings.json` (Meta model pricing; without it
  `total_cost_usd` is ~4x too high). Refs older than upstream PR #143
  (including tags up to v0.2.3) don't have it, and the `COPY` fails the
  build. For such a ref, drop that step and tell the user that USD figures
  use the CLI's default-model rates.

### 4. Analyze the target stack

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

**Runtime versions.** Upstream at `AGENT_SRC_REF` is the single source. No
version numbers are copied into the instance:

- `claude-agent-sdk` is decided only by upstream's `pyproject.toml` (installed
  by `pip install -e .`). Never pin it in the Dockerfile or `.env`; upstream
  pins it exactly, so an instance pin would be overwritten anyway.
- `claude-code` defaults to `_DEFAULT_CLAUDE_CODE_VERSION` in upstream's
  `config.py`, read at build time (not `package.json` / upstream's Dockerfile,
  which can disagree with it).
- Optional `CLAUDE_CODE_BUILD_VERSION` in `.env` picks another claude-code
  version at build time only. The image records the matching expected version
  (`/etc/agent-runtime.env`, sourced by the entrypoint), so editing `.env` without rebuilding cannot
  cause `provenance_verification_failed`. Never put `CLAUDE_CODE_VERSION` or
  `CLAUDE_AGENT_SDK_VERSION` in `.env`; the image's recorded value is the
  source of truth.
- Upgrade: move upstream or change `AGENT_SRC_REF`, then `docker compose build`
  (and recreate the container).

**compose.yaml** — `assets/compose.yaml.template`, image tag
`simple-coding-agent:<short-name>`. Its `agent-src` context URL reads the ref
from `AGENT_SRC_REF` in `.env` (`${AGENT_SRC_REF:-main}`) — nothing to fill in
here; the actual ref is set in `.env.example`/`.env` below. Fill its
`environment:` block as described next.

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

Put the list in the compose file's `environment:`, not in `.env`: the values
aren't secret, and a versioned file keeps them next to their reasons. Comment
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
- Model backend: the template defaults to Meta (`META_API_KEY`, `MODEL_*`
  commented out). If the source instance sets `MODEL_API_KEY` or other
  `MODEL_*` keys (`MODEL_BASE_URL`, `MODEL_AUTH_MODE`, `MODEL_NAME`), copy
  them together with its credential and uncomment the matching template
  lines; never leave one of them present but empty unless meant (an empty
  `MODEL_BASE_URL` selects the Anthropic API, an empty `MODEL_AUTH_MODE`
  fails startup). These keys need `AGENT_SRC_REF` v0.3.2 or later; older
  refs ignore them and require `META_API_KEY`. On a non-Meta backend the
  managed-settings pricing doesn't apply, so `MAX_BUDGET_USD` must be raised
  to the backend's rates — ask the user for the value.
- `TARGET_REPO`, `PROFILE_PATH=/opt/agent-profile/simple-coding-agent-profile.yml`,
  `AGENT_SRC_REF` (from step 3 — `main` unless the user pinned a tag), and an
  empty `CLAUDE_CODE_BUILD_VERSION=` (set only if the user asks for a specific
  claude-code version).
- Ask before adding any other setting the user didn't ask for.
- Alternative configurations (e.g. `.env.claude` for the Anthropic backend):
  only if the user asks. Copy `.env`, change what differs and set
  `AGENT_ENV_FILE=.env.claude` in the copy; leave `AGENT_ENV_FILE` unset in
  `.env`. `--env-file` alone only swaps the interpolation file, while
  compose's `env_file: ${AGENT_ENV_FILE:-.env}` decides what the container
  loads. Every command then takes `--env-file .env.claude`. Without `-p` both
  configurations share one container and the `agent_data` volume.

### 6. Verify the token

A fine-grained PAT only works for repositories it was granted. Check, without
printing the token:

```bash
for p in "" /issues /pulls /contents/; do
  curl -s -o /dev/null -w "$p %{http_code}\n" -H "Authorization: Bearer $GITHUB_TOKEN" \
    "https://api.github.com/repos/<owner>/<repo>$p"
done
```

All 200 → access OK (a fine-grained PAT's permission set applies to every repo
it covers, so write access matches the other agents that use it). Note that the `permissions`
field of `GET /repos` reflects the *user's* rights, not the token's, so it
proves nothing. Any 404 → tell the user to add the repo to the token
(Settings → Developer settings → Fine-grained tokens → Repository access);
contents, pull requests and issues need read & write.

### 7. Validate

- Profile: load it with the agent's own loader from the cloned agent source
  (`python3 -c "from simple_coding_agent.config import load_repository_profile; ..."`
  with that clone on `sys.path`; needs PyYAML).
- `docker compose config -q` in `agent-instances/agent-<name>/`.
- The split-environment check: in the built image, as `agent` in a target
  clone and *without* the profile's `env:`, run the app's config dump or
  boot command (e.g. `php bin/console debug:dotenv`, `manage.py diffsettings`,
  or `env | grep` for a plain env app). Every service URL it prints must point
  at what the image actually runs.
- Offer (don't just do — it takes minutes) to run `docker compose build` and
  then the profile's `setup` + `check` inside the built image against the
  target clone. That's the only real proof the profile is green on a clean
  tree; if the user declines, say clearly that it wasn't run.

### 8. Report

Tell the user in their language: files created, stack decisions and the reasons
for them (runtime version, included/excluded checks, bundled services), which
`simple-coding-agent` ref the image builds from (`main`, or the pinned tag —
and if pinned, that rebuilds won't pick up new agent code until `AGENT_SRC_REF`
in `.env` is bumped or changed back to `main`, then rebuilt — no other file
needs editing), token check result, what was and wasn't validated, and the
start command (`cd agent-instances/agent-<name> && docker compose up --build -d`).
The instance is ignored by Git, so there is nothing to commit there.
