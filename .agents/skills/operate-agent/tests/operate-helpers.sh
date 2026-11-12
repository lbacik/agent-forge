#!/bin/sh
# operate-helpers.sh -- pin the operate-agent helper against agentfleet.
#
# Runs operate.sh for a labelled container with `agentfleet` backed by the
# contract suite's fixtures (loaded from the pinned tag checkout, never
# copied) behind the same stubbed-Docker mechanism as the debug-agent suites,
# plus the legacy agentctl path for an unlabelled container. Covers the
# ticket's consumer classes: success (with `accepted` reported distinctly
# from the final states), rejection, `unsupported`, ambiguous outcome (the
# request ID is surfaced and followed up with `command` under the same ID,
# never a new ID), contract mismatch with no legacy fallback, malformed
# stdout, an unadvertised operation refused before submission with the
# advertised capabilities listed, and the legacy stop/command argv.
#
# Every contract mutation the helper issues carries --expect-repo and an
# explicit --request-id (asserted on the stub's argv log); the follow-up
# `command` read reuses the same request ID.
#
# Usage (from anywhere in this repository):
#
#   .agents/skills/operate-agent/tests/operate-helpers.sh
#
# Hermeticity: HOME points at a scratch dir, AGENT_INSTANCES_DIR at a scratch
# fixture, PATH starts with the debug-agent tests/stub/bin (fake docker plus
# a gh that fails if ever called). CONTRACT_FIXTURES_DIR points at the
# fixtures of the pinned agent-operator-contract tag (the installed package
# matching CONTRACT_TAG, or a checkout via CONTRACT_CHECKOUT); no fixture is
# copied into this repo. Shell internals are not tested: only exit status,
# stdout/stderr content (via grep) and the stub's argv log (no `docker cp`,
# no legacy `agentctl status` on the contract path, one request ID per
# submit-then-follow-up sequence).

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
ROOT_DIR=$(cd "$SCRIPT_DIR/../../../.." && pwd) || exit 1
SCRIPTS_DIR="$ROOT_DIR/.agents/skills/operate-agent/scripts"
DEBUG_LIB="$ROOT_DIR/.agents/skills/debug-agent/scripts/lib"
STUB_BIN="$ROOT_DIR/.agents/skills/debug-agent/tests/stub/bin"
STUB_LIB="$ROOT_DIR/.agents/skills/debug-agent/tests/stub/lib"

WORK_ROOT=""
T_HOME=""
T_INSTANCES=""
ARGV_LOG=""
ERROR_LOG=""
FIXDIR=""
CODE=0

info() {
  printf 'operate-helpers: %s\n' "$*"
}

fail() {
  printf 'operate-helpers: FAIL: %s\n' "$*" >&2
  exit 1
}

setup_fixture() {
  T_INSTANCES="$WORK_ROOT/instances"
  T_HOME="$WORK_ROOT/home"
  ARGV_LOG="$WORK_ROOT/argv.log"
  ERROR_LOG="$WORK_ROOT/stub-errors.log"
  : >"$ARGV_LOG"
  : >"$ERROR_LOG"

  mkdir -p "$T_INSTANCES/agent-foo" "$T_INSTANCES/agent-plain"
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
  cat >"$T_INSTANCES/agent-plain/compose.yaml" <<'EOF'
services:
  agent:
    image: plain-image:latest
EOF
  printf 'TARGET_REPO=example-owner/example-repo\n' >"$T_INSTANCES/agent-foo/.env"
  printf 'TARGET_REPO=example-owner/example-repo\n' >"$T_INSTANCES/agent-plain/.env"
  mkdir -p "$T_HOME/OrbStack/docker/volumes/agent-plain_agent_data/state"
  printf '{"consecutive_errors":0}\n' >"$T_HOME/OrbStack/docker/volumes/agent-plain_agent_data/state/consecutive_errors.json"

  SCENE="$WORK_ROOT/scene"
  mkdir -p "$SCENE/agent-foo" "$SCENE/agent-plain"
  printf 'agent-foo-agent-1\n' >"$SCENE/agent-foo/ps-agent.txt"
  printf 'agent-foo-agent-1\n' >"$SCENE/agent-foo/ps-PROJECT.txt"
  printf 'running|0|2026-11-10T10:00:00Z|foo-image:latest\n' >"$SCENE/agent-foo/inspect-agent-foo-agent-1.txt"
  printf '1\n' >"$SCENE/agent-foo/contract-label-agent-foo-agent-1.txt"
  printf 'agent-plain-agent-1\n' >"$SCENE/agent-plain/ps-agent.txt"
  printf 'agent-plain-agent-1\n' >"$SCENE/agent-plain/ps-PROJECT.txt"
  printf 'running|0|2026-11-10T10:00:00Z|plain-image:latest\n' >"$SCENE/agent-plain/inspect-agent-plain-agent-1.txt"
  # Legacy agentctl text replies for the unlabelled instance.
  cat >"$SCENE/agent-plain/exec-agentctl-agent-plain-agent-1.txt" <<'EOF'
WORKER_ID=
intake: running
active_attempt: none
pending_next_issue: none
agent version: v0.9.0
repository: example-owner/example-repo
EOF
  cat >"$SCENE/agent-plain/exec-agentctl-stop-agent-plain-agent-1.txt" <<'EOF'
request_id: req-legacy0000000001
acknowledgement: accepted
detail: finish the active attempt, then close intake
EOF
  cat >"$SCENE/agent-plain/exec-agentctl-command-agent-plain-agent-1.txt" <<'EOF'
request_id: req-legacy0000000001
acknowledgement: completed
detail: intake closed after the active attempt finished
EOF
  cat >"$SCENE/fleet.json" <<'EOF'
{"containers": [
  {"id": "cid-foo-1", "name": "foo", "backend": "simple-coding-agent", "contract": "1", "exec_user": "agent", "state": "running"}
]}
EOF
}

