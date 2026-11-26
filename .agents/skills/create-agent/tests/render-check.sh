#!/bin/sh
# render-check.sh -- prove the create-agent templates render to a valid Compose model.
#
# Renders the simple-coding-agent templates (compose.yaml and
# compose.litellm.yaml, .env/.env.example from the env example template, and
# the Dockerfile) and the coding-agent templates (compose.yaml,
# compose.coding-agent.litellm.yaml, Dockerfile, .env/.env.example and
# workflow/workflow.yml) with placeholder values and no
# secrets into scratch directories, then runs `docker compose config` on the
# plain, the LiteLLM, the contract-labels, the contract-labels Pool, the
# coding-agent direct-pin and the coding-agent gateway variants. Exits
# non-zero when a rendered result is not a valid Compose model.
#
# The contract-labels variants render an AGENT_SRC_REF that speaks the
# operator contract (`main` or a release tag v0.9.0 or newer — see the
# create-agent skill, "Contract discovery labels"): the labels blocks the
# template carries are kept instead of deleted. The plain and LiteLLM
# variants render an older ref (before v0.9.0) without labels and must stay
# byte-identical in the Compose model to today's layout.
# The coding-agent direct-pin variant always carries its four discovery
# labels on the worker only and carries no Forge-owned profile (see
# references/coding-agent.md), and its rendered `Dockerfile` derives the
# deployment image FROM the `engine` base (the `deployment` target at
# CODING_AGENT_REF) and runs `config validate`, `prepare-skill-bundle
# --mode install` and `verify-skill-bundle` in that order, with the
# verification after the last relevant COPY. The worker runs the full v3
# `agent run` invocation and bind-mounts nothing at /etc/coding-agent (the
# package is baked into the image, so any edit under `workflow/` needs
# `docker compose build`). Its rendered `workflow/workflow.yml` is a
# `version: 4` file with a `skills:` block whose static `skill:` references
# name declared members only. The coding-agent gateway variant renders the
# same layout with a LiteLLM gateway pin instead of the direct pin: the
# worker's explicit environment names `LITELLM_PROXY_API_KEY` (and no other
# model key), and the `compose.coding-agent.litellm.yaml` overlay attaches
# the worker — and only the worker — to the external network named by
# `GATEWAY_NETWORK`.
#
# The coding-agent variant additionally runs secret-free `agent config
# validate` against the rendered `workflow/workflow.yml` (with the prompt
# files the YAML names, before the policy stub is written — validation passes
# with the policy missing) when the `agent` CLI is on PATH, with no
# environment set. It invokes the bare `agent` CLI directly (no Docker
# needed); the operator path in references/coding-agent.md runs the same
# `config validate` arguments through the compose `agent` seat instead. CI
# has no coding-agent installed — neither an `agent` CLI at a pinned ref
# nor a built image — so there the script records the skip and passes;
# install the CLI at the pinned ref (for example `uv tool
# install git+https://github.com/lbacik/coding-agent@v0.4.7`) or build the
# image and re-run this script locally to cover validation too.
#
# Usage (from anywhere in this repository):
#
#   .agents/skills/create-agent/tests/render-check.sh
#
# The CI workflow (.github/workflows/render-check.yml) runs this same script on
# every pull request. To add an assertion about the rendered Compose model (for
# example "service X carries label Y"), extend the assertions in check_instance,
# check_contract_instance or check_coding_agent_instance below; the workflow
# file needs no changes.
#
# Requires Docker with Compose v2.17 or newer (both templates use
# additional_contexts: the simple-coding-agent template a remote git URL,
# the coding-agent template a `service:` source for the engine base).

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
ROOT_DIR=$(cd "$SCRIPT_DIR/../../../.." && pwd) || exit 1
ASSETS_DIR="$ROOT_DIR/.agents/skills/create-agent/assets"

# Placeholder values. Credentials stay empty on purpose: the check must pass
# with no secret present.
PH_OWNER=testowner
PH_REPO=testrepo
# Short names follow create-agent's `<project>-<suffix>` rule, with the
# suffixes from the backend suffix table in SKILL.md, step 0.
PH_SHORT_NAME="$PH_REPO-sid"
PH_CODING_AGENT_SHORT_NAME="$PH_REPO-rex"
PH_AGENT_SRC_REF=main
PH_MAX_BUDGET_USD=20
PH_MAX_TURNS=120
PH_MAX_BUDGET_TOKENS=4000000
PH_SOFT_THRESHOLD_PERCENTAGE=0.3
PH_NODE_MAJOR=22
PH_GATEWAY_NETWORK=test-gateway-net
# coding-agent adapter placeholders. Prices are the code-owned table's public
# list pricing at the documented ref; limits mirror coding-agent's own
# implement example. The gateway placeholders render the LiteLLM gateway pin
# (the Meta route through the gateway; the operator confirms the prices and
# the two caps, they are never defaulted).
PH_CODING_AGENT_REF=main
PH_BASE_BRANCH=main
PH_SELECTION_LABEL=agent:implement
PH_PROVIDER=anthropic
PH_MODEL=claude-sonnet-5
PH_ENDPOINT=messages
PH_API_KEY_ENV=ANTHROPIC_API_KEY
PH_PRICE_INPUT=2.00
PH_PRICE_OUTPUT=10.00
PH_PRICE_CACHE_READ=0.20
PH_PRICE_CACHE_WRITE=2.50
PH_CONTEXT_WINDOW_TOKENS=1000000
PH_CONTEXT_THRESHOLD_TOKENS=80000
PH_OUTPUT_CAP_TOKENS=32000
PH_GATEWAY_URL=http://litellm:4000
PH_GATEWAY_MODEL=muse-spark-1.3-contributor
PH_GATEWAY_EFFORT=medium
PH_GATEWAY_API_KEY_ENV=LITELLM_PROXY_API_KEY
PH_GATEWAY_CONTEXT_WINDOW_TOKENS=1000000
PH_GATEWAY_OUTPUT_CAP_TOKENS=32000
PH_GATEWAY_CONTEXT_THRESHOLD_TOKENS=300000
PH_GATEWAY_PRICE_INPUT=0.10
PH_GATEWAY_PRICE_OUTPUT=0.20
PH_GATEWAY_PRICE_CACHE_READ=0.002
PH_GATEWAY_PRICE_CACHE_WRITE=0.10
PH_LIMIT_COST_USD=20
PH_LIMIT_EFFECTIVE_TOKENS=4000000
PH_LIMIT_TOOL_CALLS=600
PH_LIMIT_WALL_CLOCK_MINUTES=60
PH_PROCESS_LIMIT_COST_USD=12
PH_SELF_REVIEW_LIMIT_COST_USD=3
# The reserved `ai-handoff` effective-tokens allowance: 150000, raised to one
# maximal Admission hold (Usable Threshold = threshold - 2000, plus the
# output cap) when the pin's threshold needs more. Per variant, because the
# gateway fixture's 300000 threshold needs 330000.
handoff_effective_tokens() {
  floor=$(($1 - 2000 + $2))
  if [ "$floor" -gt 150000 ]; then echo "$floor"; else echo 150000; fi
}
PH_DIRECT_HANDOFF_EFFECTIVE_TOKENS=$(handoff_effective_tokens "$PH_CONTEXT_THRESHOLD_TOKENS" "$PH_OUTPUT_CAP_TOKENS")
PH_GATEWAY_HANDOFF_EFFECTIVE_TOKENS=$(handoff_effective_tokens "$PH_GATEWAY_CONTEXT_THRESHOLD_TOKENS" "$PH_GATEWAY_OUTPUT_CAP_TOKENS")

WORK_ROOT=""

info() {
  printf 'render-check: %s\n' "$*"
}

fail() {
  printf 'render-check: FAIL: %s\n' "$*" >&2
  exit 1
}

# render_compose SRC DST MODE N -- compose.yaml for an N-Worker instance:
# substitute placeholders, then follow SKILL.md the way create-agent would.
#
# MODE is `labels` (the ref speaks the operator contract: keep the discovery
# labels blocks on every managed Worker service) or `no-labels` (an older
# ref: delete them, so the model is unchanged from today's layout).
# `labels` models `main` or a release tag v0.9.0 or newer; `no-labels`
# models a release tag older than v0.9.0.
#
# N is 1 (drop the example agent-<n> stanza with its volume, as SKILL.md
# instructs for N=1) or 2 (instantiate it as agent-2). Both drop the Worker id
# blocks: the fixtures model no shared login (a Pool whose Workers each have
# their own Worker identity needs no Worker id either).
render_compose() {
  src=$1
  dst=$2
  mode=$3
  n=$4
  if [ "$mode" != labels ] && [ "$mode" != no-labels ]; then
    fail "render_compose: unknown mode '$mode' (want labels or no-labels)"
  fi
  if [ "$n" != 1 ] && [ "$n" != 2 ]; then
    fail "render_compose: unknown N '$n' (want 1 or 2)"
  fi
  tmp="$dst.tmp"
  sed -e "s|{{OWNER}}|$PH_OWNER|g" \
    -e "s|{{REPO}}|$PH_REPO|g" \
    -e "s|{{SHORT_NAME}}|$PH_SHORT_NAME|g" \
    -e 's|{{MODEL_SHELL_ENV}}|CI_PLACEHOLDER: "1"|g' \
    "$src" >"$tmp"
  if [ "$n" = 2 ]; then
    sed 's|<n>|2|g' "$tmp" >"$tmp.2"
    mv "$tmp.2" "$tmp"
  fi
  if [ "$mode" = no-labels ]; then
    sed '/^    # Contract discovery labels/,/agent-operator\.backend: "simple-coding-agent"/d' \
      "$tmp" >"$tmp.2"
    mv "$tmp.2" "$tmp"
  fi
  if [ "$n" = 1 ]; then
    sed -e '/^  # Worker <n>:/,/^volumes:$/ { /^volumes:$/!d; }' \
      -e '/^    environment:$/,/^      GIT_COMMITTER_NAME:/d' \
      -e '/^  # One per further Worker: data_2\.\.N\.$/d' \
      -e '/^  data_<n>:$/d' "$tmp" >"$dst"
  else
    sed -e '/^    environment:$/,/^      GIT_COMMITTER_NAME:/d' "$tmp" >"$dst"
  fi
  rm -f "$tmp"
}

