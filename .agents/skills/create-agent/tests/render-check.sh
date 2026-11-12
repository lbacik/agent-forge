#!/bin/sh
# render-check.sh -- prove the create-agent templates render to a valid Compose model.
#
# Renders the simple-coding-agent templates (compose.yaml and
# compose.litellm.yaml, .env/.env.example from the env example template, and
# the Dockerfile) with placeholder values and no secrets into scratch
# directories, then runs `docker compose config` on the plain and the LiteLLM
# variants. Exits non-zero when a rendered result is not a valid Compose model.
#
# Usage (from anywhere in this repository):
#
#   .agents/skills/create-agent/tests/render-check.sh
#
# The CI workflow (.github/workflows/render-check.yml) runs this same script on
# every pull request. To add an assertion about the rendered Compose model (for
# example "service X carries label Y"), extend the assertions in check_instance
# below; the workflow file needs no changes.
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

# render_compose SRC DST -- compose.yaml for a single-Worker (N=1) instance:
# substitute placeholders, then drop the Worker id block (no Worker id on N=1
# without a shared login) and the example agent-<n> stanza with its volume, as
# SKILL.md instructs for N=1.
render_compose() {
  sed -e "s|{{OWNER}}|$PH_OWNER|g" \
    -e "s|{{REPO}}|$PH_REPO|g" \
    -e "s|{{SHORT_NAME}}|$PH_SHORT_NAME|g" \
    -e 's|{{MODEL_SHELL_ENV}}|CI_PLACEHOLDER: "1"|g' \
    "$1" |
    sed -e '/^  # Worker <n>:/,/^volumes:$/ { /^volumes:$/!d; }' \
      -e '/^    environment:$/,/^      GIT_COMMITTER_NAME:/d' \
      -e '/^  # One per further Worker: data_2\.\.N\.$/d' \
      -e '/^  data_<n>:$/d' >"$2"
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

# check_instance DIR LABEL -- `docker compose config` must accept the rendered
# directory, and the resulting model must carry the expected shape.
#
# Add new model assertions here (for example "service X carries label Y");
# the CI workflow needs no changes.
check_instance() {
  info "checking $2 instance"
  # Run hermetically: shell variables take precedence over the fixture's .env
  # in Compose interpolation, so an exported COMPOSE_FILE, GATEWAY_NETWORK or
  # credential from the caller's shell would rewire the fixture and could leak
  # a real secret into the check. `config` is client-side and needs no daemon,
  # so PATH and HOME suffice.
  if ! config_output=$(cd "$1" && env -i PATH="$PATH" HOME="$HOME" docker compose config); then
    fail "$2: 'docker compose config' failed"
  fi
  assert_contains "$config_output" "simple-coding-agent:$PH_SHORT_NAME" \
    "$2: image tag missing from the Compose model"
  assert_contains "$config_output" '  agent:' \
    "$2: agent service missing from the Compose model"
  assert_contains "$config_output" 'init: true' \
    "$2: init missing from the Compose model"
  assert_contains "$config_output" 'agent_data' \
    "$2: agent_data volume missing from the Compose model"
  assert_not_contains "$config_output" '<n>' \
    "$2: unrendered <n> worker reached the Compose model"
  assert_not_contains "$config_output" 'WORKER_ID' \
    "$2: N=1 instance without a shared login must not set a Worker id"
  if [ "$2" = 'litellm' ]; then
    assert_contains "$config_output" "$PH_GATEWAY_NETWORK" \
      "$2: gateway network missing from the Compose model"
    assert_contains "$config_output" 'external: true' \
      "$2: gateway network is not external in the Compose model"
  fi
}

render_plain() {
  render_compose "$ASSETS_DIR/compose.yaml.template" "$1/compose.yaml"
  render_env "$ASSETS_DIR/env.example.template" "$1/.env.example"
  cp "$1/.env.example" "$1/.env"
  render_dockerfile "$ASSETS_DIR/Dockerfile.template" "$1/Dockerfile"
}

render_litellm() {
  render_plain "$1"
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
  mkdir -p "$plain_dir" "$litellm_dir" ||
    fail 'cannot create scratch instance directories'

  info 'rendering plain instance'
  render_plain "$plain_dir"
  info 'rendering litellm instance'
  render_litellm "$litellm_dir"

  assert_no_placeholders "$plain_dir" 'plain'
  assert_no_placeholders "$litellm_dir" 'litellm'
  assert_no_secrets "$plain_dir/.env" 'plain'
  assert_no_secrets "$plain_dir/.env.example" 'plain'
  assert_no_secrets "$litellm_dir/.env" 'litellm'
  assert_no_secrets "$litellm_dir/.env.example" 'litellm'

  check_instance "$plain_dir" 'plain'
  check_instance "$litellm_dir" 'litellm'

  info 'PASS: both variants render to a valid Compose model with no secrets'
}

main
