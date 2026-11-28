#!/bin/sh
# render-check.sh -- prove the create-agent templates render to a valid Compose model.
#
# Renders the simple-coding-agent templates (compose.yaml and
# compose.litellm.yaml, .env/.env.example from the env example template, and
# the Dockerfile) and the coding-agent templates (compose.yaml,
# compose.coding-agent.litellm.yaml, Dockerfile, .env/.env.example,
# workflow/workflow.yml and the triage prompts) with placeholder values and
# no secrets into scratch directories, then runs `docker compose config` on
# the plain, the LiteLLM, the contract-labels, the contract-labels Pool, the
# coding-agent direct-pin, the coding-agent gateway, the coding-agent
# `triage`, the coding-agent two-Workflow Pool and the coding-agent
# Instance-supplied profile variants. Exits non-zero when a rendered result
# is not a valid Compose model.
#
# The contract-labels variants render an AGENT_SRC_REF that speaks the
# operator contract (`main` or a release tag v0.9.0 or newer — see the
# create-agent skill, "Contract discovery labels"): the labels blocks the
# template carries are kept instead of deleted. The plain and LiteLLM
# variants render an older ref (before v0.9.0) without labels and must stay
# byte-identical in the Compose model to today's layout.
# The coding-agent direct-pin variant always carries its four discovery
# labels on the worker only and carries no Project Profile of its own (it
# reads the repository's; see references/coding-agent.md), and its
# rendered `Dockerfile` derives the
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
# `GATEWAY_NETWORK`. The coding-agent `triage` variant declares the
# `triage` Workflow alone (a triage pin and an Advisor pin, both through
# the gateway), and the two-Workflow Pool variant declares `implement` and
# `triage` with one Worker each (`worker` on a direct pin, `worker-2` through
# the gateway, each with its own state volume, Managed Instance name and
# model keys). The Instance-supplied profile variant declares `implement`
# on a direct pin with option (b) of the skill's target checkout checks:
# its workflow.yml carries `target.profile: project-profile.yml`, its
# `workflow/project-profile.yml` is a schema-2 Project Profile, and its
# Dockerfile bakes that file before `config validate`. Only that variant
# keeps the `instance-profile-*` ranges; every variant removes a stale
# /etc/coding-agent/project-profile.yml from the base image and drops the
# range markers. See check_coding_agent_instance and
# check_coding_agent_profile for the shape each must have.
#
# Every coding-agent variant additionally runs secret-free `agent config
# validate` against the rendered `workflow/workflow.yml`, once per declared
# Workflow (with the prompt files the YAML names, before the policy stub is
# written — validation passes with the policy missing) when the `agent` CLI
# is on PATH, with no environment set. It invokes the bare `agent` CLI directly (no Docker
# needed); the operator path in references/coding-agent.md runs the same
# `config validate` arguments through the compose `agent` seat instead. CI
# has no coding-agent installed — neither an `agent` CLI at a pinned ref
# nor a built image — so there the script records the skip and passes;
# install the CLI at the pinned ref (for example `uv tool
# install git+https://github.com/lbacik/coding-agent@v0.5.1`; the `triage`
# variants and the profile notice checks need v0.5.1 or newer) or build the
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
PH_GATEWAY_EFFORT=high
PH_GATEWAY_API_KEY_ENV=LITELLM_PROXY_API_KEY
PH_GATEWAY_CONTEXT_WINDOW_TOKENS=1000000
PH_GATEWAY_OUTPUT_CAP_TOKENS=32000
PH_GATEWAY_CONTEXT_THRESHOLD_TOKENS=300000
PH_GATEWAY_PRICE_INPUT=0.10
PH_GATEWAY_PRICE_OUTPUT=0.20
PH_GATEWAY_PRICE_CACHE_READ=0.002
PH_GATEWAY_PRICE_CACHE_WRITE=0.10
# The triage Advisor pin: a stronger model behind the same gateway (the
# maintainer proxy). Its prices and caps are the operator's, never defaulted.
PH_ADVISOR_MODEL=claude-opus-5-5
PH_ADVISOR_CONTEXT_WINDOW_TOKENS=1000000
PH_ADVISOR_CONTEXT_THRESHOLD_TOKENS=150000
PH_ADVISOR_OUTPUT_CAP_TOKENS=32000
PH_ADVISOR_PRICE_INPUT=5.00
PH_ADVISOR_PRICE_OUTPUT=25.00
PH_ADVISOR_PRICE_CACHE_READ=0.50
PH_ADVISOR_PRICE_CACHE_WRITE=6.25
PH_LIMIT_COST_USD=20
PH_LIMIT_EFFECTIVE_TOKENS=4000000
PH_LIMIT_TOOL_CALLS=600
PH_LIMIT_WALL_CLOCK_MINUTES=60
PH_PROCESS_LIMIT_COST_USD=12
PH_SELF_REVIEW_LIMIT_COST_USD=3
# The `triage` Attempt Ceiling (no Reserved Step, so the Work Pool is the
# whole ceiling). Each limit holds one maximal Admission hold for the
# triage pin and for the Advisor pin.
PH_TRIAGE_LIMIT_COST_USD=10
PH_TRIAGE_LIMIT_EFFECTIVE_TOKENS=3000000
PH_TRIAGE_LIMIT_TOOL_CALLS=300
PH_TRIAGE_LIMIT_WALL_CLOCK_MINUTES=45
# The reserved `ai-handoff` effective-tokens allowance: 150000, raised to one
# maximal Admission hold (Usable Threshold = threshold - 2000, plus the
# output cap) when the pin's threshold needs more. Per variant, because the
# gateway fixture's 300000 threshold needs 330000.
handoff_effective_tokens() {
  floor=$(($1 - 2000 + $2))
  if [ "$floor" -gt 150000 ]; then echo "$floor"; else echo 150000; fi
}

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

# ca_variant VARIANT -- set the facts of one coding-agent fixture variant:
# which Workflows workflow.yml declares (CA_WORKFLOWS), which Workflow each
# Worker runs (CA_W1 for `worker`, CA_W2 for `worker-2`, empty for a single
# Worker), and which model profile each declared pin uses (CA_MAIN for the
# `implement` pin `main`, CA_TRIAGE and CA_ADVISOR for the `triage` pin and
# its Advisor pin; empty when the pin is not rendered). See profile_value.
#
#   direct   `implement` alone on a direct pin, one Worker
#   gateway  `implement` alone on a LiteLLM gateway pin, one Worker
#   triage   `triage` alone, triage and Advisor pins through the gateway,
#            one Worker
#   pool     both Workflows: `worker` runs `implement` on a direct pin,
#            `worker-2` runs `triage` through the gateway, so the two
#            Workers use different routes and different model keys
#   profile  `implement` alone on a direct pin, one Worker, with an
#            Instance-supplied Project Profile (CA_PROFILE=1: option (b) of
#            the skill's target checkout checks)
#
# CA_PROFILE is 1 only for the `profile` variant; every other variant reads
# the Target Repository's profile (or, `triage` alone, needs none).
ca_variant() {
  CA_MAIN=''
  CA_TRIAGE=''
  CA_ADVISOR=''
  CA_W2=''
  CA_PROFILE=0
  case "$1" in
    direct)
      CA_WORKFLOWS=implement
      CA_W1=implement
      CA_MAIN=sonnet
      ;;
    gateway)
      CA_WORKFLOWS=implement
      CA_W1=implement
      CA_MAIN=muse
      ;;
    triage)
      CA_WORKFLOWS=triage
      CA_W1=triage
      CA_TRIAGE=muse
      CA_ADVISOR=opus
      ;;
    pool)
      CA_WORKFLOWS='implement triage'
      CA_W1=implement
      CA_W2=triage
      CA_MAIN=sonnet
      CA_TRIAGE=muse
      CA_ADVISOR=opus
      ;;
    profile)
      CA_WORKFLOWS=implement
      CA_W1=implement
      CA_MAIN=sonnet
      CA_PROFILE=1
      ;;
    *) fail "ca_variant: unknown VARIANT '$1' (want direct, gateway, triage, pool or profile)" ;;
  esac
}