# render_compose_litellm SRC DST -- compose.litellm.yaml for N=1: copy the
# template minus the example agent-<n> stanza. The template carries no
# placeholders.
render_compose_litellm() {
  sed -e '/^  # Worker <n>:/,/^      - gateway$/d' "$1" >"$2"
}

# render_env SRC DST -- .env/.env.example from the env example template.
render_env() {
  sed -e "s|{{OWNER}}|$PH_OWNER|g" \
    -e "s|{{REPO}}|$PH_REPO|g" \
    -e "s|{{AGENT_SRC_REF}}|$PH_AGENT_SRC_REF|g" \
    -e "s|{{MAX_BUDGET_USD}}|$PH_MAX_BUDGET_USD|g" \
    -e "s|{{MAX_TURNS}}|$PH_MAX_TURNS|g" \
    -e "s|{{MAX_BUDGET_TOKENS}}|$PH_MAX_BUDGET_TOKENS|g" \
    -e "s|{{SOFT_THRESHOLD_PERCENTAGE}}|$PH_SOFT_THRESHOLD_PERCENTAGE|g" \
    "$1" >"$2"
}

# render_dockerfile SRC DST -- substitute {{NODE_MAJOR}} and replace every
# remaining (possibly multi-line) {{...}} template comment with a fixed note.
# `docker compose config` never reads the Dockerfile; it is rendered so the
# scratch instance is complete.
render_dockerfile() {
  sed -e "s|{{NODE_MAJOR}}|$PH_NODE_MAJOR|g" "$1" |
    awk '/\{\{/ && /\}\}/ { print "# render-check: template placeholder replaced."; next }
         /\{\{/ { print "# render-check: template placeholder block replaced."; in_block=1; next }
         in_block && /\}\}/ { in_block=0; next }
         in_block { next }
         { print }' >"$2"
}

assert_contains() {
  if ! printf '%s\n' "$1" | grep -qF -- "$2"; then
    fail "$3"
  fi
}

assert_not_contains() {
  if printf '%s\n' "$1" | grep -qF -- "$2"; then
    fail "$3"
  fi
}

assert_line_matches() {
  if ! printf '%s\n' "$1" | grep -Eq -- "$2"; then
    fail "$3"
  fi
}

assert_not_line_matches() {
  if printf '%s\n' "$1" | grep -Eq -- "$2"; then
    fail "$3"
  fi
}

# assert_no_placeholders DIR LABEL -- no {{...}} may survive rendering, and no
# <n> worker may survive in a Compose file.
assert_no_placeholders() {
  if grep -rF '{{' "$1" >/dev/null 2>&1; then
    fail "$2: rendered files still contain a {{PLACEHOLDER}}"
  fi
  for compose_file in "$1/compose.yaml" "$1/compose.litellm.yaml"; do
    if [ -f "$compose_file" ] && grep -qF '<n>' "$compose_file"; then
      fail "$2: $compose_file still contains an unrendered <n> worker"
    fi
  done
}

# assert_no_secrets ENV_FILE LABEL -- credential keys stay empty or absent.
assert_no_secrets() {
  for key in GITHUB_TOKEN META_API_KEY MODEL_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY LITELLM_PROXY_API_KEY; do
    value=$(grep -E "^${key}=" "$1" | cut -d '=' -f 2-)
    if [ -n "$value" ]; then
      fail "$2: $1 sets $key (the check runs with no secrets)"
    fi
  done
}

# service_block CONFIG SERVICE -- print the `docker compose config` model
# lines of one service: from its `  <service>:` line to the next service or
# top-level key. Used to assert per-service wiring (explicit environment,
# networks) that a whole-model grep cannot attribute.
service_block() {
  printf '%s\n' "$1" | awk -v svc="$2" '
    $0 == "  " svc ":" { show = 1; next }
    /^  [A-Za-z0-9_.-]+:/ { show = 0 }
    /^[A-Za-z0-9_.-]+:/ { show = 0 }
    show { print }'
}

# compose_config DIR -- print `docker compose config` for the rendered
# directory. Runs hermetically: shell variables take precedence over the
# fixture's .env in Compose interpolation, so an exported COMPOSE_FILE,
# GATEWAY_NETWORK or credential from the caller's shell would rewire the
# fixture and could leak a real secret into the check. `config` is
# client-side and needs no daemon, so PATH and HOME suffice. Any further
# arguments are global Compose flags placed before `config` (for example
# `--profile '*'`, to include services kept out of the default model by a
# profile).
compose_config() {
  (cd "$1" && shift && env -i PATH="$PATH" HOME="$HOME" docker compose "$@" config)
}

# compose_services DIR [FLAGS...] -- print `docker compose config --services`
# for the rendered directory, as hermetically as compose_config and with the
# same optional global flags: the services a bare `docker compose up`
# considers when no profile is enabled.
compose_services() {
  (cd "$1" && shift && env -i PATH="$PATH" HOME="$HOME" docker compose "$@" config --services)
}

# check_model_shape CONFIG LABEL -- assertions shared by the plain and the
# contract-labels Compose models: image tag, agent service, init, the first
# Worker's volume, no unrendered workers, and no Worker id (the fixtures
# model no shared login).
check_model_shape() {
  assert_contains "$1" "simple-coding-agent:$PH_SHORT_NAME" \
    "$2: image tag missing from the Compose model"
  assert_contains "$1" '  agent:' \
    "$2: agent service missing from the Compose model"
  assert_contains "$1" 'init: true' \
    "$2: init missing from the Compose model"
  assert_contains "$1" 'agent_data' \
    "$2: agent_data volume missing from the Compose model"
  assert_not_contains "$1" '<n>' \
    "$2: unrendered <n> worker reached the Compose model"
  assert_not_contains "$1" 'WORKER_ID' \
    "$2: fixture without a shared login must not set a Worker id"
}

# check_instance DIR LABEL -- `docker compose config` must accept the rendered
# directory, and the resulting model must carry the expected shape. This
# covers the no-labels shape (a ref that does not speak the operator
# contract): no service may carry a label at all, so any labels block added
# to the template without updating this check fails loudly.
#
# Add new model assertions here (for example "service X carries label Y");
# the CI workflow needs no changes.
check_instance() {
  info "checking $2 instance"
  if ! config_output=$(compose_config "$1"); then
    fail "$2: 'docker compose config' failed"
  fi
  check_model_shape "$config_output" "$2"
  assert_not_contains "$config_output" 'labels:' \
    "$2: service carries a Compose label but the ref does not speak the contract"
  assert_not_contains "$config_output" 'agent-operator' \
    "$2: service carries a contract discovery label but the ref does not speak the contract"
  if [ "$2" = 'litellm' ]; then
    assert_contains "$config_output" "$PH_GATEWAY_NETWORK" \
      "$2: gateway network missing from the Compose model"
    assert_contains "$config_output" 'external: true' \
      "$2: gateway network is not external in the Compose model"
  fi
}

# check_contract_instance DIR LABEL COUNT NAME... -- `docker compose config`
# must accept the rendered directory, and every managed Worker service must
# carry the four contract discovery labels: contract major 1, an instance
# name matching ^[a-z0-9][a-z0-9-]{0,62}$, a non-root exec user and the
# simple-coding-agent backend. COUNT is the number of managed Worker services;
# NAME... are their expected instance names (one per service).
#
# Add new label assertions here; the CI workflow needs no changes.
check_contract_instance() {
  dir=$1
  label=$2
  count=$3
  info "checking $label instance"
  if ! config_output=$(compose_config "$dir"); then
    fail "$label: 'docker compose config' failed"
  fi
  check_model_shape "$config_output" "$label"
  for key in contract instance exec-user backend; do
    key_count=$(printf '%s\n' "$config_output" | grep -cF -- "io.github.lbacik.agent-operator.$key" || true)
    if [ "$key_count" -ne "$count" ]; then
      fail "$label: discovery label '$key' on $key_count services, want $count (every managed Worker service)"
    fi
  done
  assert_line_matches "$config_output" \
    "io\\.github\\.lbacik\\.agent-operator\\.contract: (\"1\"|1)\$" \
    "$label: contract label is not major 1"
  assert_contains "$config_output" 'io.github.lbacik.agent-operator.exec-user: agent' \
    "$label: exec-user label is not agent"
  assert_not_contains "$config_output" 'agent-operator.exec-user: root' \
    "$label: exec-user label must not be root"
  assert_contains "$config_output" 'io.github.lbacik.agent-operator.backend: simple-coding-agent' \
    "$label: backend label is not simple-coding-agent"
  instances=$(printf '%s\n' "$config_output" | sed -n 's/.*io\.github\.lbacik\.agent-operator\.instance: *//p')
  if printf '%s\n' "$instances" | grep -Eqv '^[a-z0-9][a-z0-9-]{0,62}$'; then
    fail "$label: an instance label does not match ^[a-z0-9][a-z0-9-]{0,62}$"
  fi
  shift 3
  if [ "$#" -eq 2 ]; then
    assert_contains "$config_output" '  agent-2:' \
      "$label: agent-2 service missing from the Compose model"
    assert_contains "$config_output" 'data_2' \
      "$label: data_2 volume missing from the Compose model"
  fi
  for expected_name in "$@"; do
    assert_line_matches "$config_output" \
      "io\\.github\\.lbacik\\.agent-operator\\.instance: ${expected_name}\$" \
      "$label: instance '$expected_name' missing from the Compose model"
  done
}

