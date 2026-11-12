#!/bin/sh
# contract-helpers.sh -- pin the contract-path locate-agent against agentfleet.
#
# Runs locate-agent.sh for a labelled container with `agentfleet` backed by
# the contract suite's fixtures (loaded from the pinned tag checkout, never
# copied) behind the same stubbed-Docker mechanism as legacy-helpers.sh.
# Covers: the agentfleet prerequisite (missing or wrong major stops with the
# install command and reads no container files), path selection (labelled
# through agentfleet, unlabelled legacy unchanged), the Status Snapshot
# summary (identity plus every section with observed_at, Figures with unit
# and basis, unknown as unavailable/not_applicable never 0, native outcomes
# as the backend labels them, no private state files), --context reaching
# agentfleet, and classification of every fixture class (success, rejection,
# unsupported, ambiguous outcome, contract mismatch with no legacy fallback,
# malformed stdout).
#
# Usage (from anywhere in this repository):
#
#   .agents/skills/debug-agent/tests/contract-helpers.sh
#
# Hermeticity: HOME points at a scratch dir, AGENT_INSTANCES_DIR at a scratch
# fixture, PATH starts with tests/stub/bin (fake docker plus a gh that fails
# if ever called). CONTRACT_FIXTURES_DIR points at the fixtures of the pinned
# agent-operator-contract tag (the installed package matching CONTRACT_TAG,
# or a checkout via CONTRACT_CHECKOUT); no fixture is copied into this repo.
# Shell internals are not tested: only exit status, stdout/stderr content
# (via grep for the promised sections and error codes) and the stub's argv
# log (no `docker cp`, no legacy `agentctl status` on the contract path).

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
ROOT_DIR=$(cd "$SCRIPT_DIR/../../../.." && pwd) || exit 1
SCRIPTS_DIR="$ROOT_DIR/.agents/skills/debug-agent/scripts"
SKILLS_DIR="$ROOT_DIR/.agents/skills"
STUB_BIN="$SCRIPT_DIR/stub/bin"
STUB_LIB="$SCRIPT_DIR/stub/lib"

WORK_ROOT=""
T_HOME=""
T_INSTANCES=""
ARGV_LOG=""
ERROR_LOG=""
FIXDIR=""
CODE=0

info() {
  printf 'contract-helpers: %s\n' "$*"
}

fail() {
  printf 'contract-helpers: FAIL: %s\n' "$*" >&2
  exit 1
}