# profile_value PROFILE FIELD -- one fixture value of a model profile.
# `sonnet` is a direct Anthropic pin (the code-owned table's public list
# pricing and the upstream token recommendation), `muse` the Meta route
# through the LiteLLM gateway, `opus` a stronger model behind the same
# gateway (the triage Advisor). FIELD is the pin placeholder suffix
# (ROUTE, MODEL, ENDPOINT, EFFORT, API_KEY_ENV, CONTEXT_WINDOW_TOKENS,
# CONTEXT_THRESHOLD_TOKENS, OUTPUT_CAP_TOKENS, PRICE_INPUT, PRICE_OUTPUT,
# PRICE_CACHE_READ, PRICE_CACHE_WRITE) or KIND (`direct` or `gateway`).
profile_value() {
  case "$1:$2" in
    sonnet:KIND) echo direct ;;
    sonnet:ROUTE) echo "provider: $PH_PROVIDER" ;;
    sonnet:MODEL) echo "$PH_MODEL" ;;
    sonnet:ENDPOINT) echo "$PH_ENDPOINT" ;;
    sonnet:EFFORT) echo medium ;;
    sonnet:API_KEY_ENV) echo "$PH_API_KEY_ENV" ;;
    sonnet:CONTEXT_WINDOW_TOKENS) echo "$PH_CONTEXT_WINDOW_TOKENS" ;;
    sonnet:CONTEXT_THRESHOLD_TOKENS) echo "$PH_CONTEXT_THRESHOLD_TOKENS" ;;
    sonnet:OUTPUT_CAP_TOKENS) echo "$PH_OUTPUT_CAP_TOKENS" ;;
    sonnet:PRICE_INPUT) echo "$PH_PRICE_INPUT" ;;
    sonnet:PRICE_OUTPUT) echo "$PH_PRICE_OUTPUT" ;;
    sonnet:PRICE_CACHE_READ) echo "$PH_PRICE_CACHE_READ" ;;
    sonnet:PRICE_CACHE_WRITE) echo "$PH_PRICE_CACHE_WRITE" ;;
    muse:KIND) echo gateway ;;
    muse:ROUTE) echo "gateway: {kind: litellm, url: $PH_GATEWAY_URL}" ;;
    muse:MODEL) echo "$PH_GATEWAY_MODEL" ;;
    muse:ENDPOINT) echo responses ;;
    muse:EFFORT) echo "$PH_GATEWAY_EFFORT" ;;
    muse:API_KEY_ENV) echo "$PH_GATEWAY_API_KEY_ENV" ;;
    muse:CONTEXT_WINDOW_TOKENS) echo "$PH_GATEWAY_CONTEXT_WINDOW_TOKENS" ;;
    muse:CONTEXT_THRESHOLD_TOKENS) echo "$PH_GATEWAY_CONTEXT_THRESHOLD_TOKENS" ;;
    muse:OUTPUT_CAP_TOKENS) echo "$PH_GATEWAY_OUTPUT_CAP_TOKENS" ;;
    muse:PRICE_INPUT) echo "$PH_GATEWAY_PRICE_INPUT" ;;
    muse:PRICE_OUTPUT) echo "$PH_GATEWAY_PRICE_OUTPUT" ;;
    muse:PRICE_CACHE_READ) echo "$PH_GATEWAY_PRICE_CACHE_READ" ;;
    muse:PRICE_CACHE_WRITE) echo "$PH_GATEWAY_PRICE_CACHE_WRITE" ;;
    opus:KIND) echo gateway ;;
    opus:ROUTE) echo "gateway: {kind: litellm, url: $PH_GATEWAY_URL}" ;;
    opus:MODEL) echo "$PH_ADVISOR_MODEL" ;;
    opus:ENDPOINT) echo responses ;;
    opus:EFFORT) echo high ;;
    opus:API_KEY_ENV) echo "$PH_GATEWAY_API_KEY_ENV" ;;
    opus:CONTEXT_WINDOW_TOKENS) echo "$PH_ADVISOR_CONTEXT_WINDOW_TOKENS" ;;
    opus:CONTEXT_THRESHOLD_TOKENS) echo "$PH_ADVISOR_CONTEXT_THRESHOLD_TOKENS" ;;
    opus:OUTPUT_CAP_TOKENS) echo "$PH_ADVISOR_OUTPUT_CAP_TOKENS" ;;
    opus:PRICE_INPUT) echo "$PH_ADVISOR_PRICE_INPUT" ;;
    opus:PRICE_OUTPUT) echo "$PH_ADVISOR_PRICE_OUTPUT" ;;
    opus:PRICE_CACHE_READ) echo "$PH_ADVISOR_PRICE_CACHE_READ" ;;
    opus:PRICE_CACHE_WRITE) echo "$PH_ADVISOR_PRICE_CACHE_WRITE" ;;
    *) fail "profile_value: unknown profile field '$1:$2'" ;;
  esac
}

# pin_profile PIN -- the model profile the current variant gives a pin id.
pin_profile() {
  case "$1" in
    main) echo "$CA_MAIN" ;;
    triage) echo "$CA_TRIAGE" ;;
    triage-advisor) echo "$CA_ADVISOR" ;;
    *) fail "pin_profile: unknown pin '$1'" ;;
  esac
}

# workflow_pins WORKFLOW -- the pin ids a Worker of that Workflow uses: its
# Workflow's pin, plus the Advisor pin for `triage`.
workflow_pins() {
  case "$1" in
    implement) echo main ;;
    triage) echo 'triage triage-advisor' ;;
    *) fail "workflow_pins: unknown Workflow '$1'" ;;
  esac
}

# workflow_keys WORKFLOW -- the model key variables a Worker of that
# Workflow needs, space-separated and sorted.
workflow_keys() {
  for pin in $(workflow_pins "$1"); do
    profile_value "$(pin_profile "$pin")" API_KEY_ENV
  done | sort -u | tr '\n' ' '
}

# workflow_uses_gateway WORKFLOW -- true when any pin a Worker of that
# Workflow uses goes through the LiteLLM gateway (the Worker then joins the
# gateway network overlay).
workflow_uses_gateway() {
  for pin in $(workflow_pins "$1"); do
    if [ "$(profile_value "$(pin_profile "$pin")" KIND)" = gateway ]; then
      return 0
    fi
  done
  return 1
}

# ca_workers -- the Worker services of the current variant with their
# Workflows, one `service:workflow` per line.
ca_workers() {
  echo "worker:$CA_W1"
  if [ -n "$CA_W2" ]; then
    echo "worker-2:$CA_W2"
  fi
}

# ca_all_keys -- every model key variable some declared pin names.
ca_all_keys() {
  for workflow in $CA_WORKFLOWS; do
    workflow_keys "$workflow"
  done | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '
}

# ca_handoff_tokens -- the reserved `ai-handoff` effective-tokens allowance
# for the current variant's `main` pin.
ca_handoff_tokens() {
  handoff_effective_tokens "$(profile_value "$CA_MAIN" CONTEXT_THRESHOLD_TOKENS)" \
    "$(profile_value "$CA_MAIN" OUTPUT_CAP_TOKENS)"
}

# workflow_block CONTENT WORKFLOW -- the lines of one Workflow of a rendered
# workflow.yml: from its `  <id>:` line under `workflows:` to the next
# Workflow.
# workflow_needs_contract WORKFLOW_CONTENT ID -- whether Workflow ID needs a
# Validation Contract, by coding-agent's rule (`Workflow.needs_validation_contract`,
# ADR 0037): an operation step `check-readiness` or `run-validation`, or an
# agent step whose tools include `tests`.
workflow_needs_contract() {
  workflow_block "$1" "$2" |
    grep -Eq '^ *operation: (check-readiness|run-validation)( |$)|^ *tools: \[.*(\[|, )tests(,|\])'
}

workflow_block() {
  printf '%s\n' "$1" | awk -v wf="$2" '
    /^workflows:$/ { in_wf = 1; next }
    in_wf && $0 == "  " wf ":" { show = 1; next }
    in_wf && /^  [a-z0-9-]+:/ { show = 0 }
    show { print }'
}

