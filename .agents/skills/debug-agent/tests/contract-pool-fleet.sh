#!/bin/sh
# contract-pool-fleet.sh -- pin contract-path pool-status and the fleet overview.
#
# Runs pool-status.sh for a labelled Instance (per-Worker Status Snapshot
# blocks, Offline Read for a stopped Worker, --github only for
# simple-coding-agent Workers) and fleet.sh for a Docker context (contract
# Fleet from `agentfleet ls` plus per-member status, with unlabelled legacy
# containers listed separately), against stubbed Docker and `agentfleet` from
# the pinned tag. Covers the prerequisite stop (missing or wrong major), the
# per-Worker path selection of a mixed Instance, every pool block field, the
# --github skip for other backends, the failure reply classes with no legacy
# fallback, and --context propagation to agentfleet.
#
# Usage (from anywhere in this repository):
#
#   .agents/skills/debug-agent/tests/contract-pool-fleet.sh
#
# Hermeticity: HOME points at a scratch dir, AGENT_INSTANCES_DIR at a scratch
# fixture, PATH starts with tests/stub/bin (fake docker plus a gh that serves
# one recorded reply). CONTRACT_FIXTURES_DIR points at the fixtures of the
# pinned agent-operator-contract tag (the installed package matching
# CONTRACT_TAG, or a checkout via CONTRACT_CHECKOUT); no fixture is copied
# into this repo. Per-member fixtures are pinned by name through
# $scene/contract-status-<name>.txt, naming the fixture file. Shell internals
# are not tested: only exit status, stdout/stderr content (via grep for the
# promised sections) and the stub's argv log (no legacy `agentctl status` on
# the contract path, `--offline` for a stopped Worker, `--contract` on every
# producer call).

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
ROOT_DIR=$(cd "$SCRIPT_DIR/../../../.." && pwd) || exit 1
SCRIPTS_DIR="$ROOT_DIR/.agents/skills/debug-agent/scripts"
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
  printf 'contract-pool-fleet: %s\n' "$*"
}

fail() {
  printf 'contract-pool-fleet: FAIL: %s\n' "$*" >&2
  exit 1
}