setup_fixture() {
  T_INSTANCES="$WORK_ROOT/instances"
  T_HOME="$WORK_ROOT/home"
  ARGV_LOG="$WORK_ROOT/argv.log"
  ERROR_LOG="$WORK_ROOT/stub-errors.log"
  : >"$ARGV_LOG"
  : >"$ERROR_LOG"

  mkdir -p "$T_INSTANCES/agent-foo" "$T_INSTANCES/agent-duo" "$T_INSTANCES/agent-plain"
  cat >"$T_INSTANCES/agent-foo/compose.yaml" <<'EOF'
services:
  agent:
    image: foo-image:latest
    labels:
      io.github.lbacik.agent-operator.contract: "1"
      io.github.lbacik.agent-operator.instance: "foo"
      io.github.lbacik.agent-operator.exec-user: "agent"
      io.github.lbacik.agent-operator.backend: "simple-coding-agent"
EOF
  cat >"$T_INSTANCES/agent-duo/compose.yaml" <<'EOF'
services:
  agent:
    image: duo-image:latest
    labels:
      io.github.lbacik.agent-operator.contract: "1"
      io.github.lbacik.agent-operator.instance: "duo"
      io.github.lbacik.agent-operator.exec-user: "agent"
      io.github.lbacik.agent-operator.backend: "simple-coding-agent"
  agent-2:
    image: duo-image:latest
    labels:
      io.github.lbacik.agent-operator.contract: "1"
      io.github.lbacik.agent-operator.instance: "duo-2"
      io.github.lbacik.agent-operator.exec-user: "agent"
      io.github.lbacik.agent-operator.backend: "simple-coding-agent"
EOF
  cat >"$T_INSTANCES/agent-plain/compose.yaml" <<'EOF'
services:
  agent:
    image: plain-image:latest
EOF
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-foo/.env"
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-duo/.env"
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-plain/.env"
  mkdir -p "$T_HOME/OrbStack/docker/volumes/plain_agent_data/state"
  printf '{"consecutive_errors":0}\n' >"$T_HOME/OrbStack/docker/volumes/plain_agent_data/state/consecutive_errors.json"

  SCENE="$WORK_ROOT/scene"
  mkdir -p "$SCENE/agent-foo" "$SCENE/agent-duo" "$SCENE/agent-plain"
  printf 'agent-foo-agent-1\n' >"$SCENE/agent-foo/ps-agent.txt"
  printf 'agent-foo-agent-1\n' >"$SCENE/agent-foo/ps-PROJECT.txt"
  printf 'running|0|2026-11-10T10:00:00Z|foo-image:latest\n' >"$SCENE/agent-foo/inspect-agent-foo-agent-1.txt"
  printf '1\n' >"$SCENE/agent-foo/contract-label-agent-foo-agent-1.txt"
  printf 'agent-duo-agent-1\n' >"$SCENE/agent-duo/ps-agent.txt"
  printf 'agent-duo-agent-2-1\n' >"$SCENE/agent-duo/ps-agent-2.txt"
  printf 'agent-duo-agent-1\n' >"$SCENE/agent-duo/ps-PROJECT.txt"
  printf 'running|0|2026-11-10T10:00:00Z|duo-image:latest\n' >"$SCENE/agent-duo/inspect-agent-duo-agent-1.txt"
  printf 'running|0|2026-11-10T10:00:00Z|duo-image:latest\n' >"$SCENE/agent-duo/inspect-agent-duo-agent-2-1.txt"
  printf '1\n' >"$SCENE/agent-duo/contract-label-agent-duo-agent-1.txt"
  printf '1\n' >"$SCENE/agent-duo/contract-label-agent-duo-agent-2-1.txt"
  printf 'agent-plain-agent-1\n' >"$SCENE/agent-plain/ps-agent.txt"
  printf 'agent-plain-agent-1\n' >"$SCENE/agent-plain/ps-PROJECT.txt"
  printf 'running|0|2026-11-10T10:00:00Z|plain-image:latest\n' >"$SCENE/agent-plain/inspect-agent-plain-agent-1.txt"
  cat >"$SCENE/fleet.json" <<'EOF'
{"containers": [
  {"id": "cid-foo-1", "name": "foo", "backend": "simple-coding-agent", "contract": "1", "exec_user": "agent", "state": "running"},
  {"id": "cid-duo-1", "name": "duo", "backend": "simple-coding-agent", "contract": "1", "exec_user": "agent", "state": "running"},
  {"id": "cid-duo-2", "name": "duo-2", "backend": "simple-coding-agent", "contract": "1", "exec_user": "agent", "state": "running"}
]}
EOF
}

resolve_fixtures() {
  _tag=$(sed -n 's/^CONTRACT_TAG=//p' "$SCRIPTS_DIR/lib/contract.sh" | head -n 1)
  [ -n "$_tag" ] || fail "cannot read CONTRACT_TAG from lib/contract.sh"
  info "pinned contract tag: $_tag"
  if [ -n "${CONTRACT_CHECKOUT:-}" ] && [ -d "$CONTRACT_CHECKOUT/src/agent_operator_contract/fixtures/agentctl" ]; then
    FIXDIR="$CONTRACT_CHECKOUT/src/agent_operator_contract/fixtures/agentctl"
    info "using fixtures from CONTRACT_CHECKOUT: $FIXDIR"
  else
    _pkgdir=$(python3 -c 'import os; from agent_operator_contract import documents; print(os.path.join(os.path.dirname(documents.__file__), "fixtures", "agentctl"))' 2>/dev/null || true)
    if [ -n "$_pkgdir" ] && [ -f "$_pkgdir/identity.json" ]; then
      _ver=$(python3 -c 'import importlib.metadata as m; print(m.version("agent-operator-contract"))' 2>/dev/null || true)
      [ "v$_ver" = "$_tag" ] || fail "installed agent-operator-contract $_ver does not match pinned $_tag"
      FIXDIR="$_pkgdir"
      info "using fixtures from installed package $_ver: $FIXDIR"
    else
      _co="$WORK_ROOT/contract-tag"
      info "cloning pinned tag $_tag for fixtures"
      git clone --depth 1 --branch "$_tag" https://github.com/lbacik/agent-operator-contract "$_co" >&2 || fail "cannot clone contract tag $_tag"
      FIXDIR="$_co/src/agent_operator_contract/fixtures/agentctl"
    fi
  fi
  [ -f "$FIXDIR/identity.json" ] || fail "fixtures missing identity.json in $FIXDIR"
  [ -f "$FIXDIR/index.json" ] || fail "fixtures missing index.json in $FIXDIR"
}

run_locate() {
  : >"$ARGV_LOG"
  : >"$ERROR_LOG"
  set +e
  "$SCRIPTS_DIR/locate-agent.sh" "$@" >"$WORK_ROOT/out.txt" 2>"$WORK_ROOT/err.txt"
  CODE=$?
  set -e
  [ ! -s "$ERROR_LOG" ] || fail "stub errors during locate $*: $(cat "$ERROR_LOG")"
}