# pin_block CONTENT PIN -- the lines of one pin under `models:` of a
# rendered workflow.yml.
pin_block() {
  printf '%s\n' "$1" | awk -v pin="$2" '
    /^models:$/ { in_models = 1; next }
    in_models && /^[^ #]/ { in_models = 0 }
    in_models && index($0, "  " pin ":") == 1 { show = 1; next }
    in_models && /^  [a-z0-9-]+:/ { show = 0 }
    in_models && show { print }'
}

# worker_workflow_arg CONFIG SERVICE -- the value after `--workflow` in one
# service's command in the Compose model.
worker_workflow_arg() {
  service_block "$1" "$2" | awk '
    found { sub(/^[[:space:]]*-[[:space:]]*/, ""); print; exit }
    /^[[:space:]]*-[[:space:]]*--workflow$/ { found = 1 }'
}

# check_coding_agent_instance DIR LABEL VARIANT -- `docker compose config`
# must accept the rendered coding-agent directory, and the resulting model
# must carry the adapter's shape: the build-only `engine` base plus the
# derived services (`agent`, `validate` and one or two Workers) sharing one
# derived image, every Worker with its own state volume; a default model
# (no profile) of `engine` (`scale: 0`) and the Workers only, so that a bare
# `docker compose up` starts the Workers alone; all four discovery labels on
# every Worker and on no one-off service; each Worker's hardening (never
# restarted, init, read-only root filesystem, the full v3 `run` invocation
# with its own `--workflow` and no bind mount at /etc/coding-agent), the
# exact stop grace on the rendered file, and the Compose project name equal
# to the instance directory name. Each Worker gets exactly the model keys of
# its own pins (its Workflow's pin, plus the Advisor pin for `triage`), no
# one-off seat gets any, and a Worker using a gateway pin — and only such a
# Worker — joins GATEWAY_NETWORK through the overlay. The rendered Workflow
# Configuration must declare exactly the variant's Workflows, name
# credentials by environment variable only, carry each pin with its own
# route, and satisfy the per-Workflow rules (`implement`: a lawful Selection
# Label and Step Allowances that fit the Work Pool; `triage`: its input and
# exclusions, the three results with their end labels, `input.comments`,
# the `advisor` group with its mapping, a draft `open-pull-request` behind
# `commit-and-push` on every result path, and no `check-readiness` or
# `run-validation`). The rendered Dockerfile must derive FROM the engine
# base and run `config validate` (once per declared Workflow, from the
# WORKFLOWS build argument), `prepare-skill-bundle` and
# `verify-skill-bundle` in that order, with the verification after the last
# relevant COPY. VARIANT is one of ca_variant's.
#
# Add new model assertions here; the CI workflow needs no changes.
check_coding_agent_instance() {
  dir=$1
  label=$2
  ca_variant "$3"
  instance_dir_name=$(basename "$dir")
  info "checking $label instance"
  worker_services=$(ca_workers | cut -d: -f1 | tr '\n' ' ')
  worker_count=$(ca_workers | wc -l | tr -d ' ')
  # The full model: `agent` and `validate` sit in the `tools` profile, so
  # every per-service assertion below reads the model with all profiles
  # enabled. Without it their blocks would be empty and the "key absent
  # from this seat" checks would pass vacuously.
  if ! config_output=$(compose_config "$dir" --profile '*'); then
    fail "$label: 'docker compose --profile * config' failed"
  fi
  # A bare `docker compose up -d` must start the Workers alone. `engine`
  # must stay in the default model, because a profile left inactive would
  # drop it and break the `service:engine` build context; `scale: 0` keeps
  # it out of `up` instead. The one-off seats are kept out by the `tools`
  # profile.
  if ! default_services=$(compose_services "$dir"); then
    fail "$label: 'docker compose config --services' failed"
  fi
  default_services=$(printf '%s\n' "$default_services" | sort | tr '\n' ' ')
  if [ "$default_services" != "engine $worker_services" ]; then
    fail "$label: default services are '$default_services', want 'engine $worker_services' (agent and validate belong in the tools profile)"
  fi
  assert_contains "$(service_block "$config_output" engine)" 'scale: 0' \
    "$label: engine lacks scale: 0, so a bare 'docker compose up' would start it"
  assert_not_contains "$(service_block "$config_output" engine)" 'profiles:' \
    "$label: engine must not take a profile (it would break the service:engine build context)"
  for seat in agent validate; do
    assert_contains "$(service_block "$config_output" "$seat")" '- tools' \
      "$label: $seat seat is not in the tools profile"
  done
  # The Compose project is the directory name: the template sets no `name:`.
  assert_contains "$config_output" "name: $instance_dir_name" \
    "$label: Compose project name is not the instance directory name"
  for service in agent validate engine $worker_services; do
    assert_contains "$config_output" "  $service:" \
      "$label: $service service missing from the Compose model"
  done
  if [ -z "$CA_W2" ]; then
    assert_not_contains "$config_output" '  worker-2:' \
      "$label: a single-Worker Instance renders worker-2"
    assert_not_contains "$config_output" 'state_2' \
      "$label: a single-Worker Instance renders the state_2 volume"
  fi
  # Every runtime seat shares the derived image; the engine base carries
  # its own tag and is never run. Count service-level keys only (four-space
  # indent): the model also keeps the top-level `x-agent` extension with its
  # own copy of the image.
  runtime_seats=$((2 + worker_count))
  derived_image_count=$(printf '%s\n' "$config_output" | grep -cx -- "    image: coding-agent:$PH_CODING_AGENT_SHORT_NAME" || true)
  if [ "$derived_image_count" != "$runtime_seats" ]; then
    fail "$label: want the derived image on all $runtime_seats runtime seats (agent, validate, $worker_services), found $derived_image_count"
  fi
  assert_contains "$config_output" "image: coding-agent-engine:$PH_CODING_AGENT_SHORT_NAME" \
    "$label: engine base image tag missing from the Compose model"
  assert_contains "$config_output" '/var/lib/coding-agent' \
    "$label: state path missing from the Compose model"
  # The build argument lists the declared Workflows, so the Dockerfile
  # validates once per Workflow at build time.
  assert_line_matches "$config_output" \
    "^ +WORKFLOWS: ['\"]?${CA_WORKFLOWS}['\"]?\$" \
    "$label: build argument WORKFLOWS is not '$CA_WORKFLOWS'"
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
  # The Workflow is the Worker's own configuration: a literal per stanza,
  # never an `.env` interpolation shared by the Pool.
  # shellcheck disable=SC2016 # the literal, unexpanded reference is the point
  assert_not_contains "$(cat "$dir/compose.yaml")" '${WORKFLOW' \
    "$label: compose.yaml selects the Workflow through .env, not per Worker"
  for worker_entry in $(ca_workers); do
    service=${worker_entry%%:*}
    workflow=${worker_entry#*:}
    block=$(service_block "$config_output" "$service")
    # The Worker's full v3 `run` invocation: every flag and value upstream
    # renders, and none of the removed legacy options (v3 exits 2 on them).
    for token in '--config' '/etc/coding-agent/workflow.yml' '--workflow' \
      '--policy' '/etc/coding-agent/skill-policy.json' \
      '--bundle-dir' '/opt/coding-agent/skill-bundle' \
      '--skill-home' '/home/agent' \
      '--state-dir' '/var/lib/coding-agent' \
      '--toolchain-matrix' '/opt/coding-agent/toolchain-matrix.json'; do
      assert_contains "$block" "$token" \
        "$label: $service command misses '$token'"
    done
    actual_workflow=$(worker_workflow_arg "$config_output" "$service")
    if [ "$actual_workflow" != "$workflow" ]; then
      fail "$label: $service runs --workflow '$actual_workflow', want '$workflow'"
    fi
    assert_not_contains "$block" 'profiles:' \
      "$label: $service must not take a profile (a bare 'docker compose up' starts it)"
    assert_contains "$block" '/var/lib/coding-agent/operator:uid=1000,gid=1000,mode=0700' \
      "$label: $service private-IPC tmpfs missing its ownership and mode options"
    # Each Worker its own state volume.
    if [ "$service" = worker ]; then
      want_volume=state
    else
      want_volume=state_${service#worker-}
    fi
    assert_line_matches "$block" "source: $want_volume\$" \
      "$label: $service does not mount its own state volume $want_volume"
    # Exactly the model keys of this Worker's own pins.
    want_keys=$(workflow_keys "$workflow")
    for key in ANTHROPIC_API_KEY OPENAI_API_KEY LITELLM_PROXY_API_KEY; do
      case " $want_keys " in
        *" $key "*)
          assert_contains "$block" "$key" \
            "$label: $key missing from the $service environment (its pins name it)" ;;
        *)
          assert_not_contains "$block" "$key" \
            "$label: $key reached the $service environment (none of its pins names it)" ;;
      esac
    done
    # A Worker using a gateway pin joins the gateway network; one whose
    # pins are all direct does not. Match the service's `networks:` entry,
    # not a bare word: the fixture's build context path may contain
    # "gateway".
    if workflow_uses_gateway "$workflow"; then
      assert_line_matches "$block" '^      gateway:' \
        "$label: $service uses a gateway pin but is not attached to the gateway network"
    else
      assert_not_line_matches "$block" '^      gateway:' \
        "$label: $service joined the gateway network with direct pins only"
    fi
  done
  assert_not_contains "$config_output" '--skills-home' \
    "$label: worker command carries the removed --skills-home option (v3 exits 2)"
  assert_not_contains "$config_output" '--skill-bundle-dir' \
    "$label: worker command carries the removed --skill-bundle-dir option (v3 exits 2)"
  for seat in agent validate; do
    for key in ANTHROPIC_API_KEY OPENAI_API_KEY LITELLM_PROXY_API_KEY; do
      assert_not_contains "$(service_block "$config_output" "$seat")" "$key" \
        "$label: $key reached the $seat seat's environment"
    done
    assert_not_line_matches "$(service_block "$config_output" "$seat")" '^      gateway:' \
      "$label: $seat seat joined the gateway network"
  done
  operator_tmpfs_count=$(printf '%s\n' "$config_output" | grep -cF -- '/var/lib/coding-agent/operator' || true)
  if [ "$operator_tmpfs_count" != "$worker_count" ]; then
    fail "$label: want one operator tmpfs entry per Worker ($worker_count), found $operator_tmpfs_count"
  fi
  assert_contains "$config_output" 'stop_grace_period:' \
    "$label: stop_grace_period missing from the Compose model"
  # All four discovery labels appear once per Worker in the whole model,
  # never on a one-off seat, and each Worker carries its own Managed
  # Instance name (`<short-name>`, then `<short-name>-2`).
  for key in contract instance exec-user backend; do
    key_count=$(printf '%s\n' "$config_output" | grep -cF -- "io.github.lbacik.agent-operator.$key" || true)
    if [ "$key_count" != "$worker_count" ]; then
      fail "$label: discovery label '$key' on $key_count services, want $worker_count (the Workers only)"
    fi
  done
  assert_line_matches "$config_output" \
    "io\\.github\\.lbacik\\.agent-operator\\.contract: (\"1\"|1)\$" \
    "$label: contract label is not major 1"
  assert_line_matches "$(service_block "$config_output" worker)" \
    "io\\.github\\.lbacik\\.agent-operator\\.instance: $PH_CODING_AGENT_SHORT_NAME\$" \
    "$label: worker instance label is not $PH_CODING_AGENT_SHORT_NAME"
  if [ -n "$CA_W2" ]; then
    assert_line_matches "$(service_block "$config_output" worker-2)" \
      "io\\.github\\.lbacik\\.agent-operator\\.instance: $PH_CODING_AGENT_SHORT_NAME-2\$" \
      "$label: worker-2 instance label is not $PH_CODING_AGENT_SHORT_NAME-2"
  fi
  instances=$(printf '%s\n' "$config_output" | sed -n 's/.*io\.github\.lbacik\.agent-operator\.instance: *//p')
  if printf '%s\n' "$instances" | grep -Eqv '^[a-z0-9][a-z0-9-]{0,62}$'; then
    fail "$label: an instance label does not match ^[a-z0-9][a-z0-9-]{0,62}$"
  fi
  assert_contains "$config_output" 'io.github.lbacik.agent-operator.exec-user: agent' \
    "$label: exec-user label is not agent"
  assert_not_contains "$config_output" 'agent-operator.exec-user: root' \
    "$label: exec-user label must not be root"
  assert_contains "$config_output" 'io.github.lbacik.agent-operator.backend: coding-agent' \
    "$label: backend label is not coding-agent"
  # Hardening: one restart line and one init per Worker (never restarted),
  # and a read-only root filesystem on every runtime seat. The build-only
  # `engine` service sets none of these.
  restart_count=$(printf '%s\n' "$config_output" | grep -c -- 'restart:' || true)
  if [ "$restart_count" != "$worker_count" ]; then
    fail "$label: want one restart: line per Worker ($worker_count), found $restart_count"
  fi
  if printf '%s\n' "$config_output" | grep -- 'restart:' | grep -Eqv "restart: ['\"]?no['\"]?\$"; then
    fail "$label: a Worker is not restart: no"
  fi
  init_count=$(printf '%s\n' "$config_output" | grep -c -- 'init: true' || true)
  if [ "$init_count" != "$worker_count" ]; then
    fail "$label: want one init: true line per Worker ($worker_count), found $init_count"
  fi
  read_only_count=$(printf '%s\n' "$config_output" | grep -c -- '^    read_only: true$' || true)
  if [ "$read_only_count" != "$runtime_seats" ]; then
    fail "$label: want read_only: true on all $runtime_seats runtime seats, found $read_only_count"
  fi
  # Resource limits (Forge addition, not upstream's compose): the x-agent
  # anchor carries cpus / mem_limit / pids_limit, so every runtime seat
  # inherits them. Compose normalises mem_limit to bytes (3g -> 3221225472),
  # so assert the normalised form, not the literal `3g`.
  # Count service-level keys only (four-space indent): the model also keeps
  # the top-level `x-agent` extension, unnormalised, with its own copies.
  for limit_key in 'cpus:' 'mem_limit:' 'pids_limit:'; do
    limit_count=$(printf '%s\n' "$config_output" | grep -c -- "^    $limit_key" || true)
    if [ "$limit_count" != "$runtime_seats" ]; then
      fail "$label: want $limit_key on all $runtime_seats runtime seats, found $limit_count"
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
  # Overrides in the environment change the rendered values. The gateway
  # overlay is left out here (no COMPOSE_FILE in the hermetic environment),
  # so this reads compose.yaml alone.
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
  # grace above the Workflow Configuration's shutdown grace, on every Worker.
  grace_count=$(grep -cF -- 'stop_grace_period: 60s' "$dir/compose.yaml" || true)
  if [ "$grace_count" != "$worker_count" ]; then
    fail "$label: want stop_grace_period: 60s on every Worker ($worker_count), found $grace_count"
  fi
  # The gateway overlay and the env file: the overlay exists exactly when
  # some Worker uses a gateway pin, and lists exactly those Workers; .env
  # activates exactly the model keys some pin names.
  gateway_workers=''
  for worker_entry in $(ca_workers); do
    if workflow_uses_gateway "${worker_entry#*:}"; then
      gateway_workers="$gateway_workers ${worker_entry%%:*}"
    fi
  done
  env_content=$(cat "$dir/.env")
  if [ -n "$gateway_workers" ]; then
    if [ ! -f "$dir/compose.coding-agent.litellm.yaml" ]; then
      fail "$label: gateway overlay compose.coding-agent.litellm.yaml missing"
    fi
    for service in $worker_services; do
      case " $gateway_workers " in
        *" $service "*)
          assert_line_matches "$(cat "$dir/compose.coding-agent.litellm.yaml")" "^  $service:\$" \
            "$label: gateway overlay does not list $service" ;;
        *)
          assert_not_line_matches "$(cat "$dir/compose.coding-agent.litellm.yaml")" "^  $service:\$" \
            "$label: gateway overlay lists $service, whose pins are all direct" ;;
      esac
    done
    assert_contains "$env_content" \
      'COMPOSE_FILE=compose.yaml:compose.coding-agent.litellm.yaml' \
      "$label: .env does not load the gateway overlay"
    assert_contains "$env_content" \
      "GATEWAY_NETWORK=$PH_GATEWAY_NETWORK" \
      "$label: .env does not name the gateway network"
    assert_contains "$config_output" "$PH_GATEWAY_NETWORK" \
      "$label: gateway network missing from the Compose model"
    assert_contains "$config_output" 'external: true' \
      "$label: gateway network is not external in the Compose model"
  else
    if [ -e "$dir/compose.coding-agent.litellm.yaml" ]; then
      fail "$label: gateway overlay rendered with direct pins only"
    fi
    assert_not_line_matches "$env_content" '^COMPOSE_FILE=' \
      "$label: .env loads an overlay with direct pins only"
  fi
  all_keys=$(ca_all_keys)
  for key in ANTHROPIC_API_KEY OPENAI_API_KEY LITELLM_PROXY_API_KEY; do
    case " $all_keys " in
      *" $key "*)
        assert_line_matches "$env_content" "^$key=\$" \
          "$label: .env does not set $key (a pin names it)" ;;
      *)
        assert_not_line_matches "$env_content" "^$key=" \
          "$label: .env sets $key (no pin names it)" ;;
    esac
  done
  # The rendered Workflow Configuration: a version: 4 file with a Skill
  # Bundle, repository, branch, credentials by environment-variable name
  # only, exactly the variant's Workflows and pins.
  workflow_content=$(cat "$dir/workflow/workflow.yml")
  assert_line_matches "$workflow_content" '^version: 4$' \
    "$label: workflow.yml version line is not exactly 'version: 4'"
  assert_contains "$workflow_content" 'workflow-v4.schema.json' \
    "$label: workflow.yml editor schema is not workflow-v4"
  assert_not_line_matches "$workflow_content" '# workflow-(implement|triage)-(begin|end)$' \
    "$label: workflow.yml still carries a Workflow block marker"
  assert_contains "$workflow_content" 'git+https://github.com/mattpocock/skills.git' \
    "$label: workflow.yml Skill Bundle source is not mattpocock/skills"
  assert_contains "$workflow_content" '3cca18b368ae95cdbdebbff572ccafa662551015' \
    "$label: workflow.yml Skill Bundle ref is not the reference pin"
  want_include=''
  for workflow in $CA_WORKFLOWS; do
    case $workflow in
      implement) want_include="$want_include, implement, tdd, code-review, codebase-design" ;;
      triage) want_include="$want_include, triage, grilling, domain-modeling" ;;
    esac
  done
  want_include=${want_include#, }
  assert_contains "$workflow_content" "include: [$want_include]" \
    "$label: workflow.yml Skill Bundle membership is not [$want_include]"
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
  # Exactly the declared Workflows, and exactly their pins.
  declared=$(printf '%s\n' "$workflow_content" |
    awk '/^workflows:$/ { in_wf = 1; next } in_wf && /^  [a-z0-9-]+:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' |
    tr '\n' ' ')
  if [ "$declared" != "$CA_WORKFLOWS " ]; then
    fail "$label: workflow.yml declares Workflows '$declared', want '$CA_WORKFLOWS '"
  fi
  for pin in main triage triage-advisor; do
    profile=$(pin_profile "$pin")
    pin_content=$(pin_block "$workflow_content" "$pin")
    if [ -z "$profile" ]; then
      if [ -n "$pin_content" ]; then
        fail "$label: workflow.yml declares pin '$pin' for an undeclared Workflow"
      fi
      continue
    fi
    if [ -z "$pin_content" ]; then
      fail "$label: workflow.yml misses pin '$pin'"
    fi
    # One route per pin: a direct pin is a `provider:` line with no
    # `gateway:` key, a gateway pin a `gateway:` block with no `provider:`
    # key. Every pin declares the three token keys (version 4) and names its
    # key by environment variable.
    for field in ROUTE MODEL ENDPOINT EFFORT API_KEY_ENV \
      CONTEXT_WINDOW_TOKENS CONTEXT_THRESHOLD_TOKENS OUTPUT_CAP_TOKENS; do
      value=$(profile_value "$profile" "$field")
      case $field in
        ROUTE) line="$value" ;;
        *) line="$(printf '%s' "$field" | tr 'A-Z_' 'a-z-'): $value" ;;
      esac
      assert_line_matches "$pin_content" "^    $(printf '%s' "$line" | sed 's/[][{}.*^$|+?()]/\\&/g')\$" \
        "$label: pin '$pin' misses '$line'"
    done
    if [ "$(profile_value "$profile" KIND)" = direct ]; then
      assert_not_line_matches "$pin_content" '^    gateway:' \
        "$label: direct pin '$pin' carries a gateway block"
    else
      assert_not_line_matches "$pin_content" '^    provider:' \
        "$label: gateway pin '$pin' carries a provider key"
    fi
    assert_contains "$pin_content" "prices-usd-per-mtok: {input: $(profile_value "$profile" PRICE_INPUT), output: $(profile_value "$profile" PRICE_OUTPUT), cache-read: $(profile_value "$profile" PRICE_CACHE_READ), cache-write: $(profile_value "$profile" PRICE_CACHE_WRITE)}" \
      "$label: pin '$pin' prices are not the confirmed fixture prices"
  done
  # Version 4 renamed the token meter: a `tokens` limit is refused as an
  # unknown key, in a block or a flow mapping.
  assert_not_line_matches "$workflow_content" '^ *tokens:' \
    "$label: workflow.yml still names the version 3 tokens meter"
  assert_not_line_matches "$workflow_content" '[{,] *tokens:' \
    "$label: workflow.yml still names the version 3 tokens meter"
  assert_not_contains "$workflow_content" 'sk-' \
    "$label: workflow.yml names a secret value, not an environment variable"
  case " $CA_WORKFLOWS " in
    *" implement "*) check_coding_agent_implement "$dir" "$label" "$workflow_content" ;;
  esac
  case " $CA_WORKFLOWS " in
    *" triage "*) check_coding_agent_triage "$dir" "$label" "$workflow_content" ;;
  esac
  # Every Selection Label is distinct from every end label in the file
  # (config validate refuses the overlap): `implement`'s label is never one
  # of `triage`'s end labels.
  for end_label in ready-for-agent needs-info ready-for-human; do
    assert_not_line_matches "$workflow_content" "^      label: $end_label\$" \
      "$label: workflow.yml uses end label $end_label as a Selection Label"
  done
  assert_contains "$env_content" "TARGET_REPO=$PH_OWNER/$PH_REPO" \
    "$label: .env TARGET_REPO is not $PH_OWNER/$PH_REPO"
  assert_contains "$env_content" "CODING_AGENT_REF=$PH_CODING_AGENT_REF" \
    "$label: .env CODING_AGENT_REF is not $PH_CODING_AGENT_REF"
  assert_not_line_matches "$env_content" '^#? *WORKFLOW=' \
    "$label: .env selects a Workflow (each Worker's stanza does)"
  example_content=$(cat "$dir/.env.example")
  for worker_var in 'WORKER_CPUS=1.5' 'WORKER_MEM_LIMIT=3g' 'WORKER_PIDS_LIMIT=1024'; do
    assert_contains "$example_content" "# $worker_var" \
      "$label: .env.example misses commented-out $worker_var"
  done
  if [ ! -f "$dir/workflow/skill-policy.json" ]; then
    fail "$label: workflow/skill-policy.json missing (copied from the reference or drafted and operator-approved)"
  fi
  # The derived deployment image: the Dockerfile is copied verbatim from
  # the asset (no placeholders), derives FROM the engine base, and runs the
  # Agent Forge sequence — `config validate` once per declared Workflow,
  # then `prepare-skill-bundle --mode install`, then `verify-skill-bundle`
  # against the final roots — as the runtime user with no secrets. The
  # verification must come after the last relevant COPY so the build fails
  # on any mismatch.
  if [ ! -f "$dir/Dockerfile" ]; then
    fail "$label: Dockerfile missing (the derived deployment image)"
  fi
  dockerfile_content=$(cat "$dir/Dockerfile")
  assert_contains "$dockerfile_content" 'FROM engine' \
    "$label: Dockerfile does not derive from the engine base"
  assert_line_matches "$dockerfile_content" '^ARG WORKFLOWS=' \
    "$label: Dockerfile takes no WORKFLOWS build argument"
  # shellcheck disable=SC2016 # the literal, unexpanded Dockerfile text is the point
  assert_line_matches "$dockerfile_content" 'for workflow in \$WORKFLOWS' \
    "$label: Dockerfile does not validate once per declared Workflow"
  # shellcheck disable=SC2016 # the literal, unexpanded Dockerfile text is the point
  assert_contains "$dockerfile_content" '--workflow "$workflow"' \
    "$label: Dockerfile does not pass each Workflow id to config validate"
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
  check_coding_agent_profile "$dir" "$label" "$workflow_content" "$dockerfile_content"
  assert_no_simple_agent_profile "$dir" "$label"
}

