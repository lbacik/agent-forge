#!/bin/sh
# render-check.sh -- prove the create-agent templates render to a valid Compose model.
#
# Renders the simple-coding-agent templates (compose.yaml and
# compose.litellm.yaml, .env/.env.example from the env example template, and
# the Dockerfile) with placeholder values and no secrets into scratch
# directories, then runs `docker compose config` on the plain, the LiteLLM,
# the contract-labels and the contract-labels Pool variants. Exits non-zero
# when a rendered result is not a valid Compose model.
#
# The contract-labels variants simulate an AGENT_SRC_REF that speaks the
# operator contract (no release does yet — see the create-agent skill,
# "Contract discovery labels"): the labels blocks the template carries are
# kept instead of deleted. The plain and LiteLLM variants render without
# labels and must stay byte-identical in the Compose model to today's layout.
#
# Usage (from anywhere in this repository):
#
#   .agents/skills/create-agent/tests/render-check.sh
#
# The CI workflow (.github/workflows/render-check.yml) runs this same script on
# every pull request. To add an assertion about the rendered Compose model (for
# example "service X carries label Y"), extend the assertions in check_instance
# or check_contract_instance below; the workflow file needs no changes.
#
# Requires Docker with Compose v2.17 or newer (the template uses
# additional_contexts).

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
ROOT_DIR=$(cd "$SCRIPT_DIR/../../../.." && pwd) || exit 1
ASSETS_DIR="$ROOT_DIR/.agents/skills/create-agent/assets"

# Placeholder values. Credentials stay empty on purpose: the check must pass
# with no secret present.
PH_OWNER=testowner
PH_REPO=testrepo
PH_SHORT_NAME=testrepo
PH_AGENT_SRC_REF=main
PH_MAX_BUDGET_USD=20
PH_MAX_TURNS=120
PH_MAX_BUDGET_TOKENS=4000000
PH_SOFT_THRESHOLD_PERCENTAGE=0.3
PH_NODE_MAJOR=22
PH_GATEWAY_NETWORK=test-gateway-net

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
# ref: delete them, so the model is unchanged from today's layout). No
# release speaks the contract yet; the `labels` mode simulates one.
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
  for key in GITHUB_TOKEN META_API_KEY MODEL_API_KEY; do
    value=$(grep -E "^${key}=" "$1" | cut -d '=' -f 2-)
    if [ -n "$value" ]; then
      fail "$2: $1 sets $key (the check runs with no secrets)"
    fi
  done
}

# compose_config DIR -- print `docker compose config` for the rendered
# directory. Runs hermetically: shell variables take precedence over the
# fixture's .env in Compose interpolation, so an exported COMPOSE_FILE,
# GATEWAY_NETWORK or credential from the caller's shell would rewire the
# fixture and could leak a real secret into the check. `config` is
# client-side and needs no daemon, so PATH and HOME suffice.
compose_config() {
  (cd "$1" && env -i PATH="$PATH" HOME="$HOME" docker compose config)
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
  mkdir -p "$plain_dir" "$litellm_dir" "$contract_dir" \
    "$contract_pool_dir" ||
    fail 'cannot create scratch instance directories'

  info 'rendering plain instance'
  render_instance "$plain_dir" no-labels 1
  info 'rendering litellm instance'
  render_litellm "$litellm_dir"
  info 'rendering contract-labels instance'
  render_instance "$contract_dir" labels 1
  info 'rendering contract-labels Pool instance'
  render_instance "$contract_pool_dir" labels 2

  # Forge never bakes discovery labels into the image; the legacy role image
  # label belongs to simple-coding-agent's own discovery and stays.
  assert_no_agent_operator "$ASSETS_DIR/Dockerfile.template" \
    'Dockerfile template mentions agent-operator'
  if ! grep -qF 'LABEL io.github.lbacik.simple-coding-agent.role="agent"' \
    "$ASSETS_DIR/Dockerfile.template"; then
    fail 'Dockerfile template lost the legacy role image label'
  fi

  assert_no_placeholders "$plain_dir" 'plain'
  assert_no_placeholders "$litellm_dir" 'litellm'
  assert_no_placeholders "$contract_dir" 'contract'
  assert_no_placeholders "$contract_pool_dir" 'contract-pool'
  assert_no_secrets "$plain_dir/.env" 'plain'
  assert_no_secrets "$plain_dir/.env.example" 'plain'
  assert_no_secrets "$litellm_dir/.env" 'litellm'
  assert_no_secrets "$litellm_dir/.env.example" 'litellm'
  assert_no_secrets "$contract_dir/.env" 'contract'
  assert_no_secrets "$contract_dir/.env.example" 'contract'
  assert_no_secrets "$contract_pool_dir/.env" 'contract-pool'
  assert_no_secrets "$contract_pool_dir/.env.example" 'contract-pool'
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

  info 'PASS: all variants render to a valid Compose model with no secrets'
}

main