# check_coding_agent_instance DIR LABEL VARIANT -- `docker compose config`
# must accept the rendered coding-agent directory, and the resulting model
# must carry the adapter's shape: the build-only `engine` base plus three
# derived services sharing one state volume and one derived image, a default
# model (no profile) of `engine` (`scale: 0`) and `worker` only so that a
# bare `docker compose up` starts the Worker alone, all four
# discovery labels on the worker and on no one-off service, the worker's
# hardening (never restarted, init, read-only root filesystem, the full v3
# `run` invocation with no bind mount at /etc/coding-agent), the exact stop
# grace on the rendered file, and the Compose project name equal to the
# instance directory name. The rendered Workflow Configuration must name
# credentials by environment variable only and carry a Selection Label that
# satisfies coding-agent's rules. The rendered Dockerfile must derive FROM
# the engine base and run `config validate`, `prepare-skill-bundle` and
# `verify-skill-bundle` in that order, with the verification after the last
# relevant COPY. VARIANT is `direct` (a provider pin: no gateway-only keys
# anywhere, no LITELLM key on the worker) or `gateway` (a LiteLLM gateway
# pin: a `gateway:` block and no `provider:` key, the LITELLM key in the
# worker's explicit environment only, and the overlay attaching the worker
# — and only the worker — to GATEWAY_NETWORK).
#
# Add new model assertions here; the CI workflow needs no changes.
check_coding_agent_instance() {
  dir=$1
  label=$2
  variant=$3
  if [ "$variant" != direct ] && [ "$variant" != gateway ]; then
    fail "check_coding_agent_instance: unknown VARIANT '$variant' (want direct or gateway)"
  fi
  instance_dir_name=$(basename "$dir")
  info "checking $label instance"
  # The full model: `agent` and `validate` sit in the `tools` profile, so
  # every per-service assertion below reads the model with all profiles
  # enabled. Without it their blocks would be empty and the "key absent
  # from this seat" checks would pass vacuously.
  if ! config_output=$(compose_config "$dir" --profile '*'); then
    fail "$label: 'docker compose --profile * config' failed"
  fi
  # A bare `docker compose up -d` must start the Worker alone. `engine` must
  # stay in the default model, because a profile left inactive would drop it
  # and break the `service:engine` build context; `scale: 0` keeps it out of
  # `up` instead. The one-off seats are kept out by the `tools` profile.
  if ! default_services=$(compose_services "$dir"); then
    fail "$label: 'docker compose config --services' failed"
  fi
  default_services=$(printf '%s\n' "$default_services" | sort | tr '\n' ' ')
  if [ "$default_services" != "engine worker " ]; then
    fail "$label: default services are '$default_services', want 'engine worker ' (agent and validate belong in the tools profile)"
  fi
  assert_contains "$(service_block "$config_output" engine)" 'scale: 0' \
    "$label: engine lacks scale: 0, so a bare 'docker compose up' would start it"
  assert_not_contains "$(service_block "$config_output" engine)" 'profiles:' \
    "$label: engine must not take a profile (it would break the service:engine build context)"
  for seat in agent validate; do
    assert_contains "$(service_block "$config_output" "$seat")" '- tools' \
      "$label: $seat seat is not in the tools profile"
  done
  assert_not_contains "$(service_block "$config_output" worker)" 'profiles:' \
    "$label: worker must not take a profile (a bare 'docker compose up' starts it)"
  # The Compose project is the directory name: the template sets no `name:`.
  assert_contains "$config_output" "name: $instance_dir_name" \
    "$label: Compose project name is not the instance directory name"
  for service in worker agent validate engine; do
    assert_contains "$config_output" "  $service:" \
      "$label: $service service missing from the Compose model"
  done
  # All three runtime seats share the derived image; the engine base carries
  # its own tag and is never run. Count service-level keys only (four-space
  # indent): the model also keeps the top-level `x-agent` extension with its
  # own copy of the image.
  derived_image_count=$(printf '%s\n' "$config_output" | grep -cx -- "    image: coding-agent:$PH_CODING_AGENT_SHORT_NAME" || true)
  if [ "$derived_image_count" != 3 ]; then
    fail "$label: want the derived image on all three runtime seats (agent, validate, worker), found $derived_image_count"
  fi
  assert_contains "$config_output" "image: coding-agent-engine:$PH_CODING_AGENT_SHORT_NAME" \
    "$label: engine base image tag missing from the Compose model"
  assert_contains "$config_output" '/var/lib/coding-agent' \
    "$label: state path missing from the Compose model"
  # The Workflow Configuration is baked into the derived image, never
  # bind-mounted: no volume entry may target /etc/coding-agent on any
  # service, and the rendered file must not reference ./workflow or
  # WORKFLOW_CONFIG_DIR at all.
  assert_not_contains "$config_output" 'target: /etc/coding-agent' \
    "$label: /etc/coding-agent is bind-mounted (the package is baked into the image)"
  assert_not_contains "$(cat "$dir/compose.yaml")" './workflow' \
    "$label: compose.yaml still references the ./workflow bind mount"
  assert_not_contains "$(cat "$dir/compose.yaml")" 'WORKFLOW_CONFIG_DIR' \
    "$label: compose.yaml still references WORKFLOW_CONFIG_DIR (the package is baked into the image)"
  # The worker's full v3 `run` invocation: every flag and value upstream
  # renders, and none of the removed legacy options (v3 exits 2 on them).
  for token in '--config' '/etc/coding-agent/workflow.yml' '--workflow' \
    '--policy' '/etc/coding-agent/skill-policy.json' \
    '--bundle-dir' '/opt/coding-agent/skill-bundle' \
    '--skill-home' '/home/agent' \
    '--state-dir' '/var/lib/coding-agent' \
    '--toolchain-matrix' '/opt/coding-agent/toolchain-matrix.json'; do
    assert_contains "$config_output" "$token" \
      "$label: worker command misses '$token'"
  done
  assert_not_contains "$config_output" '--skills-home' \
    "$label: worker command carries the removed --skills-home option (v3 exits 2)"
  assert_not_contains "$config_output" '--skill-bundle-dir' \
    "$label: worker command carries the removed --skill-bundle-dir option (v3 exits 2)"
  # WORKFLOW still selects the Workflow id through interpolation, so the
  # rendered file keeps the defaulted reference.
  # shellcheck disable=SC2016 # the literal, unexpanded reference is the point
  assert_contains "$(cat "$dir/compose.yaml")" '${WORKFLOW:-implement}' \
    "$label: compose.yaml lost the WORKFLOW interpolation"
  assert_contains "$config_output" '/var/lib/coding-agent/operator:uid=1000,gid=1000,mode=0700' \
    "$label: private-IPC tmpfs missing its ownership and mode options in the Compose model"
  operator_tmpfs_count=$(printf '%s\n' "$config_output" | grep -cF -- '/var/lib/coding-agent/operator' || true)
  if [ "$operator_tmpfs_count" != 1 ]; then
    fail "$label: want exactly one operator tmpfs entry (worker only), found $operator_tmpfs_count"
  fi
  assert_contains "$config_output" 'stop_grace_period:' \
    "$label: stop_grace_period missing from the Compose model"
  # All four discovery labels appear exactly once in the whole model: on the
  # worker, never on a one-off seat.
  for key in contract instance exec-user backend; do
    key_count=$(printf '%s\n' "$config_output" | grep -cF -- "io.github.lbacik.agent-operator.$key" || true)
    if [ "$key_count" != 1 ]; then
      fail "$label: discovery label '$key' on $key_count services, want 1 (worker only)"
    fi
  done
  assert_line_matches "$config_output" \
    "io\\.github\\.lbacik\\.agent-operator\\.contract: (\"1\"|1)\$" \
    "$label: contract label is not major 1"
  assert_contains "$config_output" 'io.github.lbacik.agent-operator.instance: '"$PH_CODING_AGENT_SHORT_NAME" \
    "$label: instance label is not $PH_CODING_AGENT_SHORT_NAME"
  assert_contains "$config_output" 'io.github.lbacik.agent-operator.exec-user: agent' \
    "$label: exec-user label is not agent"
  assert_not_contains "$config_output" 'agent-operator.exec-user: root' \
    "$label: exec-user label must not be root"
  assert_contains "$config_output" 'io.github.lbacik.agent-operator.backend: coding-agent' \
    "$label: backend label is not coding-agent"
  # Hardening: exactly one restart line (the worker, never restarted), one
  # init (the worker), and a read-only root filesystem on every runtime
  # seat. The build-only `engine` service sets none of these.
  restart_count=$(printf '%s\n' "$config_output" | grep -c -- 'restart:' || true)
  if [ "$restart_count" != 1 ]; then
    fail "$label: want exactly one restart: line (worker), found $restart_count"
  fi
  assert_line_matches "$config_output" \
    "restart: ['\"]?no['\"]?\$" \
    "$label: worker is not restart: no"
  init_count=$(printf '%s\n' "$config_output" | grep -c -- 'init: true' || true)
  if [ "$init_count" != 1 ]; then
    fail "$label: want exactly one init: true line (worker), found $init_count"
  fi
  read_only_count=$(printf '%s\n' "$config_output" | grep -c -- '^    read_only: true$' || true)
  if [ "$read_only_count" != 3 ]; then
    fail "$label: want read_only: true on all three runtime seats, found $read_only_count"
  fi
  # Resource limits (Forge addition, not upstream's compose): the x-agent
  # anchor carries cpus / mem_limit / pids_limit, so all three services
  # inherit them. Compose normalises mem_limit to bytes (3g -> 3221225472),
  # so assert the normalised form, not the literal `3g`.
  # Count service-level keys only (four-space indent): the model also keeps
  # the top-level `x-agent` extension, unnormalised, with its own copies.
  for limit_key in 'cpus:' 'mem_limit:' 'pids_limit:'; do
    limit_count=$(printf '%s\n' "$config_output" | grep -c -- "^    $limit_key" || true)
    if [ "$limit_count" != 3 ]; then
      fail "$label: want $limit_key on all three services, found $limit_count"
    fi
  done
  assert_line_matches "$config_output" \
    "cpus: ['\"]?1\\.5['\"]?\$" \
    "$label: cpus default 1.5 missing from the Compose model"
  assert_contains "$config_output" '3221225472' \
    "$label: mem_limit default of 3 GiB missing from the Compose model"
  assert_line_matches "$config_output" \
    "pids_limit: ['\"]?1024['\"]?\$" \
    "$label: pids_limit default 1024 missing from the Compose model"
  # Overrides in the environment change the rendered values.
  if ! override_output=$(cd "$dir" && env -i PATH="$PATH" HOME="$HOME" WORKER_CPUS=2 WORKER_MEM_LIMIT=4g WORKER_PIDS_LIMIT=2048 docker compose config); then
    fail "$label: 'docker compose config' with WORKER_* overrides failed"
  fi
  assert_line_matches "$override_output" \
    "cpus: ['\"]?2(\\.0)?['\"]?\$" \
    "$label: WORKER_CPUS override did not change the Compose model"
  assert_contains "$override_output" '4294967296' \
    "$label: WORKER_MEM_LIMIT override did not change the Compose model"
  assert_line_matches "$override_output" \
    "pids_limit: ['\"]?2048['\"]?\$" \
    "$label: WORKER_PIDS_LIMIT override did not change the Compose model"
  assert_not_contains "$override_output" '3221225472' \
    "$label: WORKER_MEM_LIMIT override left the default in the Compose model"
  # The rendered file (not the model: durations may normalise) keeps the
  # grace above the Workflow Configuration's shutdown grace.
  if ! grep -qF -- 'stop_grace_period: 60s' "$dir/compose.yaml"; then
    fail "$label: compose.yaml lost stop_grace_period: 60s"
  fi
  # The rendered Workflow Configuration: a version: 4 file with a Skill
  # Bundle, repository, branch, credentials by environment-variable name
  # only, a lawful Selection Label, the full Attempt Ceiling and Step
  # Allowances that fit the Work Pool. Every static `skill:` reference must
  # name a declared bundle member.
  workflow_content=$(cat "$dir/workflow/workflow.yml")
  assert_contains "$workflow_content" 'version: 4' \
    "$label: workflow.yml is not a version: 4 file"
  assert_line_matches "$workflow_content" '^version: 4$' \
    "$label: workflow.yml version line is not exactly 'version: 4'"
  assert_contains "$workflow_content" 'workflow-v4.schema.json' \
    "$label: workflow.yml editor schema is not workflow-v4"
  assert_contains "$workflow_content" 'skills:' \
    "$label: workflow.yml declares no Skill Bundle"
  assert_contains "$workflow_content" 'git+https://github.com/mattpocock/skills.git' \
    "$label: workflow.yml Skill Bundle is not the reference selection"
  assert_contains "$workflow_content" '3cca18b368ae95cdbdebbff572ccafa662551015' \
    "$label: workflow.yml Skill Bundle ref is not the reference pin"
  assert_contains "$workflow_content" 'include: [implement, tdd, code-review, codebase-design]' \
    "$label: workflow.yml Skill Bundle membership is not the reference selection"
  assert_contains "$workflow_content" 'skill: implement' \
    "$label: workflow.yml process step names no skill"
  assert_contains "$workflow_content" 'skill: code-review' \
    "$label: workflow.yml self-review step names no skill"
  skill_names=$(printf '%s\n' "$workflow_content" |
    sed -n 's/^[[:space:]]*-[[:space:]]*skill:[[:space:]]*\([a-z-]*\).*/\1/p' |
    sort -u)
  include_list=$(printf '%s\n' "$workflow_content" |
    sed -n 's/^[[:space:]]*include: \[\(.*\)\].*/\1/p' | tr ',[]' '   ')
  for skill_name in $skill_names; do
    case " $include_list " in
      *" $skill_name "*) ;;
      *) fail "$label: skill '$skill_name' is not declared in the skills include list" ;;
    esac
  done
  assert_contains "$workflow_content" "repository: $PH_OWNER/$PH_REPO" \
    "$label: workflow.yml target repository is not $PH_OWNER/$PH_REPO"
  assert_contains "$workflow_content" "base-branch: $PH_BASE_BRANCH" \
    "$label: workflow.yml base branch is not $PH_BASE_BRANCH"
  assert_contains "$workflow_content" 'token-env: GITHUB_TOKEN' \
    "$label: workflow.yml token-env does not name an environment variable"
  if [ "$variant" = direct ]; then
    assert_contains "$workflow_content" "api-key-env: $PH_API_KEY_ENV" \
      "$label: workflow.yml api-key-env does not name an environment variable"
  fi
  # The model pin: exactly one variant. A direct pin is a `provider:` block
  # with no `gateway:` key; a gateway pin is a `gateway:` block with no
  # `provider:` key. Both declare the three token keys (version 4). The anchored patterns tell pin keys apart from the
  # template's prose comments about the other variant.
  if [ "$variant" = direct ]; then
    assert_line_matches "$workflow_content" \
      "^    provider: $PH_PROVIDER\$" \
      "$label: workflow.yml direct pin is not a provider pin"
    assert_not_line_matches "$workflow_content" \
      '^    gateway:' \
      "$label: workflow.yml direct pin carries a gateway block"
    assert_line_matches "$workflow_content" \
      "^    context-window-tokens: $PH_CONTEXT_WINDOW_TOKENS\$" \
      "$label: workflow.yml direct pin misses context-window-tokens"
    assert_line_matches "$workflow_content" \
      "^    context-threshold-tokens: $PH_CONTEXT_THRESHOLD_TOKENS\$" \
      "$label: workflow.yml direct pin misses context-threshold-tokens"
    assert_line_matches "$workflow_content" \
      "^    output-cap-tokens: $PH_OUTPUT_CAP_TOKENS\$" \
      "$label: workflow.yml direct pin misses output-cap-tokens"
    handoff_tokens=$PH_DIRECT_HANDOFF_EFFECTIVE_TOKENS
    assert_not_line_matches "$(cat "$dir/compose.yaml")" \
      '^      LITELLM_PROXY_API_KEY:' \
      "$label: compose.yaml sets LITELLM_PROXY_API_KEY on a direct pin"
    assert_not_contains "$config_output" 'LITELLM_PROXY_API_KEY' \
      "$label: Compose model carries LITELLM_PROXY_API_KEY on a direct pin"
    for seat in agent validate; do
      for key in ANTHROPIC_API_KEY OPENAI_API_KEY; do
        assert_not_contains "$(service_block "$config_output" "$seat")" "$key" \
          "$label: $key reached the $seat seat's environment"
      done
    done
    assert_contains "$(service_block "$config_output" worker)" "$PH_API_KEY_ENV" \
      "$label: $PH_API_KEY_ENV missing from the worker's environment"
    if [ -e "$dir/compose.coding-agent.litellm.yaml" ]; then
      fail "$label: gateway overlay rendered for a direct pin"
    fi
    if grep -qE '^LITELLM_PROXY_API_KEY=' "$dir/.env"; then
      fail "$label: .env sets LITELLM_PROXY_API_KEY on a direct pin"
    fi
  else
    assert_contains "$workflow_content" \
      "gateway: {kind: litellm, url: $PH_GATEWAY_URL}" \
      "$label: workflow.yml gateway pin is not a litellm gateway block"
    assert_contains "$workflow_content" "model: $PH_GATEWAY_MODEL" \
      "$label: workflow.yml gateway pin model is not the gateway L1 alias"
    assert_contains "$workflow_content" 'endpoint: responses' \
      "$label: workflow.yml gateway pin endpoint is not responses"
    assert_contains "$workflow_content" "api-key-env: $PH_GATEWAY_API_KEY_ENV" \
      "$label: workflow.yml gateway pin api-key-env is not $PH_GATEWAY_API_KEY_ENV"
    assert_line_matches "$workflow_content" \
      "^    context-window-tokens: $PH_GATEWAY_CONTEXT_WINDOW_TOKENS\$" \
      "$label: workflow.yml gateway pin misses context-window-tokens"
    handoff_tokens=$PH_GATEWAY_HANDOFF_EFFECTIVE_TOKENS
    assert_contains "$workflow_content" \
      "output-cap-tokens: $PH_GATEWAY_OUTPUT_CAP_TOKENS" \
      "$label: workflow.yml gateway pin misses output-cap-tokens"
    assert_contains "$workflow_content" \
      "context-threshold-tokens: $PH_GATEWAY_CONTEXT_THRESHOLD_TOKENS" \
      "$label: workflow.yml gateway pin misses context-threshold-tokens"
    assert_not_line_matches "$workflow_content" \
      '^    provider:' \
      "$label: workflow.yml gateway pin carries a provider key"
    # The gateway key reaches the worker's environment only (the template
    # sets no env_file, which would copy .env into every seat). Whole-model
    # greps cannot attribute it, so check per service. The empty fixture
    # value keeps the check secret-free while proving the wiring is live.
    worker_block=$(service_block "$config_output" worker)
    agent_block=$(service_block "$config_output" agent)
    validate_block=$(service_block "$config_output" validate)
    assert_contains "$worker_block" 'LITELLM_PROXY_API_KEY' \
      "$label: LITELLM_PROXY_API_KEY missing from the worker's environment"
    assert_not_contains "$agent_block" 'LITELLM_PROXY_API_KEY' \
      "$label: LITELLM_PROXY_API_KEY reached the agent seat's environment"
    assert_not_contains "$validate_block" 'LITELLM_PROXY_API_KEY' \
      "$label: LITELLM_PROXY_API_KEY reached the validate seat's environment"
    assert_not_contains "$worker_block" 'ANTHROPIC_API_KEY' \
      "$label: direct-pin key ANTHROPIC_API_KEY left on the gateway worker"
    assert_not_contains "$worker_block" 'OPENAI_API_KEY' \
      "$label: direct-pin key OPENAI_API_KEY left on the gateway worker"
    assert_line_matches "$(cat "$dir/compose.yaml")" \
      '^      LITELLM_PROXY_API_KEY: ' \
      "$label: compose.yaml misses the worker LITELLM_PROXY_API_KEY line"
    assert_contains "$(cat "$dir/.env")" \
      'COMPOSE_FILE=compose.yaml:compose.coding-agent.litellm.yaml' \
      "$label: .env does not load the gateway overlay"
    assert_contains "$(cat "$dir/.env")" \
      "GATEWAY_NETWORK=$PH_GATEWAY_NETWORK" \
      "$label: .env does not name the gateway network"
    if [ ! -f "$dir/compose.coding-agent.litellm.yaml" ]; then
      fail "$label: gateway overlay compose.coding-agent.litellm.yaml missing"
    fi
    # The overlay attaches the worker — and only the worker — to the
    # external network named by GATEWAY_NETWORK.
    assert_contains "$config_output" "$PH_GATEWAY_NETWORK" \
      "$label: gateway network missing from the Compose model"
    assert_contains "$config_output" 'external: true' \
      "$label: gateway network is not external in the Compose model"
    # Match the service's `networks:` entry, not a bare word: the fixture's
    # build context path itself contains "gateway".
    assert_line_matches "$worker_block" '^      gateway:' \
      "$label: worker is not attached to the gateway network"
    assert_not_line_matches "$agent_block" '^      gateway:' \
      "$label: agent seat joined the gateway network"
    assert_not_line_matches "$validate_block" '^      gateway:' \
      "$label: validate seat joined the gateway network"
  fi
  assert_contains "$workflow_content" "label: $PH_SELECTION_LABEL" \
    "$label: workflow.yml Selection Label is not $PH_SELECTION_LABEL"
  assert_not_contains "$workflow_content" 'label: ready-for-human' \
    "$label: workflow.yml Selection Label breaks coding-agent's rules"
  assert_not_contains "$workflow_content" 'label: wontfix' \
    "$label: workflow.yml Selection Label breaks coding-agent's rules"
  assert_not_contains "$workflow_content" 'wayfinder' \
    "$label: workflow.yml Selection Label breaks coding-agent's rules"
  assert_contains "$workflow_content" "cost-usd: $PH_LIMIT_COST_USD" \
    "$label: workflow.yml Attempt Ceiling cost is incomplete"
  assert_contains "$workflow_content" "effective-tokens: $PH_LIMIT_EFFECTIVE_TOKENS" \
    "$label: workflow.yml Attempt Ceiling effective-tokens are incomplete"
  # Version 4 renamed the token meter: a `tokens` limit is refused as an
  # unknown key, in a block or a flow mapping.
  assert_not_line_matches "$workflow_content" '^ *tokens:' \
    "$label: workflow.yml still names the version 3 tokens meter"
  assert_not_line_matches "$workflow_content" '[{,] *tokens:' \
    "$label: workflow.yml still names the version 3 tokens meter"
  assert_contains "$workflow_content" "effective-tokens: $handoff_tokens, tool-calls: 30" \
    "$label: workflow.yml ai-handoff reserve is not $handoff_tokens effective-tokens"
  assert_contains "$workflow_content" "tool-calls: $PH_LIMIT_TOOL_CALLS" \
    "$label: workflow.yml Attempt Ceiling tool-calls are incomplete"
  assert_contains "$workflow_content" "wall-clock-minutes: $PH_LIMIT_WALL_CLOCK_MINUTES" \
    "$label: workflow.yml Attempt Ceiling wall-clock is incomplete"
  assert_contains "$workflow_content" "cost-usd: $PH_PROCESS_LIMIT_COST_USD" \
    "$label: workflow.yml process Step Allowance missing"
  assert_contains "$workflow_content" "cost-usd: $PH_SELF_REVIEW_LIMIT_COST_USD" \
    "$label: workflow.yml self-review Step Allowance missing"
  # The fixture's Step Allowances fit the Work Pool on the cost meter: the
  # Attempt Ceiling minus the 1 USD `ai-handoff` reserve leaves room for both.
  # This mirrors the skill's fit check (a 5 USD ceiling with the default 12
  # USD `process` allowance must never render). The cost meter is the whole
  # check here: the rendered steps set `limits` only on `cost-usd`, so it is
  # the only meter an allowance sets.
  if [ "$((PH_LIMIT_COST_USD - 1))" -lt "$PH_PROCESS_LIMIT_COST_USD" ]; then
    fail "$label: process allowance $PH_PROCESS_LIMIT_COST_USD does not fit the $((PH_LIMIT_COST_USD - 1)) USD Work Pool"
  fi
  if [ "$((PH_LIMIT_COST_USD - 1))" -lt "$PH_SELF_REVIEW_LIMIT_COST_USD" ]; then
    fail "$label: self-review allowance $PH_SELF_REVIEW_LIMIT_COST_USD does not fit the $((PH_LIMIT_COST_USD - 1)) USD Work Pool"
  fi
  assert_not_contains "$workflow_content" 'sk-' \
    "$label: workflow.yml names a secret value, not an environment variable"
  env_content=$(cat "$dir/.env")
  assert_contains "$env_content" "TARGET_REPO=$PH_OWNER/$PH_REPO" \
    "$label: .env TARGET_REPO is not $PH_OWNER/$PH_REPO"
  assert_contains "$env_content" "CODING_AGENT_REF=$PH_CODING_AGENT_REF" \
    "$label: .env CODING_AGENT_REF is not $PH_CODING_AGENT_REF"
  example_content=$(cat "$dir/.env.example")
  for worker_var in 'WORKER_CPUS=1.5' 'WORKER_MEM_LIMIT=3g' 'WORKER_PIDS_LIMIT=1024'; do
    assert_contains "$example_content" "# $worker_var" \
      "$label: .env.example misses commented-out $worker_var"
  done
  for prompt in implement-policy.md handoff.md; do
    if [ ! -f "$dir/workflow/prompts/$prompt" ]; then
      fail "$label: workflow/prompts/$prompt missing"
    fi
  done
  if [ ! -f "$dir/workflow/skill-policy.json" ]; then
    fail "$label: workflow/skill-policy.json missing (the skill copies it verbatim from the CODING_AGENT_REF checkout)"
  fi
  # The derived deployment image: the Dockerfile is copied verbatim from
  # the asset (no placeholders), derives FROM the engine base, and runs the
  # Agent Forge sequence — `config validate`, then `prepare-skill-bundle
  # --mode install`, then `verify-skill-bundle` against the final roots —
  # as the runtime user with no secrets. The verification must come after
  # the last relevant COPY so the build fails on any mismatch.
  if [ ! -f "$dir/Dockerfile" ]; then
    fail "$label: Dockerfile missing (the derived deployment image)"
  fi
  dockerfile_content=$(cat "$dir/Dockerfile")
  assert_contains "$dockerfile_content" 'FROM engine' \
    "$label: Dockerfile does not derive from the engine base"
  validate_line=$(printf '%s\n' "$dockerfile_content" | grep -nF 'agent config validate' | cut -d: -f1 | head -n 1)
  prepare_line=$(printf '%s\n' "$dockerfile_content" | grep -nF 'agent prepare-skill-bundle' | cut -d: -f1 | head -n 1)
  verify_line=$(printf '%s\n' "$dockerfile_content" | grep -nF 'agent verify-skill-bundle' | cut -d: -f1 | head -n 1)
  last_copy_line=$(printf '%s\n' "$dockerfile_content" | grep -n '^COPY ' | cut -d: -f1 | tail -n 1)
  if [ -z "$validate_line" ] || [ -z "$prepare_line" ] || [ -z "$verify_line" ]; then
    fail "$label: Dockerfile misses a step of the prepare sequence (config validate, prepare-skill-bundle, verify-skill-bundle)"
  fi
  if [ "$validate_line" -ge "$prepare_line" ] || [ "$prepare_line" -ge "$verify_line" ]; then
    fail "$label: Dockerfile runs the prepare sequence out of order (want config validate, then prepare-skill-bundle, then verify-skill-bundle)"
  fi
  if [ -z "$last_copy_line" ] || [ "$verify_line" -le "$last_copy_line" ]; then
    fail "$label: Dockerfile verifies before the last COPY (verification must run against the final roots)"
  fi
  assert_contains "$dockerfile_content" '--mode install' \
    "$label: Dockerfile does not prepare with --mode install"
  assert_no_forge_profile "$dir" "$label"
}