# check_coding_agent_profile DIR LABEL WORKFLOW_CONTENT DOCKERFILE_CONTENT --
# the Project Profile shape (call after ca_variant). Every variant: no
# `instance-profile-*` marker survives in workflow.yml or the Dockerfile,
# and the Dockerfile's `rm -rf` (before the first COPY) removes a stale
# /etc/coding-agent/project-profile.yml from the base image. An
# Instance-supplied profile (CA_PROFILE=1) renders `target.profile:
# project-profile.yml` in the target block, writes
# workflow/project-profile.yml as a schema-2 profile, and COPYs it to
# /etc/coding-agent/project-profile.yml before `config validate`; any other
# variant renders none of the three.
check_coding_agent_profile() {
  dir=$1
  label=$2
  workflow_content=$3
  dockerfile_content=$4
  assert_not_line_matches "$workflow_content" '^ *# instance-profile-(begin|end)$' \
    "$label: workflow.yml still carries an instance-profile marker"
  assert_not_line_matches "$dockerfile_content" '^ *# instance-profile-(begin|end)$' \
    "$label: Dockerfile still carries an instance-profile marker"
  stale_rm="    /etc/coding-agent/project-profile.yml \\"
  stale_rm_line=$(printf '%s\n' "$dockerfile_content" | grep -nxF -- "$stale_rm" | cut -d: -f1 | head -n 1)
  rm_line=$(printf '%s\n' "$dockerfile_content" | grep -n '^RUN rm -rf ' | cut -d: -f1 | head -n 1)
  first_copy_line=$(printf '%s\n' "$dockerfile_content" | grep -n '^COPY ' | cut -d: -f1 | head -n 1)
  if [ -z "$stale_rm_line" ] || [ -z "$rm_line" ] || [ -z "$first_copy_line" ] ||
    [ "$stale_rm_line" -le "$rm_line" ] || [ "$stale_rm_line" -ge "$first_copy_line" ]; then
    fail "$label: Dockerfile does not remove a stale /etc/coding-agent/project-profile.yml before the first COPY"
  fi
  profile_copy='COPY workflow/project-profile.yml /etc/coding-agent/project-profile.yml'
  if [ "$CA_PROFILE" = 1 ]; then
    target_block=$(printf '%s\n' "$workflow_content" | awk '
      /^target:$/ { in_block = 1; next }
      in_block && /^[^ #]/ { exit }
      in_block { print }')
    assert_line_matches "$target_block" '^  profile: project-profile\.yml$' \
      "$label: workflow.yml target block carries no 'profile: project-profile.yml'"
    if [ ! -f "$dir/workflow/project-profile.yml" ]; then
      fail "$label: workflow/project-profile.yml missing (named by target.profile)"
    fi
    assert_line_matches "$(cat "$dir/workflow/project-profile.yml")" '^schema: 2$' \
      "$label: workflow/project-profile.yml is not a schema-2 Project Profile"
    copy_line=$(printf '%s\n' "$dockerfile_content" | grep -nxF -- "$profile_copy" | cut -d: -f1 | head -n 1)
    validate_line=$(printf '%s\n' "$dockerfile_content" | grep -nF 'agent config validate' | cut -d: -f1 | head -n 1)
    if [ -z "$copy_line" ]; then
      fail "$label: Dockerfile does not bake workflow/project-profile.yml"
    elif [ -z "$validate_line" ] || [ "$copy_line" -ge "$validate_line" ]; then
      fail "$label: Dockerfile bakes the profile after config validate (validate must check it)"
    fi
  else
    assert_not_line_matches "$workflow_content" '^ *profile:' \
      "$label: workflow.yml renders target.profile without an Instance-supplied profile"
    if [ -e "$dir/workflow/project-profile.yml" ]; then
      fail "$label: workflow/project-profile.yml rendered without an Instance-supplied profile"
    fi
    assert_not_contains "$dockerfile_content" "$profile_copy" \
      "$label: Dockerfile bakes a profile without an Instance-supplied profile"
  fi
}

# check_coding_agent_implement DIR LABEL WORKFLOW_CONTENT -- the `implement`
# Workflow of a rendered workflow.yml: a lawful Selection Label, the full
# Attempt Ceiling, the `ai-handoff` reserve for the `main` pin, Step
# Allowances that fit the Work Pool, and its two prompt files.
check_coding_agent_implement() {
  block=$(workflow_block "$3" implement)
  assert_contains "$block" 'model: main' \
    "$2: implement does not pin main"
  assert_contains "$block" "label: $PH_SELECTION_LABEL" \
    "$2: implement Selection Label is not $PH_SELECTION_LABEL"
  for forbidden in 'label: ready-for-human' 'label: wontfix' 'wayfinder' 'label: needs-triage'; do
    assert_not_contains "$block" "$forbidden" \
      "$2: implement Selection Label breaks the rules ($forbidden)"
  done
  assert_contains "$block" 'skill: implement' \
    "$2: implement process step names no skill"
  assert_contains "$block" 'skill: code-review' \
    "$2: implement self-review step names no skill"
  # Runtime-only endings need end labels, or the issue leaves every queue
  # unlabelled.
  for outcome in 'interrupted: {labels: [ready-for-human]}' \
    'drift: {labels: [ready-for-human]}'; do
    assert_contains "$block" "$outcome" \
      "$2: implement end labels miss '$outcome'"
  done
  assert_contains "$block" "cost-usd: $PH_LIMIT_COST_USD" \
    "$2: implement Attempt Ceiling cost is incomplete"
  assert_contains "$block" "effective-tokens: $PH_LIMIT_EFFECTIVE_TOKENS" \
    "$2: implement Attempt Ceiling effective-tokens are incomplete"
  assert_contains "$block" "tool-calls: $PH_LIMIT_TOOL_CALLS" \
    "$2: implement Attempt Ceiling tool-calls are incomplete"
  assert_contains "$block" "wall-clock-minutes: $PH_LIMIT_WALL_CLOCK_MINUTES" \
    "$2: implement Attempt Ceiling wall-clock is incomplete"
  assert_contains "$block" "effective-tokens: $(ca_handoff_tokens), tool-calls: 30" \
    "$2: implement ai-handoff reserve is not $(ca_handoff_tokens) effective-tokens"
  assert_contains "$block" "cost-usd: $PH_PROCESS_LIMIT_COST_USD" \
    "$2: implement process Step Allowance missing"
  assert_contains "$block" "cost-usd: $PH_SELF_REVIEW_LIMIT_COST_USD" \
    "$2: implement self-review Step Allowance missing"
  # The fixture's Step Allowances fit the Work Pool on the cost meter: the
  # Attempt Ceiling minus the 1 USD `ai-handoff` reserve leaves room for both.
  # This mirrors the skill's fit check (a 5 USD ceiling with the default 12
  # USD `process` allowance must never render). The cost meter is the whole
  # check here: the rendered steps set `limits` only on `cost-usd`, so it is
  # the only meter an allowance sets.
  if [ "$((PH_LIMIT_COST_USD - 1))" -lt "$PH_PROCESS_LIMIT_COST_USD" ]; then
    fail "$2: process allowance $PH_PROCESS_LIMIT_COST_USD does not fit the $((PH_LIMIT_COST_USD - 1)) USD Work Pool"
  fi
  if [ "$((PH_LIMIT_COST_USD - 1))" -lt "$PH_SELF_REVIEW_LIMIT_COST_USD" ]; then
    fail "$2: self-review allowance $PH_SELF_REVIEW_LIMIT_COST_USD does not fit the $((PH_LIMIT_COST_USD - 1)) USD Work Pool"
  fi
  for prompt in implement-policy.md handoff.md; do
    if [ ! -f "$1/workflow/prompts/$prompt" ]; then
      fail "$2: workflow/prompts/$prompt missing"
    fi
  done
}

# check_coding_agent_triage DIR LABEL WORKFLOW_CONTENT -- the `triage`
# Workflow of a rendered workflow.yml (issue #122): `needs-triage` in with
# the three exclusions, the triage pin and the Advisor pin, the three
# results with their end labels, `input.comments` as an input, the
# `advisor` tool group with its mapping, on every result path a
# `post-comment` of that result's document, then `commit-and-push`, then a
# draft `open-pull-request` with the same document, and no
# `check-readiness` or `run-validation`. Its two policy prompts are the
# Forge assets, byte for byte, with no placeholder left.
check_coding_agent_triage() {
  block=$(workflow_block "$3" triage)
  assert_contains "$block" 'model: triage' \
    "$2: triage does not pin the triage model"
  assert_contains "$block" 'label: needs-triage' \
    "$2: triage Selection Label is not needs-triage"
  assert_contains "$block" 'exclude: [needs-info, ready-for-human, wontfix]' \
    "$2: triage exclusions are not [needs-info, ready-for-human, wontfix]"
  for outcome in 'completed: {labels: [ready-for-agent]}' \
    'blocked: {labels: [needs-info]}' \
    'unfinished: {labels: [ready-for-human]}' \
    'failed: {labels: [ready-for-human]}' \
    'internal-failure: {labels: [ready-for-human]}' \
    'interrupted: {labels: [ready-for-human]}' \
    'drift: {labels: [ready-for-human]}'; do
    assert_contains "$block" "$outcome" \
      "$2: triage end labels miss '$outcome'"
  done
  for line in '- skill: triage' '- prompt: prompts/triage-policy.md' \
    'tools: [workspace-read, workspace-write, shell, advisor]' \
    'advisor: {model: triage-advisor, prompt: prompts/triage-advisor.md}' \
    '- input.comments' 'brief: document' 'notes: document' \
    'recommendation: document'; do
    assert_contains "$block" "$line" \
      "$2: triage step misses '$line'"
  done
  assert_not_contains "$block" 'optional: input.comments' \
    "$2: triage declares input.comments optional (it is a required input)"
  for forbidden in check-readiness run-validation 'draft: false' requires:; do
    assert_not_contains "$block" "$forbidden" \
      "$2: triage carries '$forbidden'"
  done
  for limit in "cost-usd: $PH_TRIAGE_LIMIT_COST_USD" \
    "effective-tokens: $PH_TRIAGE_LIMIT_EFFECTIVE_TOKENS" \
    "tool-calls: $PH_TRIAGE_LIMIT_TOOL_CALLS" \
    "wall-clock-minutes: $PH_TRIAGE_LIMIT_WALL_CLOCK_MINUTES"; do
    assert_contains "$block" "$limit" \
      "$2: triage Attempt Ceiling misses '$limit'"
  done
  # result:document:end on each of the three paths. Each path posts the
  # document, pushes, and opens a draft pull request with the same
  # document; `no-changes` and both pull-request results end the Attempt
  # with the result's outcome.
  for path in ready:brief:completed blocked:notes:blocked \
    human:recommendation:unfinished; do
    result=${path%%:*}
    rest=${path#*:}
    field=${rest%%:*}
    end=${rest#*:}
    assert_contains "$block" "$result: post-$field" \
      "$2: triage result $result does not route to post-$field"
    step=$(printf '%s\n' "$block" | awk -v id="post-$field" '
      $0 == "      " id ":" { show = 1; next }
      /^      [a-z0-9-]+:$/ { show = 0 }
      show { print }')
    for line in 'operation: post-comment' "body: triage.$result.$field" \
      "posted: push-$field"; do
      assert_contains "$step" "$line" "$2: triage post-$field misses '$line'"
    done
    step=$(printf '%s\n' "$block" | awk -v id="push-$field" '
      $0 == "      " id ":" { show = 1; next }
      /^      [a-z0-9-]+:$/ { show = 0 }
      show { print }')
    for line in 'operation: commit-and-push' "pushed: open-$field-pr" \
      "no-changes: {end: $end}"; do
      assert_contains "$step" "$line" "$2: triage push-$field misses '$line'"
    done
    step=$(printf '%s\n' "$block" | awk -v id="open-$field-pr" '
      $0 == "      " id ":" { show = 1; next }
      /^      [a-z0-9-]+:$/ { show = 0 }
      show { print }')
    for line in 'operation: open-pull-request' "body: triage.$result.$field" \
      'draft: true' "opened: {end: $end}" "already-open: {end: $end}"; do
      assert_contains "$step" "$line" "$2: triage open-$field-pr misses '$line'"
    done
  done
  for prompt in triage-policy.md triage-advisor.md; do
    if [ ! -f "$1/workflow/prompts/$prompt" ]; then
      fail "$2: workflow/prompts/$prompt missing"
    fi
    if ! cmp -s "$ASSETS_DIR/prompts/$prompt" "$1/workflow/prompts/$prompt"; then
      fail "$2: workflow/prompts/$prompt is not the Forge asset byte for byte"
    fi
  done
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

# assert_no_simple_agent_profile DIR LABEL -- a coding-agent instance carries no
# simple-coding-agent profile: no simple-coding-agent-profile.yml, and no
# PROFILE_PATH / AGENT_SRC_REF / WORKER_ID in the rendered .env or
# compose.yaml. Its Project Profile is the repository's, or an
# Instance-supplied workflow/project-profile.yml named by target.profile
# (checked in check_coding_agent_profile). It does carry a Dockerfile: the
# derived deployment image (checked in check_coding_agent_instance).
assert_no_simple_agent_profile() {
  if [ -e "$1/simple-coding-agent-profile.yml" ]; then
    fail "$2: coding-agent instance must not contain a simple-coding-agent profile"
  fi
  if grep -qF 'PROFILE_PATH' "$1/.env"; then
    fail "$2: .env sets PROFILE_PATH (no simple-coding-agent profile on this backend)"
  fi
  if grep -qF 'AGENT_SRC_REF' "$1/.env"; then
    fail "$2: .env sets AGENT_SRC_REF (this backend names its ref CODING_AGENT_REF)"
  fi
  if grep -qF 'WORKER_ID' "$1/compose.yaml"; then
    fail "$2: compose.yaml sets WORKER_ID (this backend renders no Worker id and no Claim marker)"
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
# CODING_AGENT_REF, read through ${...} interpolation like AGENT_SRC_REF),
# the declared Workflows as the WORKFLOWS build argument, and each Worker's
# own `--workflow`. A single Worker drops the `worker-2` stanza and its
# `state_2` volume; a two-Worker Pool keeps both and drops the markers. Each
# Worker then keeps exactly the model keys of its own pins (its Workflow's
# pin, plus the Advisor pin for `triage`).
render_coding_agent_compose() {
  ca_variant "$3"
  tmp="$2.tmp"
  sed -e "s|{{OWNER}}|$PH_OWNER|g" \
    -e "s|{{REPO}}|$PH_REPO|g" \
    -e "s|{{SHORT_NAME}}|$PH_CODING_AGENT_SHORT_NAME|g" \
    -e "s|{{WORKFLOWS}}|$CA_WORKFLOWS|g" \
    -e "s|{{WORKER_WORKFLOW}}|$CA_W1|g" \
    -e "s|{{WORKER_2_WORKFLOW}}|$CA_W2|g" "$1" >"$tmp"
  if [ -z "$CA_W2" ]; then
    sed -e '/^ *# worker-2-begin$/,/^ *# worker-2-end$/d' "$tmp" >"$tmp.2"
  else
    sed -e '/^ *# worker-2-begin$/d' -e '/^ *# worker-2-end$/d' "$tmp" >"$tmp.2"
  fi
  keys1=$(workflow_keys "$CA_W1")
  keys2=''
  if [ -n "$CA_W2" ]; then
    keys2=$(workflow_keys "$CA_W2")
  fi
  awk -v keep1="$keys1" -v keep2="$keys2" '
    /^  [A-Za-z0-9_.-]+:$/ { svc = substr($0, 3, length($0) - 3) }
    /^      (ANTHROPIC_API_KEY|OPENAI_API_KEY|LITELLM_PROXY_API_KEY):/ {
      key = $1
      sub(/:$/, "", key)
      keep = (svc == "worker") ? keep1 : keep2
      if (index(" " keep " ", " " key " ") == 0) next
    }
    { print }' "$tmp.2" >"$2"
  rm -f "$tmp" "$tmp.2"
}

# render_coding_agent_env SRC DST VARIANT -- .env/.env.example from the
# coding-agent env example template: exactly the model keys some declared
# pin names stay active, the others stay commented out, and a variant with
# a gateway pin additionally enables the gateway network overlay
# (COMPOSE_FILE plus GATEWAY_NETWORK).
render_coding_agent_env() {
  ca_variant "$3"
  tmp="$2.tmp"
  sed -e "s|{{OWNER}}|$PH_OWNER|g" \
    -e "s|{{REPO}}|$PH_REPO|g" \
    -e "s|{{CODING_AGENT_REF}}|$PH_CODING_AGENT_REF|g" \
    -e 's|^ANTHROPIC_API_KEY=$|# ANTHROPIC_API_KEY=|' \
    "$1" >"$tmp"
  for key in $(ca_all_keys); do
    sed -e "s|^# $key=\$|$key=|" "$tmp" >"$tmp.2"
    mv "$tmp.2" "$tmp"
  done
  gateway=0
  for worker_entry in $(ca_workers); do
    if workflow_uses_gateway "${worker_entry#*:}"; then
      gateway=1
    fi
  done
  if [ "$gateway" = 1 ]; then
    sed -e 's|^# COMPOSE_FILE=compose.yaml:compose.coding-agent.litellm.yaml$|COMPOSE_FILE=compose.yaml:compose.coding-agent.litellm.yaml|' \
      -e "s|^# GATEWAY_NETWORK=$|GATEWAY_NETWORK=$PH_GATEWAY_NETWORK|" \
      "$tmp" >"$2"
  else
    cp "$tmp" "$2"
  fi
  rm -f "$tmp"
}

# render_coding_agent_overlay SRC DST VARIANT -- compose.coding-agent.litellm.yaml
# (variants with a gateway pin only): the template carries no placeholders;
# it keeps exactly the Workers that use a gateway pin, mirroring
# render_compose_litellm for the simple-coding-agent overlay.
render_coding_agent_overlay() {
  ca_variant "$3"
  cp "$1" "$2.tmp"
  if [ -z "$CA_W2" ] || ! workflow_uses_gateway "$CA_W2"; then
    sed -e '/^ *# worker-2-begin$/,/^ *# worker-2-end$/d' "$2.tmp" >"$2.tmp.2"
    mv "$2.tmp.2" "$2.tmp"
  fi
  if ! workflow_uses_gateway "$CA_W1"; then
    sed -e '/^  worker:$/,/^      - gateway$/d' "$2.tmp" >"$2.tmp.2"
    mv "$2.tmp.2" "$2.tmp"
  fi
  sed -e '/^ *# worker-2-begin$/d' -e '/^ *# worker-2-end$/d' "$2.tmp" >"$2"
  rm -f "$2.tmp"
}

# render_coding_agent_workflow SRC DST VARIANT -- workflow/workflow.yml from
# the coding-agent Workflow Configuration template: substitute every
# rendered pin's placeholders from its fixture profile (its route line
# included), the Skill Bundle membership and both Workflows' limits, then
# delete the blocks of the Workflows the variant does not declare and every
# block marker.
render_coding_agent_workflow() {
  ca_variant "$3"
  script="$2.sed"
  {
    printf 's|{{OWNER}}|%s|g\n' "$PH_OWNER"
    printf 's|{{REPO}}|%s|g\n' "$PH_REPO"
    printf 's|{{BASE_BRANCH}}|%s|g\n' "$PH_BASE_BRANCH"
    printf 's|{{SELECTION_LABEL}}|%s|g\n' "$PH_SELECTION_LABEL"
    printf 's|{{LIMIT_COST_USD}}|%s|g\n' "$PH_LIMIT_COST_USD"
    printf 's|{{LIMIT_EFFECTIVE_TOKENS}}|%s|g\n' "$PH_LIMIT_EFFECTIVE_TOKENS"
    printf 's|{{LIMIT_TOOL_CALLS}}|%s|g\n' "$PH_LIMIT_TOOL_CALLS"
    printf 's|{{LIMIT_WALL_CLOCK_MINUTES}}|%s|g\n' "$PH_LIMIT_WALL_CLOCK_MINUTES"
    printf 's|{{PROCESS_LIMIT_COST_USD}}|%s|g\n' "$PH_PROCESS_LIMIT_COST_USD"
    printf 's|{{SELF_REVIEW_LIMIT_COST_USD}}|%s|g\n' "$PH_SELF_REVIEW_LIMIT_COST_USD"
    printf 's|{{TRIAGE_LIMIT_COST_USD}}|%s|g\n' "$PH_TRIAGE_LIMIT_COST_USD"
    printf 's|{{TRIAGE_LIMIT_EFFECTIVE_TOKENS}}|%s|g\n' "$PH_TRIAGE_LIMIT_EFFECTIVE_TOKENS"
    printf 's|{{TRIAGE_LIMIT_TOOL_CALLS}}|%s|g\n' "$PH_TRIAGE_LIMIT_TOOL_CALLS"
    printf 's|{{TRIAGE_LIMIT_WALL_CLOCK_MINUTES}}|%s|g\n' "$PH_TRIAGE_LIMIT_WALL_CLOCK_MINUTES"
    include=''
    for workflow in $CA_WORKFLOWS; do
      case $workflow in
        implement) include="$include, implement, tdd, code-review, codebase-design" ;;
        triage) include="$include, triage, grilling, domain-modeling" ;;
      esac
    done
    printf 's|{{SKILL_INCLUDE}}|%s|g\n' "${include#, }"
    if [ -n "$CA_MAIN" ]; then
      printf 's|{{HANDOFF_EFFECTIVE_TOKENS}}|%s|g\n' "$(ca_handoff_tokens)"
    fi
    for pin in main triage triage-advisor; do
      profile=$(pin_profile "$pin")
      [ -n "$profile" ] || continue
      case $pin in
        main) prefix=MAIN ;;
        triage) prefix=TRIAGE ;;
        triage-advisor) prefix=ADVISOR ;;
      esac
      for field in ROUTE MODEL ENDPOINT EFFORT API_KEY_ENV \
        CONTEXT_WINDOW_TOKENS CONTEXT_THRESHOLD_TOKENS OUTPUT_CAP_TOKENS \
        PRICE_INPUT PRICE_OUTPUT PRICE_CACHE_READ PRICE_CACHE_WRITE; do
        printf 's|{{%s_%s}}|%s|g\n' "$prefix" "$field" \
          "$(profile_value "$profile" "$field")"
      done
    done
    for workflow in implement triage; do
      case " $CA_WORKFLOWS " in
        *" $workflow "*) ;;
        *) printf '/^ *# workflow-%s-begin$/,/^ *# workflow-%s-end$/d\n' \
          "$workflow" "$workflow" ;;
      esac
    done
    printf '/^ *# workflow-implement-begin$/d\n'
    printf '/^ *# workflow-implement-end$/d\n'
    printf '/^ *# workflow-triage-begin$/d\n'
    printf '/^ *# workflow-triage-end$/d\n'
    instance_profile_markers
  } >"$script"
  sed -f "$script" "$1" >"$2"
  rm -f "$script"
}

# instance_profile_markers -- the sed commands for the `instance-profile-*`
# ranges of the Workflow Configuration and Dockerfile templates (call after
# ca_variant): an Instance-supplied profile (CA_PROFILE=1) keeps the range,
# any other variant deletes it, and the marker lines go either way.
instance_profile_markers() {
  if [ "$CA_PROFILE" != 1 ]; then
    printf '/^ *# instance-profile-begin$/,/^ *# instance-profile-end$/d\n'
  fi
  printf '/^ *# instance-profile-begin$/d\n'
  printf '/^ *# instance-profile-end$/d\n'
}

# render_coding_agent_dockerfile SRC DST VARIANT -- the coding-agent
# instance Dockerfile: the asset carries no placeholders (every path and
# flag is fixed by the adapter, and the declared Workflows arrive as the
# WORKFLOWS build argument from compose.yaml); only its `instance-profile-*`
# range is kept or deleted, as in workflow.yml.
render_coding_agent_dockerfile() {
  ca_variant "$3"
  instance_profile_markers >"$2.sed"
  sed -f "$2.sed" "$1" >"$2" ||
    fail 'coding-agent: cannot render the instance Dockerfile'
  rm -f "$2.sed"
}

# render_coding_agent_profile DIR VARIANT -- workflow/project-profile.yml
# for an Instance-supplied profile (CA_PROFILE=1) only: a schema-2 Project
# Profile in the upstream format (coding-agent
# docs/contract/v1-runtime-contract.md §7). The skill writes it from the
# target's gating CI checks; the check writes a Python/uv fixture whose
# toolchain the image's Supported Toolchain Matrix carries.
render_coding_agent_profile() {
  ca_variant "$2"
  [ "$CA_PROFILE" = 1 ] || return 0
  cat >"$1/workflow/project-profile.yml" <<'PROFILE' ||
# render-check: Instance-supplied Project Profile fixture (schema 2).
schema: 2
language: python
working_directory: "."
toolchain:
  python: "3.13"
  package_manager: uv
commands:
  bootstrap: uv sync --frozen
  test_all: uv run pytest -q --junit-xml={evidence_dir}/test_all.xml
  test_targeted: uv run pytest -q --junit-xml={evidence_dir}/test_targeted.xml {path}
evidence:
  format: junit-xml
  test_all: "{evidence_dir}/test_all.xml"
  test_targeted: "{evidence_dir}/test_targeted.xml"
checks:
  - name: lint
    command: uv run ruff check .
services: []
PROFILE
    fail 'coding-agent: cannot write workflow/project-profile.yml'
}

# render_coding_agent_prompts DIR VARIANT -- the prompt files the rendered
# workflow.yml references. `implement`'s come from the CODING_AGENT_REF
# checkout (step 3b of the skill), so the check writes stubs with their
# names: it only proves the layout the validation stats exists. `triage`'s
# are Forge assets the skill copies verbatim, so the check copies the real
# files.
render_coding_agent_prompts() {
  ca_variant "$2"
  mkdir -p "$1/workflow/prompts" ||
    fail 'coding-agent: cannot create workflow/prompts directory'
  for workflow in $CA_WORKFLOWS; do
    case $workflow in
      implement)
        for prompt in implement-policy.md handoff.md; do
          printf '# render-check: prompt stub for %s.\n' "$prompt" \
            >"$1/workflow/prompts/$prompt"
        done
        ;;
      triage)
        for prompt in triage-policy.md triage-advisor.md; do
          cp "$ASSETS_DIR/prompts/$prompt" "$1/workflow/prompts/$prompt" ||
            fail "coding-agent: cannot copy prompts/$prompt"
        done
        ;;
    esac
  done
}