setup_fixture() {
  T_INSTANCES="$WORK_ROOT/instances"
  T_HOME="$WORK_ROOT/home"
  ARGV_LOG="$WORK_ROOT/argv.log"
  ERROR_LOG="$WORK_ROOT/stub-errors.log"
  : >"$ARGV_LOG"
  : >"$ERROR_LOG"

  mkdir -p "$T_INSTANCES/agent-mix" "$T_INSTANCES/agent-sca" \
    "$T_INSTANCES/agent-code" "$T_INSTANCES/agent-halt" \
    "$T_INSTANCES/agent-drain" "$T_INSTANCES/agent-plain"
  cat >"$T_INSTANCES/agent-mix/compose.yaml" <<'EOF'
services:
  agent:
    image: mix-image:latest
    labels:
      io.github.lbacik.agent-operator.contract: "1"
      io.github.lbacik.agent-operator.instance: "mix"
      io.github.lbacik.agent-operator.exec-user: "agent"
      io.github.lbacik.agent-operator.backend: "simple-coding-agent"
    environment:
      WORKER_ID: mix-1
  agent-2:
    image: mix-image:latest
    labels:
      io.github.lbacik.agent-operator.contract: "1"
      io.github.lbacik.agent-operator.instance: "mix-2"
      io.github.lbacik.agent-operator.exec-user: "agent"
      io.github.lbacik.agent-operator.backend: "coding-agent"
    environment:
      WORKER_ID: mix-2
EOF
  cat >"$T_INSTANCES/agent-sca/compose.yaml" <<'EOF'
services:
  agent:
    image: sca-image:latest
    labels:
      io.github.lbacik.agent-operator.contract: "1"
      io.github.lbacik.agent-operator.instance: "sca"
      io.github.lbacik.agent-operator.exec-user: "agent"
      io.github.lbacik.agent-operator.backend: "simple-coding-agent"
    environment:
      WORKER_ID: sca-1
EOF
  cat >"$T_INSTANCES/agent-code/compose.yaml" <<'EOF'
services:
  agent:
    image: code-image:latest
    labels:
      io.github.lbacik.agent-operator.contract: "1"
      io.github.lbacik.agent-operator.instance: "code"
      io.github.lbacik.agent-operator.exec-user: "agent"
      io.github.lbacik.agent-operator.backend: "coding-agent"
    environment:
      WORKER_ID: code-1
EOF
  cat >"$T_INSTANCES/agent-halt/compose.yaml" <<'EOF'
services:
  agent:
    image: halt-image:latest
    labels:
      io.github.lbacik.agent-operator.contract: "1"
      io.github.lbacik.agent-operator.instance: "halt"
      io.github.lbacik.agent-operator.exec-user: "agent"
      io.github.lbacik.agent-operator.backend: "coding-agent"
    environment:
      WORKER_ID: halt-1
EOF
  cat >"$T_INSTANCES/agent-drain/compose.yaml" <<'EOF'
services:
  agent:
    image: drain-image:latest
    labels:
      io.github.lbacik.agent-operator.contract: "1"
      io.github.lbacik.agent-operator.instance: "drain"
      io.github.lbacik.agent-operator.exec-user: "agent"
      io.github.lbacik.agent-operator.backend: "coding-agent"
    environment:
      WORKER_ID: drain-1
EOF
  cat >"$T_INSTANCES/agent-plain/compose.yaml" <<'EOF'
services:
  agent:
    image: plain-image:latest
EOF
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-drain/.env"
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-mix/.env"
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-sca/.env"
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-code/.env"
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-halt/.env"
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-plain/.env"

  SCENE="$WORK_ROOT/scene"
  mkdir -p "$SCENE/agent-mix" "$SCENE/agent-sca" "$SCENE/agent-code" \
    "$SCENE/agent-halt" "$SCENE/agent-drain" "$SCENE/agent-plain"
  for p in agent-mix agent-sca agent-code agent-halt agent-drain agent-plain; do
    printf '%s-agent-1\n' "$p" >"$SCENE/$p/ps-agent.txt"
  done
  printf 'agent-mix-agent-2-1\n' >"$SCENE/agent-mix/ps-agent-2.txt"
  for p in agent-mix agent-sca agent-code agent-drain agent-plain; do
    printf 'running|0|2026-11-10T10:00:00Z|%s-image:latest\n' "$p" \
      >"$SCENE/$p/inspect-$p-agent-1.txt"
  done
  printf 'exited|2|2026-11-10T11:00:00Z|halt-image:latest\n' \
    >"$SCENE/agent-halt/inspect-agent-halt-agent-1.txt"
  printf 'agent|agent-mix-agent-1|running|Up 3 hours|1\nagent-2|agent-mix-agent-2-1|running|Up 3 hours|1\n' \
    >"$SCENE/agent-mix/ps-PROJECT.txt"
  printf 'agent|agent-sca-agent-1|running|Up 2 hours|1\n' >"$SCENE/agent-sca/ps-PROJECT.txt"
  printf 'agent|agent-code-agent-1|running|Up 2 hours|1\n' >"$SCENE/agent-code/ps-PROJECT.txt"
  printf 'agent|agent-halt-agent-1|exited|Exited (2) 1 hour ago|1\n' >"$SCENE/agent-halt/ps-PROJECT.txt"
  printf 'agent|agent-drain-agent-1|running|Up 2 hours|1\n' >"$SCENE/agent-drain/ps-PROJECT.txt"
  printf 'agent|agent-plain-agent-1|running|Up 2 hours\n' >"$SCENE/agent-plain/ps-PROJECT.txt"
  # Fleet overview legacy list: one ps for every project; a one-off of the
  # legacy instance is filtered client-side.
  cat >"$SCENE/ps-ALL.txt" <<'EOF'
agent-mix|agent-mix-agent-1|Up 3 hours|<no value>
agent-mix|agent-mix-agent-2-1|Up 3 hours|<no value>
agent-sca|agent-sca-agent-1|Up 2 hours|<no value>
agent-code|agent-code-agent-1|Up 2 hours|<no value>
agent-drain|agent-drain-agent-1|Up 2 hours|<no value>
agent-halt|agent-halt-agent-1|Exited (2) 1 hour ago|<no value>
agent-plain|agent-plain-agent-1|Up 2 hours|<no value>
agent-plain|agent-plain-run-abc|Up 1 minute|True
EOF
  cat >"$SCENE/fleet.json" <<'EOF'
{"containers": [
  {"id": "cid-mix-1", "name": "mix", "backend": "simple-coding-agent", "contract": "1", "exec_user": "agent", "state": "running", "image": "mix-image"},
  {"id": "cid-mix-2", "name": "mix-2", "backend": "coding-agent", "contract": "1", "exec_user": "agent", "state": "running", "image": "mix2-image"},
  {"id": "cid-sca-1", "name": "sca", "backend": "simple-coding-agent", "contract": "1", "exec_user": "agent", "state": "running", "image": "sca-image"},
  {"id": "cid-code-1", "name": "code", "backend": "coding-agent", "contract": "1", "exec_user": "agent", "state": "running", "image": "code-image"},
  {"id": "cid-drain-1", "name": "drain", "backend": "coding-agent", "contract": "1", "exec_user": "agent", "state": "running", "image": "drain-image"},
  {"id": "cid-halt-1", "name": "halt", "backend": "coding-agent", "contract": "1", "exec_user": "agent", "state": "exited", "image": "halt-image"}
]}
EOF
  printf 'status-simple-coding-agent.json\n' >"$SCENE/contract-status-mix.txt"
  printf 'status-active.json\n' >"$SCENE/contract-status-mix-2.txt"
  printf 'status-draining.json\n' >"$SCENE/contract-status-drain.txt"
  printf 'status-simple-coding-agent.json\n' >"$SCENE/contract-status-sca.txt"
  printf 'status-active.json\n' >"$SCENE/contract-status-code.txt"
  printf 'offline-status-halted.json\n' >"$SCENE/contract-status-halt.txt"

  # --github replies: post-jq lines `gh issue list --jq ...` would print.
  cat >"$SCENE/gh-mix.txt" <<'EOF'
42 issue
42 label claimed-by:mix-1
42 assignee some-login
7 issue
7 label claimed-by:ghost-9
EOF
  cat >"$SCENE/gh-sca-clean.txt" <<'EOF'
42 issue
42 label claimed-by:sca-1
42 assignee some-login
EOF
  cat >"$SCENE/gh-sca-nolabel.txt" <<'EOF'
42 issue
42 assignee some-login
EOF
  # Every label names the skipped coding-agent Worker: nothing is verified,
  # nothing is flagged orphaned.
  cat >"$SCENE/gh-code.txt" <<'EOF'
42 issue
42 label claimed-by:code-1
EOF
}