# assert_no_agent_operator FILE MESSAGE -- Forge never bakes discovery labels
# into the image: neither the Dockerfile template nor a rendered Dockerfile
# may mention agent-operator (discovery labels are Compose labels:, never an
# image LABEL). The legacy role image LABEL belongs to simple-coding-agent's
# own discovery and stays untouched (asserted on the template in main).
assert_no_agent_operator() {
  if grep -qF 'agent-operator' "$1"; then
    fail "$2"
  fi
}

# assert_no_forge_profile DIR LABEL -- a coding-agent instance carries no
# Forge-owned profile: no simple-coding-agent-profile.yml, and no
# PROFILE_PATH / AGENT_SRC_REF / WORKER_ID in the rendered .env or
# compose.yaml (the repository-owned Project Profile is the only profile).
# It does carry a Dockerfile: the derived deployment image (checked in
# check_coding_agent_instance), not a Forge-owned profile.
assert_no_forge_profile() {
  if [ -e "$1/simple-coding-agent-profile.yml" ]; then
    fail "$2: coding-agent instance must not contain a Forge-owned profile"
  fi
  if grep -qF 'PROFILE_PATH' "$1/.env"; then
    fail "$2: .env sets PROFILE_PATH (no Forge-owned profile on this backend)"
  fi
  if grep -qF 'AGENT_SRC_REF' "$1/.env"; then
    fail "$2: .env sets AGENT_SRC_REF (this backend names its ref CODING_AGENT_REF)"
  fi
  if grep -qF 'WORKER_ID' "$1/compose.yaml"; then
    fail "$2: compose.yaml sets WORKER_ID (this backend runs one Worker, never a Pool)"
  fi
}