# render_coding_agent_policy DIR -- stub skill-policy.json. The skill copies
# the reviewed reference policy verbatim from the CODING_AGENT_REF
# checkout's docker/deployment/ for the reference bundle, and otherwise
# drafts one with `agent draft-skill-policy` and writes only
# operator-approved decisions; Forge keeps no copy of its own, so the check
# only proves the layout the Worker expects exists. The stub is written
# after the config-validate run below: validation passes with the policy
# missing, and a stub must never stand in for the reviewed copy.
render_coding_agent_policy() {
  printf '{}\n' >"$1/workflow/skill-policy.json" ||
    fail 'coding-agent: cannot write workflow/skill-policy.json stub'
}

# check_coding_agent_validate DIR LABEL VARIANT -- secret-free `agent config
# validate` against the rendered coding-agent workflow, once per declared
# Workflow, with no environment set. Runs only when the `agent` CLI is on
# PATH: CI has no coding-agent installed, so there the check records the
# skip and passes (see the header). Install the CLI at the pinned ref or
# build the image and re-run locally to cover it.
check_coding_agent_validate() {
  ca_variant "$3"
  if ! agent_bin=$(command -v agent); then
    info "$2: SKIP secret-free config validate (no agent CLI on PATH; CI has no coding-agent installed)"
    return 0
  fi
  for workflow in $CA_WORKFLOWS; do
    info "checking $2 secret-free config validate --workflow $workflow"
    validate_output=$(cd "$1" && env -i "$agent_bin" config validate \
      --config ./workflow/workflow.yml --workflow "$workflow" 2>&1) || {
      printf '%s\n' "$validate_output" >&2
      fail "$2: secret-free 'agent config validate --workflow $workflow' failed"
    }
    printf '%s\n' "$validate_output"
    # The "no target.profile" notice belongs only to a Workflow that needs
    # a Validation Contract and has no target.profile (coding-agent ADR
    # 0037). With target.profile the file is checked here instead.
    if [ "$CA_PROFILE" != 1 ] &&
      workflow_needs_contract "$(cat "$1/workflow/workflow.yml")" "$workflow"; then
      assert_contains "$validate_output" 'no target.profile' \
        "$2: config validate --workflow $workflow prints no 'no target.profile' notice"
    else
      assert_not_contains "$validate_output" 'no target.profile' \
        "$2: config validate --workflow $workflow prints the 'no target.profile' notice"
    fi
  done
}