resolve_fixtures() {
  _tag=$(sed -n 's/^CONTRACT_TAG=//p' "$SCRIPTS_DIR/lib/contract.sh" | head -n 1)
  [ -n "$_tag" ] || fail "cannot read CONTRACT_TAG from lib/contract.sh"
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

run_helper() {
  name=$1
  shift
  : >"$ARGV_LOG"
  : >"$ERROR_LOG"
  set +e
  "$SCRIPTS_DIR/$name" "$@" >"$WORK_ROOT/out.txt" 2>"$WORK_ROOT/err.txt"
  CODE=$?
  set -e
  [ ! -s "$ERROR_LOG" ] || fail "stub errors during $name $*: $(cat "$ERROR_LOG")"
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
  if grep -q 'agentctl status' "$ARGV_LOG"; then
    case "$(cat "$ARGV_LOG")" in
      *--contract*) ;;
      *) fail "$1: contract path ran legacy 'agentctl status'" ;;
    esac
  fi
}

check_pool_block() {
  _case=$1
  [ "$CODE" -eq 0 ] || fail "$_case: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "(contract path)" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "instance:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "intake:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "pending_stop:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "stop_plan:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "priority:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "current_attempt:" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "native_phase" "$_case"
  assert_contains "$WORK_ROOT/out.txt" "observed_at" "$_case"
  assert_no_file_reads "$_case"
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
  export STUB_PROJECTS="agent-mix agent-sca agent-code agent-halt agent-drain agent-plain"
  export STUB_LIB
  export PATH="$STUB_BIN:$PATH"

  [ "$(command -v docker)" = "$STUB_BIN/docker" ] || fail "stub docker is not first on PATH"
  [ "$(command -v gh)" = "$STUB_BIN/gh" ] || fail "stub gh is not first on PATH"

  resolve_fixtures
  export CONTRACT_FIXTURES_DIR="$FIXDIR"

  command -v agentfleet >/dev/null 2>&1 || fail "agentfleet is not installed; install from the pinned tag"
  _ver=$(agentfleet --version 2>/dev/null || true)
  info "agentfleet version: $_ver"

  # Pool on one Worker: snapshot fields with unit-carrying budget Figures
  # behind them (simple-coding-agent backend, draining with a pending stop).
  unset STUB_GH_REPLY
  run_helper pool-status.sh --context rpi5 sca
  check_pool_block "pool-sca"
  assert_contains "$WORK_ROOT/out.txt" "managed sca" "pool-sca"
  assert_contains "$WORK_ROOT/out.txt" "backend=simple-coding-agent" "pool-sca"
  assert_contains "$WORK_ROOT/out.txt" "current_attempt: .*issue #42 native_phase model_running" "pool-sca"

  # Pool on a mixed Instance: one block per Worker, each on its own backend.
  run_helper pool-status.sh --context rpi5 mix
  check_pool_block "pool-mix"
  assert_contains "$WORK_ROOT/out.txt" "managed mix," "pool-mix"
  assert_contains "$WORK_ROOT/out.txt" "managed mix-2" "pool-mix"
  assert_contains "$WORK_ROOT/out.txt" "backend=simple-coding-agent" "pool-mix"
  assert_contains "$WORK_ROOT/out.txt" "backend=coding-agent" "pool-mix"

  # Draining Worker: Intake closed with a pending stop.
  run_helper pool-status.sh --context rpi5 drain
  check_pool_block "pool-drain"
  assert_contains "$WORK_ROOT/out.txt" "instance: .*draining" "pool-drain"
  assert_contains "$WORK_ROOT/out.txt" "intake: .*closed" "pool-drain"
  assert_contains "$WORK_ROOT/out.txt" "pending_stop: .*request" "pool-drain"

  # --github on the mixed Instance: comparison for the simple-coding-agent
  # Worker (owned label, orphaned label for no such Worker), skip note for
  # the coding-agent Worker active on an issue.
  export STUB_GH_REPLY="$WORK_ROOT/scene/gh-mix.txt"
  run_helper pool-status.sh --context rpi5 --github mix
  [ "$CODE" -eq 0 ] || fail "pool-mix-github: exit $CODE"
  assert_contains "$WORK_ROOT/out.txt" "orphaned claim: #7 labeled claimed-by:ghost-9" "pool-mix-github"
  assert_contains "$WORK_ROOT/out.txt" "active attempt of mix-1 (worker 1)" "pool-mix-github"
  assert_contains "$WORK_ROOT/out.txt" "Claim-marker comparison skipped" "pool-mix-github"
  assert_contains "$WORK_ROOT/out.txt" "mix-2.*backend coding-agent" "pool-mix-github"
  assert_no_file_reads "pool-mix-github"

  # --github on a clean simple-coding-agent Worker: claims consistent.
  export STUB_GH_REPLY="$WORK_ROOT/scene/gh-sca-clean.txt"
  run_helper pool-status.sh --context rpi5 --github sca
  [ "$CODE" -eq 0 ] || fail "pool-sca-github-clean: exit $CODE"
  assert_contains "$WORK_ROOT/out.txt" "claims consistent" "pool-sca-github-clean"

  # --github flags a claim without a label for simple-coding-agent.
  export STUB_GH_REPLY="$WORK_ROOT/scene/gh-sca-nolabel.txt"
  run_helper pool-status.sh --context rpi5 --github sca
  [ "$CODE" -eq 0 ] || fail "pool-sca-github-nolabel: exit $CODE"
  assert_contains "$WORK_ROOT/out.txt" "claim without label" "pool-sca-github-nolabel"
  unset STUB_GH_REPLY

  # --github on a coding-agent Worker skips the comparison and says so.
  export STUB_GH_REPLY="$WORK_ROOT/scene/gh-code.txt"
  run_helper pool-status.sh --context rpi5 --github code
  [ "$CODE" -eq 0 ] || fail "pool-code-github: exit $CODE"
  assert_contains "$WORK_ROOT/out.txt" "Claim-marker comparison skipped" "pool-code-github"
  assert_contains "$WORK_ROOT/out.txt" "not verified" "pool-code-github (owned label, unverified)"
  assert_not_contains "$WORK_ROOT/out.txt" "orphaned claim" "pool-code-github (nothing compared, nothing orphaned)"
  assert_contains "$WORK_ROOT/out.txt" "claims consistent for compared Workers" "pool-code-github (skipped Workers named)"
  unset STUB_GH_REPLY

  # --github Conflict requeue on the contract path: a live Conflict attempt
  # (marked in the simple-coding-agent Worker's block with its standing), a
  # queued attempt, a Conflict escalation, and the bare ready-for-human
  # triage label (never listed). Comment reads go only to the candidates.
  printf 'MAX_CONFLICT_ATTEMPTS=3\n' >>"$T_INSTANCES/agent-sca/.env"
  printf 'MAX_CONFLICT_ATTEMPTS=3\n' >>"$T_INSTANCES/agent-mix/.env"
  mkdir -p "$WORK_ROOT/gh-views"
  cat >"$WORK_ROOT/gh-views/view-42.txt" <<'EOF'
Rebased onto main, checks green.

**Conflict attempts**: 1/3
EOF
  cat >"$WORK_ROOT/gh-views/view-15.txt" <<'EOF'
First Conflict attempt failed, retrying.

**Conflict attempts**: 2/3
EOF
  cat >"$WORK_ROOT/gh-views/view-9.txt" <<'EOF'
Gave up after the last attempt.

**Conflict attempts**: 3/3

<!-- conflict-escalation -->
EOF
  cat >"$WORK_ROOT/gh-views/view-21.txt" <<'EOF'
Human triage note, not an escalation.
EOF
  # No standing comment: the row shows 0/N with the configured N.
  cat >"$WORK_ROOT/gh-views/view-30.txt" <<'EOF'
A Conflict attempt with no result comment yet.
EOF
  cat >"$WORK_ROOT/scene/gh-conflict.txt" <<'EOF'
42 issue
42 conflict merge-conflict
42 assignee some-login
15 issue
15 conflict merge-conflict
9 issue
9 conflict ready-for-human
21 issue
21 conflict ready-for-human
30 issue
30 conflict merge-conflict
EOF
  export STUB_GH_REPLY="$WORK_ROOT/scene/gh-conflict.txt"
  export STUB_GH_VIEW_DIR="$WORK_ROOT/gh-views"

  run_helper pool-status.sh --context rpi5 --github sca
  [ "$CODE" -eq 0 ] || fail "pool-sca-conflict: exit $CODE"
  assert_contains "$WORK_ROOT/out.txt" "Conflict requeue: MAX_CONFLICT_ATTEMPTS=3 (markers read from any author)" "pool-sca-conflict"
  assert_contains "$WORK_ROOT/out.txt" "Conflict attempt (1/3)" "pool-sca-conflict (Worker block mark)"
  assert_contains "$WORK_ROOT/out.txt" "#42 live (worker 1) 1/3" "pool-sca-conflict"
  assert_contains "$WORK_ROOT/out.txt" "#15 queued 2/3" "pool-sca-conflict"
  assert_contains "$WORK_ROOT/out.txt" "#9 escalated 3/3" "pool-sca-conflict"
  assert_contains "$WORK_ROOT/out.txt" "#30 queued 0/3" "pool-sca-conflict (no standing comment)"
  assert_not_contains "$WORK_ROOT/out.txt" "  #21 " "pool-sca-conflict (bare ready-for-human triage label never listed)"
  assert_not_contains "$WORK_ROOT/out.txt" "Conflict requeue comparison skipped" "pool-sca-conflict (nothing skipped)"
  assert_no_file_reads "pool-sca-conflict"

  # Mixed backends: the live row names the simple-coding-agent Worker only,
  # the coding-agent Worker gets the same kind of skip note as the Claim
  # comparison. Comment reads stay limited to the candidates.
  run_helper pool-status.sh --context rpi5 --github mix
  [ "$CODE" -eq 0 ] || fail "pool-mix-conflict: exit $CODE"
  assert_contains "$WORK_ROOT/out.txt" "#42 live (worker 1) 1/3" "pool-mix-conflict"
  assert_contains "$WORK_ROOT/out.txt" "mix-2.*backend coding-agent" "pool-mix-conflict"
  assert_contains "$WORK_ROOT/out.txt" "Conflict requeue comparison skipped" "pool-mix-conflict"
  [ "$(grep -c 'gh issue view' "$ARGV_LOG")" -eq 4 ] \
    || fail "pool-mix-conflict: comment reads must go to the 4 candidates only"
  assert_no_file_reads "pool-mix-conflict"

  # Requeue off with leftover labels and a coding-agent Worker: the header
  # says so, the rows are still listed with the stale/historical note, and
  # the other backend is skipped, never compared.
  cat >"$WORK_ROOT/scene/gh-off.txt" <<'EOF'
15 issue
15 conflict merge-conflict
9 issue
9 conflict ready-for-human
EOF
  export STUB_GH_REPLY="$WORK_ROOT/scene/gh-off.txt"
  run_helper pool-status.sh --context rpi5 --github code
  [ "$CODE" -eq 0 ] || fail "pool-code-conflict-off: exit $CODE"
  assert_contains "$WORK_ROOT/out.txt" "Conflict requeue: MAX_CONFLICT_ATTEMPTS=0 (requeue off; markers read from any author)" "pool-code-conflict-off"
  assert_contains "$WORK_ROOT/out.txt" "stale" "pool-code-conflict-off"
  assert_contains "$WORK_ROOT/out.txt" "historical" "pool-code-conflict-off"
  assert_contains "$WORK_ROOT/out.txt" "#15 queued 2/3" "pool-code-conflict-off"
  assert_contains "$WORK_ROOT/out.txt" "#9 escalated 3/3" "pool-code-conflict-off"
  assert_contains "$WORK_ROOT/out.txt" "Conflict requeue comparison skipped" "pool-code-conflict-off"

  # A failed comment read exits 1.
  export STUB_GH_REPLY="$WORK_ROOT/scene/gh-conflict.txt"
  export STUB_GH_VIEW_FAIL="15"
  run_helper pool-status.sh --context rpi5 --github sca
  [ "$CODE" -eq 1 ] || fail "pool-conflict-view-fail: exit $CODE, want 1"
  assert_contains "$WORK_ROOT/err.txt" "failed to read comments of issue #15" "pool-conflict-view-fail"
  unset STUB_GH_VIEW_FAIL
  unset STUB_GH_REPLY STUB_GH_VIEW_DIR
  info "ok: Conflict requeue cases (live, queued, escalated, triage label, requeue off, failed read)"

  # Stopped Worker: Offline Read, never a gap.
  run_helper pool-status.sh --context rpi5 halt
  [ "$CODE" -eq 0 ] || fail "pool-halt: exit $CODE"
  assert_contains "$WORK_ROOT/out.txt" "offline_read:" "pool-halt"
  assert_contains "$WORK_ROOT/out.txt" "instance: .*stopped" "pool-halt"
  assert_contains "$WORK_ROOT/out.txt" "last_halt:" "pool-halt"
  assert_contains "$WORK_ROOT/out.txt" "credential-failure" "pool-halt"
  if ! grep -q -- '--offline' "$ARGV_LOG"; then
    fail "pool-halt: no Offline Read in argv"
  fi
  assert_no_file_reads "pool-halt"

  # Failure reply: reported for the Worker, the rest still listed, no legacy
  # fallback, non-zero exit.
  printf 'contract-mismatch.json\n' >"$WORK_ROOT/scene/contract-status-mix-2.txt"
  run_helper pool-status.sh --context rpi5 mix
  [ "$CODE" -eq 4 ] || fail "pool-mismatch: exit $CODE, want 4"
  assert_contains "$WORK_ROOT/out.txt" "managed mix," "pool-mismatch (other Worker still listed)"
  assert_contains "$WORK_ROOT/out.txt" "contract_mismatch" "pool-mismatch"
  assert_contains "$WORK_ROOT/out.txt" "no legacy fallback" "pool-mismatch"
  assert_no_file_reads "pool-mismatch"
  printf 'status-active.json\n' >"$WORK_ROOT/scene/contract-status-mix-2.txt"

  # --context reaches agentfleet through the Docker context mechanism.
  run_helper pool-status.sh --context rpi5 sca
  if ! grep -q 'CTX=rpi5 docker .*--contract' "$ARGV_LOG"; then
    fail "--context rpi5 did not reach agentfleet (no CTX=rpi5 contract call)"
  fi
  info "ok: --context reaches agentfleet"

  # Fleet overview: every Managed Instance with backend, repository, state
  # and Intake, plus the legacy containers listed separately.
  run_helper fleet.sh --context rpi5
  [ "$CODE" -eq 0 ] || fail "fleet: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "fleet (context rpi5" "fleet"
  assert_contains "$WORK_ROOT/out.txt" "mix backend=simple-coding-agent repository=.* contract=1 instance=.* intake=" "fleet"
  assert_contains "$WORK_ROOT/out.txt" "mix-2 backend=coding-agent repository=" "fleet"
  assert_contains "$WORK_ROOT/out.txt" "halt backend=coding-agent repository=.* instance=stopped intake=" "fleet (stopped member through Offline Read)"
  assert_contains "$WORK_ROOT/out.txt" "legacy (not managed by agentfleet):" "fleet"
  assert_contains "$WORK_ROOT/out.txt" "agent-plain: agent-plain-agent-1" "fleet"
  assert_not_contains "$WORK_ROOT/out.txt" "agent-plain-run-abc" "fleet (one-off containers skipped)"
  for _m in mix mix-2 sca code halt drain; do
    assert_not_contains "$WORK_ROOT/out.txt" "  $_m: " "fleet (no labelled member in the legacy list)"
  done
  if ! grep -q 'label=io.github.lbacik.agent-operator.contract' "$ARGV_LOG"; then
    fail "fleet: no agentfleet discovery (contract label ps) in argv"
  fi
  if ! grep -q 'CTX=rpi5 docker .*--contract' "$ARGV_LOG"; then
    fail "fleet: --context rpi5 did not reach agentfleet"
  fi
  info "ok: fleet overview"

  # Fleet with a duplicated instance name flags the duplicate.
  cp "$WORK_ROOT/scene/fleet.json" "$WORK_ROOT/fleet-backup.json"
  python3 - "$WORK_ROOT/scene/fleet.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
dup = dict(doc["containers"][0])
dup["id"] = "cid-mix-1-dup"
dup["state"] = "exited"
doc["containers"].append(dup)
json.dump(doc, open(path, "w"))
PYEOF
  run_helper fleet.sh --context rpi5
  [ "$CODE" -ne 0 ] || fail "fleet-dup: exit 0, want non-zero (no status by a duplicated name)"
  assert_contains "$WORK_ROOT/out.txt" "DUPLICATE" "fleet-dup"
  assert_contains "$WORK_ROOT/out.txt" "duplicate_instance" "fleet-dup"
  cp "$WORK_ROOT/fleet-backup.json" "$WORK_ROOT/scene/fleet.json"

  # Fleet with an unreadable member status lists the rest and exits non-zero.
  printf 'malformed-non-json.json\n' >"$WORK_ROOT/scene/contract-status-sca.txt"
  run_helper fleet.sh --context rpi5
  [ "$CODE" -ne 0 ] || fail "fleet-malformed: exit 0, want non-zero"
  assert_contains "$WORK_ROOT/out.txt" "sca backend=simple-coding-agent contract=1.*status unavailable (client.malformed_stdout)" "fleet-malformed"
  assert_contains "$WORK_ROOT/out.txt" "mix backend=" "fleet-malformed (other members still listed)"
  printf 'status-simple-coding-agent.json\n' >"$WORK_ROOT/scene/contract-status-sca.txt"

  # The renderers report a non-envelope stdin instead of parsing it.
  if printf 'not json' | python3 "$SCRIPTS_DIR/lib/render_pool.py" --meta \
    >"$WORK_ROOT/render-out.txt" 2>"$WORK_ROOT/render-err.txt"; then
    fail "render-pool-meta: exit 0 on non-JSON stdin"
  fi
  if printf 'not json' | python3 "$SCRIPTS_DIR/lib/render_fleet_member.py" \
    --name x --backend b --contract 1 >"$WORK_ROOT/render-out.txt" 2>/dev/null; then
    fail "render-fleet-member: exit 0 on non-JSON stdin"
  fi
  assert_contains "$WORK_ROOT/render-out.txt" "status unreadable" "render-fleet-member"

  # Missing agentfleet stops pool-status and fleet with the install command
  # and reads no container files.
  (
    PATH="$STUB_BIN:/usr/bin:/bin"
    export PATH
    command -v agentfleet >/dev/null 2>&1 && fail "missing-agentfleet: agentfleet unexpectedly on PATH"
    unset STUB_GH_REPLY
    run_helper pool-status.sh --context rpi5 sca
    [ "$CODE" -ne 0 ] || fail "missing-agentfleet-pool: exit 0, want non-zero"
    assert_contains "$WORK_ROOT/err.txt" "agentfleet is not installed" "missing-agentfleet-pool"
    assert_contains "$WORK_ROOT/err.txt" "$PINNED_TAG" "missing-agentfleet-pool install command pins the tag"
    assert_no_file_reads "missing-agentfleet-pool"
    run_helper fleet.sh --context rpi5
    [ "$CODE" -ne 0 ] || fail "missing-agentfleet-fleet: exit 0, want non-zero"
    assert_contains "$WORK_ROOT/err.txt" "agentfleet is not installed" "missing-agentfleet-fleet"
    assert_contains "$WORK_ROOT/err.txt" "$PINNED_TAG" "missing-agentfleet-fleet install command pins the tag"
    assert_no_file_reads "missing-agentfleet-fleet"
    info "ok: missing agentfleet stops with the install command"
  )

  # Wrong contract major stops pool-status and fleet with the install command.
  (
    _faked="$WORK_ROOT/fakebin"
    mkdir -p "$_faked"
    # shellcheck disable=SC2016 # intentional: the fake's body must not expand here.
    printf '#!/bin/sh\nif [ "${1:-}" = "--version" ]; then echo "agentfleet 9.9.9 (contract major 9)"; exit 0; fi\necho "agentfleet: unexpected call" >&2; exit 1\n' >"$_faked/agentfleet"
    chmod +x "$_faked/agentfleet"
    PATH="$_faked:$STUB_BIN:/usr/bin:/bin"
    export PATH
    unset STUB_GH_REPLY
    run_helper pool-status.sh --context rpi5 sca
    [ "$CODE" -ne 0 ] || fail "wrong-major-pool: exit 0, want non-zero"
    assert_contains "$WORK_ROOT/err.txt" "unexpected contract major" "wrong-major-pool"
    assert_contains "$WORK_ROOT/err.txt" "$PINNED_TAG" "wrong-major-pool install command pins the tag"
    assert_no_file_reads "wrong-major-pool"
    run_helper fleet.sh --context rpi5
    [ "$CODE" -ne 0 ] || fail "wrong-major-fleet: exit 0, want non-zero"
    assert_contains "$WORK_ROOT/err.txt" "unexpected contract major" "wrong-major-fleet"
    info "ok: wrong contract major stops with the install command"
  )

  info "PASS: contract-path pool-status and fleet overview behave as specified (fixtures from the pinned tag, no copies)"
}

main