# render_instance DIR MODE N -- one scratch instance: compose.yaml in the given
# MODE (`labels` when the ref speaks the operator contract, `no-labels`
# otherwise) for N Workers, plus .env/.env.example and the Dockerfile.
# Callers: plain is no-labels 1 (today's layout); contract is labels 1 (one
# managed Worker service); contract-pool is labels 2 (both Worker services
# labelled, the second Worker's instance name is its Worker id).
render_instance() {
  render_compose "$ASSETS_DIR/compose.yaml.template" "$1/compose.yaml" \
    "$2" "$3"
  render_env "$ASSETS_DIR/env.example.template" "$1/.env.example"
  cp "$1/.env.example" "$1/.env"
  render_dockerfile "$ASSETS_DIR/Dockerfile.template" "$1/Dockerfile"
}

render_litellm() {
  render_instance "$1" no-labels 1
  render_compose_litellm "$ASSETS_DIR/compose.litellm.yaml.template" \
    "$1/compose.litellm.yaml"
  cat >>"$1/.env" <<EOF
COMPOSE_FILE=compose.yaml:compose.litellm.yaml
GATEWAY_NETWORK=$PH_GATEWAY_NETWORK
MODEL_BASE_URL=http://litellm:4000
MODEL_AUTH_MODE=auth_token
MODEL_API_KEY=
MODEL_NAME=muse-spark-1.3-contributor
EOF
}