assert_contains() {
  grep -q "$2" "$1" || fail "$3: expected '$2' in $(cat "$1")"
}

assert_not_contains() {
  if grep -q "$2" "$1"; then
    fail "$3: unexpected '$2' in $(cat "$1")"
  fi
}

assert_no_file_reads() {
  if grep -q 'docker cp' "$ARGV_LOG"; then
    fail "$1: contract path ran 'docker cp' (a file read)"
  fi
  if grep -q 'agentctl status' "$ARGV_LOG" && ! grep -q -- '--contract' "$ARGV_LOG"; then
    fail "$1: contract path ran legacy 'agentctl status'"
  fi
}

check_success_snapshot() {
  _case=$1
  [ "$CODE" -eq 0 ] || fail "$_case: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "agentfleet_identity:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "backend:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "status_snapshot:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "instance: .*observed_at" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "startup_check:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "last_halt:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "intake: .*observed_at" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "pending_stop:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "stop_plan:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "priority:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "current_attempt: .*observed_at" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "native_phase" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "budget:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "basis" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "last_finished:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "managed_instance:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "forge_instance:" "$_case"
  assert_not_contains "$WORK_ROOT/out.txt" "state_files:" "$_case (no private state files on the contract path)"
  assert_no_file_reads "$_case"
  info "ok: $_case"
}