# render_coding_agent DIR VARIANT -- one scratch coding-agent instance:
# compose.yaml (plus the gateway network overlay when a Worker uses a
# gateway pin), Dockerfile, .env/.env.example, workflow/workflow.yml, the
# prompt files, the Instance-supplied profile (profile variant only) and
# the policy stub (written after the secret-free validate
# run, which needs no policy). VARIANT is one of ca_variant's.
render_coding_agent() {
  ca_variant "$2"
  render_coding_agent_compose \
    "$ASSETS_DIR/compose.coding-agent.yaml.template" "$1/compose.yaml" "$2"
  render_coding_agent_dockerfile \
    "$ASSETS_DIR/Dockerfile.coding-agent.template" "$1/Dockerfile" "$2"
  render_coding_agent_env "$ASSETS_DIR/env.coding-agent.example.template" \
    "$1/.env.example" "$2"
  cp "$1/.env.example" "$1/.env"
  if grep -qE '^COMPOSE_FILE=' "$1/.env"; then
    render_coding_agent_overlay \
      "$ASSETS_DIR/compose.coding-agent.litellm.yaml.template" \
      "$1/compose.coding-agent.litellm.yaml" "$2"
  fi
  mkdir -p "$1/workflow" ||
    fail 'coding-agent: cannot create workflow directory'
  render_coding_agent_workflow \
    "$ASSETS_DIR/workflow.coding-agent.yml.template" "$1/workflow/workflow.yml" "$2"
  render_coding_agent_prompts "$1" "$2"
  render_coding_agent_profile "$1" "$2"
  check_coding_agent_validate "$1" "coding-agent $2" "$2"
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
  coding_agent_triage_dir="$WORK_ROOT/agent-triage-$PH_CODING_AGENT_SHORT_NAME"
  coding_agent_pool_dir="$WORK_ROOT/agent-pool-$PH_CODING_AGENT_SHORT_NAME"
  coding_agent_profile_dir="$WORK_ROOT/agent-profile-$PH_CODING_AGENT_SHORT_NAME"
  mkdir -p "$plain_dir" "$litellm_dir" "$contract_dir" \
    "$contract_pool_dir" "$coding_agent_dir" "$coding_agent_gateway_dir" \
    "$coding_agent_triage_dir" "$coding_agent_pool_dir" \
    "$coding_agent_profile_dir" ||
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
  info 'rendering coding-agent triage instance'
  render_coding_agent "$coding_agent_triage_dir" triage
  info 'rendering coding-agent two-Workflow Pool instance'
  render_coding_agent "$coding_agent_pool_dir" pool
  info 'rendering coding-agent Instance-supplied profile instance'
  render_coding_agent "$coding_agent_profile_dir" profile

  # Forge never bakes discovery labels into the image; the legacy role image
  # label belongs to simple-coding-agent's own discovery and stays.
  assert_no_agent_operator "$ASSETS_DIR/Dockerfile.template" \
    'Dockerfile template mentions agent-operator'
  if ! grep -qF 'LABEL io.github.lbacik.simple-coding-agent.role="agent"' \
    "$ASSETS_DIR/Dockerfile.template"; then
    fail 'Dockerfile template lost the legacy role image label'
  fi

  # The coding-agent template fixes no project name (the directory is the
  # project) and renders at most `worker` and the marked `worker-2`, never
  # an open-ended <n> worker (manage-pool adds further Workers by hand).
  if grep -qE '^name:' "$ASSETS_DIR/compose.coding-agent.yaml.template"; then
    fail 'compose.coding-agent.yaml.template sets a project name (the directory is the project)'
  fi
  if grep -qF '<n>' "$ASSETS_DIR/compose.coding-agent.yaml.template"; then
    fail 'compose.coding-agent.yaml.template renders an open-ended <n> worker (create-agent renders worker and worker-2 only)'
  fi
  if grep -qF 'PROFILE_PATH' "$ASSETS_DIR/env.coding-agent.example.template"; then
    fail 'env.coding-agent.example.template sets PROFILE_PATH (no simple-coding-agent profile on this backend)'
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
  # The coding-agent gateway overlay attaches only Worker services (the one-off
  # `agent` seat is not a Managed Instance) and fixes no project name; the
  # gateway network name always comes from .env, never hard-coded.
  if grep -qE '^name:' "$ASSETS_DIR/compose.coding-agent.litellm.yaml.template"; then
    fail 'compose.coding-agent.litellm.yaml.template sets a project name (the directory is the project)'
  fi
  if grep -qE '^  agent:' "$ASSETS_DIR/compose.coding-agent.litellm.yaml.template"; then
    fail 'compose.coding-agent.litellm.yaml.template attaches the agent seat (only Worker services join the gateway network)'
  fi
  if grep -qE '^  validate:' "$ASSETS_DIR/compose.coding-agent.litellm.yaml.template"; then
    fail 'compose.coding-agent.litellm.yaml.template attaches the validate seat (only Worker services join the gateway network)'
  fi
  for service in worker worker-2; do
    if ! grep -qE "^  $service:" "$ASSETS_DIR/compose.coding-agent.litellm.yaml.template"; then
      fail "compose.coding-agent.litellm.yaml.template misses the $service service"
    fi
  done
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

  # The triage policy prompts are rendered verbatim: no placeholder may
  # survive in the assets themselves.
  for prompt in triage-policy.md triage-advisor.md; do
    if grep -qF '{{' "$ASSETS_DIR/prompts/$prompt"; then
      fail "prompts/$prompt carries a {{PLACEHOLDER}} (it is copied verbatim)"
    fi
  done

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
  assert_no_placeholders "$coding_agent_triage_dir" 'coding-agent triage'
  assert_no_placeholders "$coding_agent_pool_dir" 'coding-agent pool'
  assert_no_placeholders "$coding_agent_profile_dir" 'coding-agent profile'
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
  assert_no_secrets "$coding_agent_triage_dir/.env" 'coding-agent triage'
  assert_no_secrets "$coding_agent_triage_dir/.env.example" 'coding-agent triage'
  assert_no_secrets "$coding_agent_pool_dir/.env" 'coding-agent pool'
  assert_no_secrets "$coding_agent_pool_dir/.env.example" 'coding-agent pool'
  assert_no_secrets "$coding_agent_profile_dir/.env" 'coding-agent profile'
  assert_no_secrets "$coding_agent_profile_dir/.env.example" 'coding-agent profile'
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
  check_coding_agent_instance "$coding_agent_triage_dir" 'coding-agent triage' triage
  check_coding_agent_instance "$coding_agent_pool_dir" 'coding-agent pool' pool
  check_coding_agent_instance "$coding_agent_profile_dir" 'coding-agent profile' profile

  info 'PASS: all variants render to a valid Compose model with no secrets'
}

main