resolve_fixtures() {
  _tag=$(sed -n 's/^CONTRACT_TAG=//p' "$DEBUG_LIB/contract.sh" | head -n 1)
  [ -n "$_tag" ] || fail "cannot read CONTRACT_TAG from debug-agent lib/contract.sh"
  PINNED_TAG="$_tag"
  export PINNED_TAG
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

run_operate() {
  : >"$ARGV_LOG"
  : >"$ERROR_LOG"
  set +e
  "$SCRIPTS_DIR/operate.sh" "$@" >"$WORK_ROOT/out.txt" 2>"$WORK_ROOT/err.txt"
  CODE=$?
  set -e
  [ ! -s "$ERROR_LOG" ] || fail "stub errors during operate $*: $(cat "$ERROR_LOG")"
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

# Every contract mutation argv carries --expect-repo and one --request-id.
assert_mutation_carries_guards() {
  _case=$1
  _id=$2
  grep -q -- "--expect-repo example-owner/example-repo" "$ARGV_LOG" || fail "$_case: no --expect-repo in mutation argv"
  grep -q -- "--request-id $_id" "$ARGV_LOG" || fail "$_case: no --request-id $_id in mutation argv"
  info "ok: $_case (mutation carries --expect-repo and --request-id)"
}

# All --request-id values on the argv log must be the one expected ID.
assert_single_request_id() {
  _case=$1
  _id=$2
  _ids=$(grep -o -- '--request-id [^ ]*' "$ARGV_LOG" | sort -u || true)
  [ -n "$_ids" ] || fail "$_case: no --request-id on the argv log at all"
  [ "$(printf '%s\n' "$_ids" | wc -l | tr -d ' ')" -eq 1 ] || fail "$_case: more than one request ID: $_ids"
  printf '%s\n' "$_ids" | grep -q -- "--request-id $_id" || fail "$_case: expected only ID $_id, got: $_ids"
  info "ok: $_case (single request ID $_id, no new ID)"
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
  export STUB_PROJECTS="agent-foo agent-plain"
  export STUB_LIB
  export PATH="$STUB_BIN:$PATH"

  [ "$(command -v docker)" = "$STUB_BIN/docker" ] || fail "stub docker is not first on PATH"

  resolve_fixtures
  export CONTRACT_FIXTURES_DIR="$FIXDIR"

  command -v agentfleet >/dev/null 2>&1 || fail "agentfleet is not installed; install from the pinned tag"
  _ver=$(agentfleet --version 2>/dev/null || true)
  info "agentfleet version: $_ver"

  export OPERATE_FOLLOW_INTERVAL=0

  # Success: stop commits with acknowledgement `accepted`, reported distinctly
  # from the final states, with a follow-up pointer carrying the same ID.
  export CONTRACT_IDENTITY_FIXTURE=identity.json
  export CONTRACT_STATUS_FIXTURE=stop-accepted.json
  run_operate --context rpi5 foo stop --request-id req-0a1b2c3d4e5f
  [ "$CODE" -eq 0 ] || fail "stop-accepted: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "managed_instance: foo" "stop-accepted"
  assert_contains "$WORK_ROOT/out.txt" "target_repo:     example-owner/example-repo" "stop-accepted"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-0a1b2c3d4e5f" "stop-accepted"
  assert_contains "$WORK_ROOT/out.txt" "acknowledgement: accepted" "stop-accepted"
  assert_contains "$WORK_ROOT/out.txt" "accepted (committed, effect not yet applied)" "stop-accepted (accepted distinct from final)"
  assert_contains "$WORK_ROOT/out.txt" "command req-0a1b2c3d4e5f" "stop-accepted (follow-up keeps the ID)"
  assert_mutation_carries_guards "stop-accepted" "req-0a1b2c3d4e5f"
  assert_no_file_reads "stop-accepted"
  info "ok: stop-accepted"

  # Success: resume commits already completed; the final state is reported.
  export CONTRACT_STATUS_FIXTURE=resume-accepted.json
  run_operate --context rpi5 foo resume --request-id req-1b2c3d4e5f6a
  [ "$CODE" -eq 0 ] || fail "resume-completed: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "acknowledgement: completed" "resume-completed"
  assert_contains "$WORK_ROOT/out.txt" "state:           final (completed)" "resume-completed (final state)"
  assert_mutation_carries_guards "resume-completed" "req-1b2c3d4e5f6a"
  assert_no_file_reads "resume-completed"
  info "ok: resume-completed"

  # Success: command lookup reads the committed command; --follow reaches the
  # final state with the same ID (the replayed resume envelope is completed).
  export CONTRACT_COMMAND_FIXTURE=resume-accepted.json
  run_operate --context rpi5 foo command req-9a8b7c6d5e4f --follow
  [ "$CODE" -eq 0 ] || fail "command-lookup: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-9a8b7c6d5e4f" "command-lookup"
  assert_contains "$WORK_ROOT/out.txt" "acknowledgement: completed" "command-lookup"
  assert_not_contains "$WORK_ROOT/out.txt" "still finalizing" "command-lookup (completed is final)"
  if grep -q -- '--request-id' "$ARGV_LOG"; then
    fail "command-lookup: a read must not submit a mutation (no --request-id in docker argv)"
  fi
  info "ok: command-lookup"

  # Rejection is reported with the request ID; nothing is stored, so there is
  # no command follow-up.
  export CONTRACT_STATUS_FIXTURE=rejected.json
  run_operate --context rpi5 foo resume --request-id req-2b3c4d5e6f7a
  [ "$CODE" -eq 1 ] || fail "rejection: exit $CODE, want 1"
  assert_contains "$WORK_ROOT/err.txt" "rejected" "rejection"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-2b3c4d5e6f7a" "rejection (ID surfaced)"
  if grep -q -- '--contract 1 command' "$ARGV_LOG"; then
    fail "rejection: nothing was stored, so no command follow-up may run"
  fi
  assert_mutation_carries_guards "rejection" "req-2b3c4d5e6f7a"
  assert_no_file_reads "rejection"
  info "ok: rejection"

  # Unsupported is reported, never retried through the legacy path.
  export CONTRACT_STATUS_FIXTURE=unsupported.json
  run_operate --context rpi5 foo resume --request-id req-3c4d5e6f7a8b
  [ "$CODE" -eq 3 ] || fail "unsupported: exit $CODE, want 3"
  if ! grep -q 'unsupported' "$WORK_ROOT/err.txt"; then
    grep -q 'unsupported' "$WORK_ROOT/out.txt" || fail "unsupported: expected 'unsupported' in output"
  fi
  assert_mutation_carries_guards "unsupported" "req-3c4d5e6f7a8b"
  assert_no_file_reads "unsupported"
  info "ok: unsupported"

  # Ambiguous outcome: the request ID is surfaced and followed up with
  # `command` under the same ID, never a new submission.
  export CONTRACT_STATUS_FIXTURE=agent-unreachable.json
  export CONTRACT_COMMAND_FIXTURE=command-found.json
  run_operate --context rpi5 foo stop --request-id req-4d5e6f7a8b9c
  [ "$CODE" -eq 0 ] || fail "ambiguous: command follow-up exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/err.txt" "ambiguous outcome" "ambiguous"
  assert_contains "$WORK_ROOT/err.txt" "req-4d5e6f7a8b9c" "ambiguous (ID surfaced)"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-4d5e6f7a8b9c" "ambiguous (same ID in follow-up)"
  grep -q -- '--contract 1 command' "$ARGV_LOG" || fail "ambiguous: no command follow-up ran"
  assert_single_request_id "ambiguous" "req-4d5e6f7a8b9c"
  assert_no_file_reads "ambiguous"
  info "ok: ambiguous outcome (same ID follow-up, no new ID)"

  # Contract mismatch is reported, never retried through the legacy path.
  export CONTRACT_STATUS_FIXTURE=contract-mismatch.json
  run_operate --context rpi5 foo stop --request-id req-5e6f7a8b9c0d
  [ "$CODE" -eq 4 ] || fail "contract-mismatch: exit $CODE, want 4"
  if ! grep -q 'contract_mismatch' "$WORK_ROOT/err.txt"; then
    grep -q 'contract_mismatch' "$WORK_ROOT/out.txt" || fail "contract-mismatch: expected 'contract_mismatch' in output"
  fi
  assert_no_file_reads "contract-mismatch"
  info "ok: contract mismatch (no legacy fallback)"

  # Malformed stdout is reported, never parsed as success.
  export CONTRACT_STATUS_FIXTURE=malformed-non-json.json
  run_operate --context rpi5 foo stop --request-id req-6f7a8b9c0d1e
  [ "$CODE" -ne 0 ] || fail "malformed: exit 0, want non-zero"
  if ! grep -q 'malformed' "$WORK_ROOT/err.txt"; then
    grep -q 'malformed' "$WORK_ROOT/out.txt" || fail "malformed: expected 'malformed' in output"
  fi
  assert_no_file_reads "malformed"
  info "ok: malformed stdout (exit $CODE)"

  # An unadvertised operation is refused before submission, with the
  # advertised capabilities listed. identity.json advertises
  # next-issue,stop-after; handoff needs operator-handoff.
  export CONTRACT_STATUS_FIXTURE=stop-accepted.json
  run_operate --context rpi5 foo handoff --request-id req-7a8b9c0d1e2f
  [ "$CODE" -eq 3 ] || fail "unadvertised: exit $CODE, want 3"
  assert_contains "$WORK_ROOT/err.txt" "does not advertise 'operator-handoff'" "unadvertised"
  assert_contains "$WORK_ROOT/err.txt" "advertised_capabilities: next-issue,stop-after" "unadvertised (caps listed)"
  if grep -q -- '--contract 1 handoff' "$ARGV_LOG"; then
    fail "unadvertised: the mutation was submitted anyway"
  fi
  grep -q -- '--contract 1 identity' "$ARGV_LOG" || fail "unadvertised: no identity pre-flight ran"
  info "ok: unadvertised operation refused before submission"

  # --context reaches agentfleet through the Docker context mechanism.
  export CONTRACT_STATUS_FIXTURE=stop-accepted.json
  run_operate --context rpi5 foo stop --request-id req-8b9c0d1e2f3a
  if ! grep -q 'CTX=rpi5 docker .*--contract' "$ARGV_LOG"; then
    fail "--context rpi5 did not reach agentfleet (no CTX=rpi5 contract call)"
  fi
  info "ok: --context reaches agentfleet"

  # Missing agentfleet stops with the install command and reads no files.
  (
    PATH="$STUB_BIN:/usr/bin:/bin"
    export PATH
    command -v agentfleet >/dev/null 2>&1 && fail "missing-agentfleet: agentfleet unexpectedly on PATH"
    run_operate --context rpi5 foo stop --request-id req-9c0d1e2f3a4b
    [ "$CODE" -ne 0 ] || fail "missing-agentfleet: exit 0, want non-zero"
    assert_contains "$WORK_ROOT/err.txt" "agentfleet is not installed" "missing-agentfleet"
    assert_contains "$WORK_ROOT/err.txt" "$PINNED_TAG" "missing-agentfleet install command pins the tag"
    assert_no_file_reads "missing-agentfleet"
    info "ok: missing agentfleet stops with the install command"
  )

  # Legacy path: stop on an unlabelled instance uses today's agentctl usage
  # with --expect-repo, and surfaces the printed request ID.
  unset CONTRACT_STATUS_FIXTURE
  unset CONTRACT_IDENTITY_FIXTURE
  unset CONTRACT_COMMAND_FIXTURE
  run_operate --context rpi5 plain stop
  [ "$CODE" -eq 0 ] || fail "legacy-stop: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "legacy agentctl" "legacy-stop"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-legacy0000000001" "legacy-stop"
  grep -q 'agentctl stop --expect-repo=example-owner/example-repo' "$ARGV_LOG" || fail "legacy-stop: no --expect-repo in agentctl argv"
  info "ok: legacy stop (legacy agentctl with --expect-repo)"

  # Legacy path: command lookup reads the stored command.
  run_operate --context rpi5 plain command req-legacy0000000001
  [ "$CODE" -eq 0 ] || fail "legacy-command: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "acknowledgement: completed" "legacy-command"
  grep -q 'agentctl command req-legacy0000000001' "$ARGV_LOG" || fail "legacy-command: no agentctl command argv"
  info "ok: legacy command lookup"

  info "PASS: operate-agent helper behaves as specified (fixtures from the pinned tag, no copies)"
}

main