main() {
  WORK_ROOT=$(mktemp -d) || fail "cannot create a scratch directory"
  trap 'rm -rf "$WORK_ROOT"' EXIT INT TERM

  setup_fixture

  export HOME="$T_HOME"
  export AGENT_INSTANCES_DIR="$T_INSTANCES"
  export STUB_ARGV_LOG="$ARGV_LOG"
  export STUB_ERROR_LOG="$ERROR_LOG"
  export STUB_SCENARIO_DIR="$WORK_ROOT/scene"
  export STUB_VOLUMES_ROOT="$T_HOME/OrbStack/docker/volumes"
  export STUB_PROJECTS="agent-foo agent-duo agent-plain"
  export STUB_LIB
  export PATH="$STUB_BIN:$PATH"

  [ "$(command -v docker)" = "$STUB_BIN/docker" ] || fail "stub docker is not first on PATH"

  resolve_fixtures
  export CONTRACT_FIXTURES_DIR="$FIXDIR"

  command -v agentfleet >/dev/null 2>&1 || fail "agentfleet is not installed; install from the pinned tag"
  _ver=$(agentfleet --version 2>/dev/null || true)
  info "agentfleet version: $_ver"

  # Success: simple-coding-agent backend with raw budget Figures.
  export CONTRACT_IDENTITY_FIXTURE=identity.json
  export CONTRACT_STATUS_FIXTURE=status-simple-coding-agent.json
  run_locate --context rpi5 foo
  check_success_snapshot "success-simple-coding-agent"
  assert_contains "$WORK_ROOT/out.txt" "enforced: raw" "success-simple-coding-agent"
  assert_contains "$WORK_ROOT/out.txt" "raw .*tokens" "success-simple-coding-agent"

  # Success: coding-agent backend with unavailable/not_applicable Figures, never 0.
  export CONTRACT_STATUS_FIXTURE=status-active.json
  run_locate --context rpi5 foo
  check_success_snapshot "success-figures"
  assert_contains "$WORK_ROOT/out.txt" "unavailable" "success-figures"
  assert_contains "$WORK_ROOT/out.txt" "not_applicable" "success-figures"
  assert_contains "$WORK_ROOT/out.txt" "native delivered" "success-figures"

  # Per-Worker: the second Worker resolves to its own Managed Instance name.
  run_locate --context rpi5 --worker 2 duo
  check_success_snapshot "per-worker-duo-2"
  assert_contains "$WORK_ROOT/out.txt" "managed_instance: duo-2" "per-worker-duo-2"

  # --context reaches agentfleet through the Docker context mechanism.
  if ! grep -q 'CTX=rpi5 docker .*--contract' "$ARGV_LOG"; then
    fail "--context rpi5 did not reach agentfleet (no CTX=rpi5 contract call)"
  fi
  info "ok: --context reaches agentfleet"

  # Rejection is reported, never retried through the legacy grammar.
  export CONTRACT_STATUS_FIXTURE=rejected.json
  run_locate --context rpi5 foo
  [ "$CODE" -eq 1 ] || fail "rejection: exit $CODE, want 1"
  assert_contains "$WORK_ROOT/err.txt" "rejected" "rejection"
  assert_no_file_reads "rejection"
  info "ok: rejection"

  # Unsupported is reported, never retried through the legacy grammar.
  export CONTRACT_STATUS_FIXTURE=unsupported.json
  run_locate --context rpi5 foo
  [ "$CODE" -eq 3 ] || fail "unsupported: exit $CODE, want 3"
  if ! grep -q 'unsupported' "$WORK_ROOT/err.txt"; then
    if ! grep -q 'unsupported' "$WORK_ROOT/out.txt"; then
      fail "unsupported: expected 'unsupported' in output"
    fi
  fi
  assert_no_file_reads "unsupported"
  info "ok: unsupported"

  # Ambiguous outcome (agent_unreachable) is reported, never retried with a new ID.
  export CONTRACT_STATUS_FIXTURE=agent-unreachable.json
  run_locate --context rpi5 foo
  [ "$CODE" -eq 6 ] || fail "ambiguous: exit $CODE, want 6"
  if ! grep -q 'agent_unreachable' "$WORK_ROOT/err.txt"; then
    if ! grep -q 'agent_unreachable' "$WORK_ROOT/out.txt"; then
      fail "ambiguous: expected 'agent_unreachable' in output"
    fi
  fi
  assert_no_file_reads "ambiguous"
  info "ok: ambiguous outcome"

  # Contract mismatch is reported, never retried through the legacy grammar.
  export CONTRACT_STATUS_FIXTURE=contract-mismatch.json
  run_locate --context rpi5 foo
  [ "$CODE" -eq 4 ] || fail "contract-mismatch: exit $CODE, want 4"
  if ! grep -q 'contract_mismatch' "$WORK_ROOT/err.txt"; then
    if ! grep -q 'contract_mismatch' "$WORK_ROOT/out.txt"; then
      fail "contract-mismatch: expected 'contract_mismatch' in output"
    fi
  fi
  assert_no_file_reads "contract-mismatch"
  info "ok: contract mismatch (no legacy fallback)"

  # Malformed stdout is reported, never parsed as success.
  export CONTRACT_STATUS_FIXTURE=malformed-non-json.json
  run_locate --context rpi5 foo
  [ "$CODE" -ne 0 ] || fail "malformed: exit 0, want non-zero"
  assert_no_file_reads "malformed"
  info "ok: malformed stdout (exit $CODE)"

  # Missing agentfleet stops with the install command and reads no files.
  (
    PATH="$STUB_BIN:/usr/bin:/bin"
    export PATH
    command -v agentfleet >/dev/null 2>&1 && fail "missing-agentfleet: agentfleet unexpectedly on PATH"
    export CONTRACT_STATUS_FIXTURE=status-active.json
    run_locate --context rpi5 foo
    [ "$CODE" -ne 0 ] || fail "missing-agentfleet: exit 0, want non-zero"
    assert_contains "$WORK_ROOT/err.txt" "agentfleet is not installed" "missing-agentfleet"
    assert_contains "$WORK_ROOT/err.txt" "v1.0.4" "missing-agentfleet install command pins the tag"
    assert_no_file_reads "missing-agentfleet"
    info "ok: missing agentfleet stops with the install command"
  )

  # Wrong contract major stops with the install command and reads no files.
  (
    _faked="$WORK_ROOT/fakebin"
    mkdir -p "$_faked"
    printf '#!/bin/sh\nif [ "${1:-}" = "--version" ]; then echo "agentfleet 9.9.9 (contract major 9)"; exit 0; fi\necho "agentfleet: unexpected call" >&2; exit 1\n' >"$_faked/agentfleet"
    chmod +x "$_faked/agentfleet"
    PATH="$_faked:$STUB_BIN:/usr/bin:/bin"
    export PATH
    export CONTRACT_STATUS_FIXTURE=status-active.json
    run_locate --context rpi5 foo
    [ "$CODE" -ne 0 ] || fail "wrong-major: exit 0, want non-zero"
    assert_contains "$WORK_ROOT/err.txt" "unexpected contract major" "wrong-major"
    assert_contains "$WORK_ROOT/err.txt" "v1.0.4" "wrong-major install command pins the tag"
    assert_no_file_reads "wrong-major"
    info "ok: wrong contract major stops with the install command"
  )

  # Unlabelled containers stay on the legacy path with today's output.
  unset CONTRACT_STATUS_FIXTURE
  unset CONTRACT_IDENTITY_FIXTURE
  run_locate --context rpi5 plain
  [ "$CODE" -eq 0 ] || fail "unlabelled: exit $CODE"
  assert_contains "$WORK_ROOT/out.txt" "state_files:" "unlabelled legacy output"
  assert_not_contains "$WORK_ROOT/out.txt" "agentfleet_identity:" "unlabelled must not take the contract path"
  info "ok: unlabelled stays on the legacy path"

  info "PASS: contract-path locate-agent behaves as specified (fixtures from the pinned tag, no copies)"
}

main