# render_coding_agent_compose SRC DST VARIANT -- the coding-agent compose.yaml:
# owner, repo and short name to substitute (the engine ref lives in .env as
# CODING_AGENT_REF, read through ${...} interpolation like AGENT_SRC_REF).
# VARIANT is `direct` (a provider pin: the worker keeps the ANTHROPIC/OPENAI
# keys, the gateway key is dropped) or `gateway` (a LiteLLM gateway pin: the
# worker keeps only LITELLM_PROXY_API_KEY).
render_coding_agent_compose() {
  if [ "$3" != direct ] && [ "$3" != gateway ]; then
    fail "render_coding_agent_compose: unknown VARIANT '$3' (want direct or gateway)"
  fi
  tmp="$2.tmp"
  sed -e "s|{{OWNER}}|$PH_OWNER|g" \
    -e "s|{{REPO}}|$PH_REPO|g" \
    -e "s|{{SHORT_NAME}}|$PH_CODING_AGENT_SHORT_NAME|g" "$1" >"$tmp"
  if [ "$3" = direct ]; then
    sed -e '/^      # gateway-model-key-begin$/,/^      # gateway-model-key-end$/d' \
      -e '/^      # direct-model-key-begin$/d' \
      -e '/^      # direct-model-key-end$/d' "$tmp" >"$2"
  else
    sed -e '/^      # direct-model-key-begin$/,/^      # direct-model-key-end$/d' \
      -e '/^      # gateway-model-key-begin$/d' \
      -e '/^      # gateway-model-key-end$/d' \
      -e 's|^      # LITELLM_PROXY_API_KEY:|      LITELLM_PROXY_API_KEY:|' \
      "$tmp" >"$2"
  fi
  rm -f "$tmp"
}

# render_coding_agent_env SRC DST VARIANT -- .env/.env.example from the
# coding-agent env example template. VARIANT is `direct` or `gateway`, as
# above: only the model key the Workflow Configuration names stays active,
# the others stay commented out, and the gateway variant additionally enables
# the gateway network overlay (COMPOSE_FILE plus GATEWAY_NETWORK).
render_coding_agent_env() {
  if [ "$3" != direct ] && [ "$3" != gateway ]; then
    fail "render_coding_agent_env: unknown VARIANT '$3' (want direct or gateway)"
  fi
  tmp="$2.tmp"
  sed -e "s|{{OWNER}}|$PH_OWNER|g" \
    -e "s|{{REPO}}|$PH_REPO|g" \
    -e "s|{{CODING_AGENT_REF}}|$PH_CODING_AGENT_REF|g" \
    "$1" >"$tmp"
  if [ "$3" = direct ]; then
    cp "$tmp" "$2"
  else
    sed -e 's|^ANTHROPIC_API_KEY=$|# ANTHROPIC_API_KEY=|' \
      -e 's|^# LITELLM_PROXY_API_KEY=$|LITELLM_PROXY_API_KEY=|' \
      -e 's|^# COMPOSE_FILE=compose.yaml:compose.coding-agent.litellm.yaml$|COMPOSE_FILE=compose.yaml:compose.coding-agent.litellm.yaml|' \
      -e "s|^# GATEWAY_NETWORK=$|GATEWAY_NETWORK=$PH_GATEWAY_NETWORK|" \
      "$tmp" >"$2"
  fi
  rm -f "$tmp"
}

# render_coding_agent_overlay SRC DST -- compose.coding-agent.litellm.yaml
# (gateway variant only): the template carries no placeholders, so copy it
# verbatim, mirroring render_compose_litellm for the simple-coding-agent
# overlay.
render_coding_agent_overlay() {
  cp "$1" "$2"
}

# render_coding_agent_workflow SRC DST VARIANT -- workflow/workflow.yml from
# the coding-agent Workflow Configuration template. VARIANT is `direct` (a
# provider pin: substitute the direct placeholders and drop the gateway-pin
# block) or `gateway` (a LiteLLM gateway pin: drop the direct-pin block,
# uncomment the gateway-pin block and substitute its placeholders).
render_coding_agent_workflow() {
  if [ "$3" != direct ] && [ "$3" != gateway ]; then
    fail "render_coding_agent_workflow: unknown VARIANT '$3' (want direct or gateway)"
  fi
  if [ "$3" = direct ]; then
    handoff=$PH_DIRECT_HANDOFF_EFFECTIVE_TOKENS
  else
    handoff=$PH_GATEWAY_HANDOFF_EFFECTIVE_TOKENS
  fi
  tmp="$2.tmp"
  sed -e "s|{{OWNER}}|$PH_OWNER|g" \
    -e "s|{{REPO}}|$PH_REPO|g" \
    -e "s|{{BASE_BRANCH}}|$PH_BASE_BRANCH|g" \
    -e "s|{{SELECTION_LABEL}}|$PH_SELECTION_LABEL|g" \
    -e "s|{{PROVIDER}}|$PH_PROVIDER|g" \
    -e "s|{{MODEL}}|$PH_MODEL|g" \
    -e "s|{{ENDPOINT}}|$PH_ENDPOINT|g" \
    -e "s|{{API_KEY_ENV}}|$PH_API_KEY_ENV|g" \
    -e "s|{{PRICE_INPUT}}|$PH_PRICE_INPUT|g" \
    -e "s|{{PRICE_OUTPUT}}|$PH_PRICE_OUTPUT|g" \
    -e "s|{{PRICE_CACHE_READ}}|$PH_PRICE_CACHE_READ|g" \
    -e "s|{{PRICE_CACHE_WRITE}}|$PH_PRICE_CACHE_WRITE|g" \
    -e "s|{{CONTEXT_WINDOW_TOKENS}}|$PH_CONTEXT_WINDOW_TOKENS|g" \
    -e "s|{{CONTEXT_THRESHOLD_TOKENS}}|$PH_CONTEXT_THRESHOLD_TOKENS|g" \
    -e "s|{{OUTPUT_CAP_TOKENS}}|$PH_OUTPUT_CAP_TOKENS|g" \
    -e "s|{{GATEWAY_URL}}|$PH_GATEWAY_URL|g" \
    -e "s|{{GATEWAY_MODEL}}|$PH_GATEWAY_MODEL|g" \
    -e "s|{{GATEWAY_EFFORT}}|$PH_GATEWAY_EFFORT|g" \
    -e "s|{{GATEWAY_API_KEY_ENV}}|$PH_GATEWAY_API_KEY_ENV|g" \
    -e "s|{{GATEWAY_CONTEXT_WINDOW_TOKENS}}|$PH_GATEWAY_CONTEXT_WINDOW_TOKENS|g" \
    -e "s|{{GATEWAY_OUTPUT_CAP_TOKENS}}|$PH_GATEWAY_OUTPUT_CAP_TOKENS|g" \
    -e "s|{{GATEWAY_CONTEXT_THRESHOLD_TOKENS}}|$PH_GATEWAY_CONTEXT_THRESHOLD_TOKENS|g" \
    -e "s|{{GATEWAY_PRICE_INPUT}}|$PH_GATEWAY_PRICE_INPUT|g" \
    -e "s|{{GATEWAY_PRICE_OUTPUT}}|$PH_GATEWAY_PRICE_OUTPUT|g" \
    -e "s|{{GATEWAY_PRICE_CACHE_READ}}|$PH_GATEWAY_PRICE_CACHE_READ|g" \
    -e "s|{{GATEWAY_PRICE_CACHE_WRITE}}|$PH_GATEWAY_PRICE_CACHE_WRITE|g" \
    -e "s|{{LIMIT_COST_USD}}|$PH_LIMIT_COST_USD|g" \
    -e "s|{{LIMIT_EFFECTIVE_TOKENS}}|$PH_LIMIT_EFFECTIVE_TOKENS|g" \
    -e "s|{{HANDOFF_EFFECTIVE_TOKENS}}|$handoff|g" \
    -e "s|{{LIMIT_TOOL_CALLS}}|$PH_LIMIT_TOOL_CALLS|g" \
    -e "s|{{LIMIT_WALL_CLOCK_MINUTES}}|$PH_LIMIT_WALL_CLOCK_MINUTES|g" \
    -e "s|{{PROCESS_LIMIT_COST_USD}}|$PH_PROCESS_LIMIT_COST_USD|g" \
    -e "s|{{SELF_REVIEW_LIMIT_COST_USD}}|$PH_SELF_REVIEW_LIMIT_COST_USD|g" \
    "$1" >"$tmp"
  if [ "$3" = direct ]; then
    sed -e '/^    # gateway-pin-begin$/,/^    # gateway-pin-end$/d' \
      "$tmp" >"$2"
  else
    sed -e '/^    # direct-pin-begin$/,/^    # direct-pin-end$/d' \
      -e '/^    # gateway-pin-begin$/,/^    # gateway-pin-end$/s/^    # /    /' \
      -e '/^    gateway-pin-begin$/d' \
      -e '/^    gateway-pin-end$/d' \
      "$tmp" >"$2"
  fi
  rm -f "$tmp"
}

# render_coding_agent_dockerfile SRC DST -- the coding-agent instance
# Dockerfile: copied verbatim from the asset (it carries no placeholders;
# every path and flag is fixed by the adapter).
render_coding_agent_dockerfile() {
  cp "$1" "$2" ||
    fail 'coding-agent: cannot copy the instance Dockerfile'
}

# render_coding_agent_prompts DIR -- stub prompt files with the names the
# rendered workflow.yml references. The skill copies the real contents from
# the CODING_AGENT_REF checkout (step 3b); the check only proves the layout
# the validation stats exists.
render_coding_agent_prompts() {
  mkdir -p "$1/workflow/prompts" ||
    fail 'coding-agent: cannot create workflow/prompts directory'
  for prompt in implement-policy.md handoff.md; do
    printf '# render-check: prompt stub for %s.\n' "$prompt" \
      >"$1/workflow/prompts/$prompt"
  done
}

# render_coding_agent_policy DIR -- stub skill-policy.json. The skill copies
# the real reviewed policy verbatim from the CODING_AGENT_REF checkout's
# docker/deployment/ (step 3b of the skill); Forge keeps no copy of its own,
# so the check only proves the layout the Worker expects exists. The stub is
# written after the config-validate run below: validation passes with the
# policy missing, and a stub must never stand in for the reviewed copy.
render_coding_agent_policy() {
  printf '{}\n' >"$1/workflow/skill-policy.json" ||
    fail 'coding-agent: cannot write workflow/skill-policy.json stub'
}

# check_coding_agent_validate DIR LABEL -- secret-free `agent config validate`
# against the rendered coding-agent workflow, with no environment set. Runs
# only when the `agent` CLI is on PATH: CI has no coding-agent installed, so
# there the check records the skip and passes (see the header). Install the
# CLI at the pinned ref or build the image and re-run locally to cover it.
check_coding_agent_validate() {
  if ! agent_bin=$(command -v agent); then
    info "$2: SKIP secret-free config validate (no agent CLI on PATH; CI has no coding-agent installed)"
    return 0
  fi
  info "checking $2 secret-free config validate"
  (cd "$1" && env -i "$agent_bin" config validate \
    --config ./workflow/workflow.yml --workflow implement) ||
    fail "$2: secret-free 'agent config validate' failed"
}

# render_coding_agent DIR VARIANT -- one scratch coding-agent instance:
# compose.yaml (plus the gateway network overlay on the gateway variant),
# Dockerfile, .env/.env.example, workflow/workflow.yml, stub prompt files
# and the policy stub (written after the secret-free validate run, which
# needs no policy). VARIANT is `direct` or `gateway` (see
# render_coding_agent_workflow).
render_coding_agent() {
  if [ "$2" != direct ] && [ "$2" != gateway ]; then
    fail "render_coding_agent: unknown VARIANT '$2' (want direct or gateway)"
  fi
  render_coding_agent_compose \
    "$ASSETS_DIR/compose.coding-agent.yaml.template" "$1/compose.yaml" "$2"
  render_coding_agent_dockerfile \
    "$ASSETS_DIR/Dockerfile.coding-agent.template" "$1/Dockerfile"
  render_coding_agent_env "$ASSETS_DIR/env.coding-agent.example.template" \
    "$1/.env.example" "$2"
  cp "$1/.env.example" "$1/.env"
  if [ "$2" = gateway ]; then
    render_coding_agent_overlay \
      "$ASSETS_DIR/compose.coding-agent.litellm.yaml.template" \
      "$1/compose.coding-agent.litellm.yaml"
  fi
  mkdir -p "$1/workflow" ||
    fail 'coding-agent: cannot create workflow directory'
  render_coding_agent_workflow \
    "$ASSETS_DIR/workflow.coding-agent.yml.template" "$1/workflow/workflow.yml" "$2"
  render_coding_agent_prompts "$1"
  check_coding_agent_validate "$1" "coding-agent $2"
  render_coding_agent_policy "$1"
}

main() {
  command -v docker >/dev/null 2>&1 ||
    fail 'docker not found (needs Docker with Compose v2.17 or newer)'
  docker compose version >/dev/null 2>&1 ||
    fail "'docker compose' is not available (needs Compose v2.17 or newer)"

  WORK_ROOT=$(mktemp -d) || fail 'cannot create a scratch directory'
  trap 'rm -rf "$WORK_ROOT"' EXIT INT TERM

  plain_dir="$WORK_ROOT/plain"
  litellm_dir="$WORK_ROOT/litellm"
  contract_dir="$WORK_ROOT/contract"
  contract_pool_dir="$WORK_ROOT/contract-pool"
  coding_agent_dir="$WORK_ROOT/agent-$PH_CODING_AGENT_SHORT_NAME"
  coding_agent_gateway_dir="$WORK_ROOT/agent-gateway-$PH_CODING_AGENT_SHORT_NAME"
  mkdir -p "$plain_dir" "$litellm_dir" "$contract_dir" \
    "$contract_pool_dir" "$coding_agent_dir" "$coding_agent_gateway_dir" ||
    fail 'cannot create scratch instance directories'

  info 'rendering plain instance'
  render_instance "$plain_dir" no-labels 1
  info 'rendering litellm instance'
  render_litellm "$litellm_dir"
  info 'rendering contract-labels instance'
  render_instance "$contract_dir" labels 1
  info 'rendering contract-labels Pool instance'
  render_instance "$contract_pool_dir" labels 2
  info 'rendering coding-agent direct-pin instance'
  render_coding_agent "$coding_agent_dir" direct
  info 'rendering coding-agent gateway instance'
  render_coding_agent "$coding_agent_gateway_dir" gateway

  # Forge never bakes discovery labels into the image; the legacy role image
  # label belongs to simple-coding-agent's own discovery and stays.
  assert_no_agent_operator "$ASSETS_DIR/Dockerfile.template" \
    'Dockerfile template mentions agent-operator'
  if ! grep -qF 'LABEL io.github.lbacik.simple-coding-agent.role="agent"' \
    "$ASSETS_DIR/Dockerfile.template"; then
    fail 'Dockerfile template lost the legacy role image label'
  fi

  # The coding-agent template fixes no project name (the directory is the
  # project) and renders no Pool: an <n> worker must never appear in it.
  if grep -qE '^name:' "$ASSETS_DIR/compose.coding-agent.yaml.template"; then
    fail 'compose.coding-agent.yaml.template sets a project name (the directory is the project)'
  fi
  if grep -qF '<n>' "$ASSETS_DIR/compose.coding-agent.yaml.template"; then
    fail 'compose.coding-agent.yaml.template renders a Pool (this backend runs one Worker)'
  fi
  if grep -qF 'PROFILE_PATH' "$ASSETS_DIR/env.coding-agent.example.template"; then
    fail 'env.coding-agent.example.template sets PROFILE_PATH (no Forge-owned profile on this backend)'
  fi
  if grep -qF 'AGENT_SRC_REF' "$ASSETS_DIR/env.coding-agent.example.template"; then
    fail 'env.coding-agent.example.template sets AGENT_SRC_REF (this backend names its ref CODING_AGENT_REF)'
  fi
  # Budgets stay in the Workflow Configuration (the Effective Configuration
  # digest is the only budget authority): no budget, turn, timeout or retry
  # key may appear in the coding-agent env template.
  for budget_pattern in 'MAX_' 'BUDGET' 'TIMEOUT' 'TURN' 'RETRY'; do
    if grep -qF -- "$budget_pattern" "$ASSETS_DIR/env.coding-agent.example.template"; then
      fail "env.coding-agent.example.template sets $budget_pattern (budgets stay in the Workflow Configuration)"
    fi
  done
  # The coding-agent gateway overlay attaches only the worker (the one-off
  # `agent` seat is not a Managed Instance) and fixes no project name; the
  # gateway network name always comes from .env, never hard-coded.
  if grep -qE '^name:' "$ASSETS_DIR/compose.coding-agent.litellm.yaml.template"; then
    fail 'compose.coding-agent.litellm.yaml.template sets a project name (the directory is the project)'
  fi
  if grep -qE '^  agent:' "$ASSETS_DIR/compose.coding-agent.litellm.yaml.template"; then
    fail 'compose.coding-agent.litellm.yaml.template attaches the agent seat (only the worker joins the gateway network)'
  fi
  if grep -qE '^  validate:' "$ASSETS_DIR/compose.coding-agent.litellm.yaml.template"; then
    fail 'compose.coding-agent.litellm.yaml.template attaches the validate seat (only the worker joins the gateway network)'
  fi
  if ! grep -qE '^  worker:' "$ASSETS_DIR/compose.coding-agent.litellm.yaml.template"; then
    fail 'compose.coding-agent.litellm.yaml.template misses the worker service'
  fi
  if ! grep -qF 'GATEWAY_NETWORK' "$ASSETS_DIR/compose.coding-agent.litellm.yaml.template"; then
    fail 'compose.coding-agent.litellm.yaml.template misses GATEWAY_NETWORK (the gateway network comes from .env)'
  fi
  for worker_var in 'WORKER_CPUS:-1.5' 'WORKER_MEM_LIMIT:-3g' 'WORKER_PIDS_LIMIT:-1024'; do
    if ! grep -qF -- "$worker_var" "$ASSETS_DIR/compose.coding-agent.yaml.template"; then
      fail "compose.coding-agent.yaml.template misses resource limit default \${$worker_var}"
    fi
  done
  for worker_default in 'WORKER_CPUS=1.5' 'WORKER_MEM_LIMIT=3g' 'WORKER_PIDS_LIMIT=1024'; do
    if ! grep -qF -- "# $worker_default" "$ASSETS_DIR/env.coding-agent.example.template"; then
      fail "env.coding-agent.example.template misses commented-out $worker_default"
    fi
  done
  # The Workflow Configuration is baked into the derived image, never
  # mounted: no template may reference the old bind mount or its variable.
  for template in "$ASSETS_DIR/compose.coding-agent.yaml.template" \
    "$ASSETS_DIR/env.coding-agent.example.template"; do
    if grep -qF 'WORKFLOW_CONFIG_DIR' "$template"; then
      fail "$(basename "$template") references WORKFLOW_CONFIG_DIR (the package is baked into the image)"
    fi
  done
  if grep -qF './workflow' "$ASSETS_DIR/compose.coding-agent.yaml.template"; then
    fail 'compose.coding-agent.yaml.template bind-mounts ./workflow (the package is baked into the image)'
  fi
  # v3 removed the legacy fixed-bundle options: the worker command must
  # carry neither (the CLI exits 2 on them).
  for legacy in '--skills-home' '--skill-bundle-dir'; do
    if grep -qF -- "$legacy" "$ASSETS_DIR/compose.coding-agent.yaml.template"; then
      fail "compose.coding-agent.yaml.template carries the removed $legacy option (v3 exits 2)"
    fi
  done
  # Build arrangement: the engine base builds the deployment target from
  # the git context, and the derived services build FROM it through a
  # `service:` additional context.
  if ! grep -qF 'target: deployment' "$ASSETS_DIR/compose.coding-agent.yaml.template"; then
    fail 'compose.coding-agent.yaml.template builds no deployment target (the engine base is missing)'
  fi
  if ! grep -qF 'service:engine' "$ASSETS_DIR/compose.coding-agent.yaml.template"; then
    fail 'compose.coding-agent.yaml.template wires no service:engine build context (the derived image has no base)'
  fi
  if ! grep -qF 'dockerfile: Dockerfile' "$ASSETS_DIR/compose.coding-agent.yaml.template"; then
    fail 'compose.coding-agent.yaml.template does not build the instance Dockerfile'
  fi
  # Forge never bakes discovery labels into the image; the derived
  # Dockerfile is no exception (the one-off seats share the worker image).
  assert_no_agent_operator "$ASSETS_DIR/Dockerfile.coding-agent.template" \
    'Dockerfile.coding-agent template mentions agent-operator'

  # The workflow template carries no hard-coded Work Pool numbers: the old
  # comment quoted the pool for the example ceiling only.
  for stale in '19 USD' '3,850,000' '570 tool calls' '55 minutes'; do
    if grep -qF -- "$stale" "$ASSETS_DIR/workflow.coding-agent.yml.template"; then
      fail "workflow.coding-agent.yml.template hard-codes a Work Pool number ($stale)"
    fi
  done

  assert_no_placeholders "$plain_dir" 'plain'
  assert_no_placeholders "$litellm_dir" 'litellm'
  assert_no_placeholders "$contract_dir" 'contract'
  assert_no_placeholders "$contract_pool_dir" 'contract-pool'
  assert_no_placeholders "$coding_agent_dir" 'coding-agent'
  assert_no_placeholders "$coding_agent_gateway_dir" 'coding-agent gateway'
  assert_no_secrets "$plain_dir/.env" 'plain'
  assert_no_secrets "$plain_dir/.env.example" 'plain'
  assert_no_secrets "$litellm_dir/.env" 'litellm'
  assert_no_secrets "$litellm_dir/.env.example" 'litellm'
  assert_no_secrets "$contract_dir/.env" 'contract'
  assert_no_secrets "$contract_dir/.env.example" 'contract'
  assert_no_secrets "$contract_pool_dir/.env" 'contract-pool'
  assert_no_secrets "$contract_pool_dir/.env.example" 'contract-pool'
  assert_no_secrets "$coding_agent_dir/.env" 'coding-agent'
  assert_no_secrets "$coding_agent_dir/.env.example" 'coding-agent'
  assert_no_secrets "$coding_agent_gateway_dir/.env" 'coding-agent gateway'
  assert_no_secrets "$coding_agent_gateway_dir/.env.example" 'coding-agent gateway'
  assert_no_agent_operator "$plain_dir/Dockerfile" \
    'plain: Dockerfile mentions agent-operator'
  assert_no_agent_operator "$contract_dir/Dockerfile" \
    'contract: Dockerfile mentions agent-operator'
  assert_no_agent_operator "$contract_pool_dir/Dockerfile" \
    'contract-pool: Dockerfile mentions agent-operator'

  check_instance "$plain_dir" 'plain'
  check_instance "$litellm_dir" 'litellm'
  check_contract_instance "$contract_dir" 'contract' 1 "$PH_SHORT_NAME"
  check_contract_instance "$contract_pool_dir" 'contract-pool' 2 \
    "$PH_SHORT_NAME" "$PH_SHORT_NAME-2"
  check_coding_agent_instance "$coding_agent_dir" 'coding-agent' direct
  check_coding_agent_instance "$coding_agent_gateway_dir" 'coding-agent gateway' gateway

  info 'PASS: all variants render to a valid Compose model with no secrets'
}

main
