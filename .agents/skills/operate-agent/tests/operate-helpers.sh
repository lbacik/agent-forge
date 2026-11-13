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
# The optional commands (`stop --after`, `next-issue` followed to
# `completed`/`superseded`/`not_fulfilled`, `handoff`, `recovery-retry`,
# `recovery-release --saved-at`, `errors-reset`) are covered the same way:
# success with guards, rejection, and refusal when unadvertised, plus the
# credential-shaped `--saved-at` refusal (no submission, value never
# echoed) and the legacy `agentctl` argv for each.
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
# a gh that fails if ever called). CONTRACT_FIXTURES_DIR points at a scratch
# farm of symlinks to the fixtures of the pinned agent-operator-contract tag
# (the installed package matching CONTRACT_TAG, or a checkout via
# CONTRACT_CHECKOUT), plus five envelopes derived at run time from those
# fixtures (a full-capability identity, two single-capability identities, a
# `not_fulfilled` command read and a `superseded` command read — the tag
# ships no such fixture); no fixture is copied into this repo. Shell
# internals are not tested: only exit status,
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
  cat >"$SCENE/agent-plain/exec-agentctl-recovery-retry-agent-plain-agent-1.txt" <<'EOF'
request_id: req-legacy0000000002
acknowledgement: completed
detail: safe finalization retried from retained evidence
EOF
  cat >"$SCENE/agent-plain/exec-agentctl-recovery-release-agent-plain-agent-1.txt" <<'EOF'
request_id: req-legacy0000000003
acknowledgement: completed
detail: work secured at shelf-303; issue released
EOF
  cat >"$SCENE/agent-plain/exec-agentctl-errors-reset-agent-plain-agent-1.txt" <<'EOF'
request_id: req-legacy0000000004
acknowledgement: completed
detail: infrastructure-error guard reset
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
  grep -q -- "$2" "$1" || fail "$3: expected '$2' in $(cat "$1")"
}

assert_not_contains() {
  if grep -q -- "$2" "$1"; then
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

  # The pinned tag ships no full-capability identity and no `not_fulfilled`
  # or `superseded` command fixture, so derive them at run time from the
  # pinned fixtures (a symlink farm plus five generated envelopes): nothing
  # is copied, and the derived envelopes cannot go stale.
  FIXFARM="$WORK_ROOT/fixfarm"
  mkdir -p "$FIXFARM"
  for _f in "$FIXDIR"/*.json; do ln -s "$_f" "$FIXFARM/$(basename "$_f")"; done
  # The stub replays the harness wrapper ({argv, exit_code, stdout,
  # stderr}), so the derived envelopes are wrapped the same way.
  python3 - "$FIXDIR/identity.json" "$FIXFARM/identity-full.json" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1]))
env = json.loads(doc["stdout"])
env["result"]["capabilities"] = ["next-issue", "stop-after", "operator-handoff",
                                 "recovery-retry", "recovery-release", "errors-reset", "pool"]
doc["stdout"] = json.dumps(env) + "\n"
json.dump(doc, open(sys.argv[2], "w"))
PYEOF
  # Single-capability identities: the pinned identity advertises
  # next-issue and stop-after together, so derive the one-sided variants
  # to pin the unadvertised refusal of each optional command.
  python3 - "$FIXDIR/identity.json" "$FIXFARM/identity-next-only.json" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1]))
env = json.loads(doc["stdout"])
env["result"]["capabilities"] = ["next-issue"]
doc["stdout"] = json.dumps(env) + "\n"
json.dump(doc, open(sys.argv[2], "w"))
PYEOF
  python3 - "$FIXDIR/identity.json" "$FIXFARM/identity-stop-only.json" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1]))
env = json.loads(doc["stdout"])
env["result"]["capabilities"] = ["stop-after"]
doc["stdout"] = json.dumps(env) + "\n"
json.dump(doc, open(sys.argv[2], "w"))
PYEOF
  python3 - "$FIXDIR/next-issue-accepted.json" "$FIXFARM/command-not-fulfilled.json" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1]))
env = json.loads(doc["stdout"])
env["result"]["command"]["acknowledgement"] = "not_fulfilled"
env["result"]["command"]["detail"] = "issue 122 went to another worker; priority not fulfilled"
doc["stdout"] = json.dumps(env) + "\n"
json.dump(doc, open(sys.argv[2], "w"))
PYEOF
  python3 - "$FIXDIR/next-issue-accepted.json" "$FIXFARM/command-superseded.json" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1]))
env = json.loads(doc["stdout"])
env["result"]["command"]["acknowledgement"] = "superseded"
env["result"]["command"]["detail"] = "a newer command superseded this priority"
doc["stdout"] = json.dumps(env) + "\n"
json.dump(doc, open(sys.argv[2], "w"))
PYEOF
  export CONTRACT_FIXTURES_DIR="$FIXFARM"

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

  # Optional stop plan: stop --after commits where advertised, carrying the
  # guards; the producer argv is `stop --after N`.
  export CONTRACT_IDENTITY_FIXTURE=identity.json
  export CONTRACT_STATUS_FIXTURE=stop-after-accepted.json
  run_operate --context rpi5 foo stop --after 2 --request-id req-aa01bb02cc03
  [ "$CODE" -eq 0 ] || fail "stop-after: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "close Intake after 2 finalized attempts" "stop-after (effect)"
  assert_contains "$WORK_ROOT/out.txt" "acknowledgement: accepted" "stop-after"
  assert_contains "$WORK_ROOT/out.txt" "accepted (committed, effect not yet applied)" "stop-after (accepted distinct)"
  grep -q -- '--contract 1 stop --after 2' "$ARGV_LOG" || fail "stop-after: no 'stop --after 2' in mutation argv"
  assert_mutation_carries_guards "stop-after" "req-aa01bb02cc03"
  assert_no_file_reads "stop-after"
  info "ok: stop --after (stop plan)"

  # stop --after rejection is reported with the request ID; nothing is
  # stored, so there is no command follow-up.
  export CONTRACT_STATUS_FIXTURE=rejected.json
  run_operate --context rpi5 foo stop --after 2 --request-id req-aa02bb03cc04
  [ "$CODE" -eq 1 ] || fail "stop-after-rejection: exit $CODE, want 1"
  assert_contains "$WORK_ROOT/err.txt" "rejected" "stop-after-rejection"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-aa02bb03cc04" "stop-after-rejection (ID surfaced)"
  if grep -q -- '--contract 1 command' "$ARGV_LOG"; then
    fail "stop-after-rejection: nothing was stored, so no command follow-up may run"
  fi
  assert_mutation_carries_guards "stop-after-rejection" "req-aa02bb03cc04"
  assert_no_file_reads "stop-after-rejection"
  info "ok: stop --after rejection"

  # stop --after is refused before submission where the instance does not
  # advertise stop-after, listing the advertised capabilities.
  export CONTRACT_IDENTITY_FIXTURE=identity-next-only.json
  export CONTRACT_STATUS_FIXTURE=stop-after-accepted.json
  run_operate --context rpi5 foo stop --after 2 --request-id req-aa03bb04cc05
  [ "$CODE" -eq 3 ] || fail "stop-after-unadvertised: exit $CODE, want 3"
  assert_contains "$WORK_ROOT/err.txt" "does not advertise 'stop-after'" "stop-after-unadvertised"
  assert_contains "$WORK_ROOT/err.txt" "advertised_capabilities: next-issue" "stop-after-unadvertised (caps listed)"
  if grep -q -- '--contract 1 stop' "$ARGV_LOG"; then
    fail "stop-after-unadvertised: the mutation was submitted anyway"
  fi
  export CONTRACT_IDENTITY_FIXTURE=identity.json
  info "ok: stop --after refused when unadvertised"

  # next-issue commits a one-shot priority; --follow reaches the final state
  # with the same ID (the producer argv is `next issue N`).
  export CONTRACT_STATUS_FIXTURE=next-issue-accepted.json
  export CONTRACT_COMMAND_FIXTURE=resume-accepted.json
  run_operate --context rpi5 foo next-issue 122 --follow --request-id req-bb02cc03dd04
  [ "$CODE" -eq 0 ] || fail "next-issue: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "one-shot priority: issue #122" "next-issue (effect)"
  assert_contains "$WORK_ROOT/out.txt" "acknowledgement: completed" "next-issue (final)"
  assert_contains "$WORK_ROOT/out.txt" "state:           final (completed)" "next-issue (final state)"
  grep -q -- '--contract 1 next issue 122' "$ARGV_LOG" || fail "next-issue: no 'next issue 122' in mutation argv"
  assert_mutation_carries_guards "next-issue" "req-bb02cc03dd04"
  assert_single_request_id "next-issue" "req-bb02cc03dd04"
  assert_no_file_reads "next-issue"
  info "ok: next-issue followed to completed"

  # A lost race is final (superseded) but reported distinctly from success.
  export CONTRACT_COMMAND_FIXTURE=command-superseded.json
  run_operate --context rpi5 foo next-issue 122 --follow --request-id req-cc03dd04ee05
  [ "$CODE" -eq 0 ] || fail "next-issue-superseded: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "state:           final (superseded)" "next-issue-superseded"
  assert_single_request_id "next-issue-superseded" "req-cc03dd04ee05"
  info "ok: next-issue followed to superseded"

  # A not_fulfilled priority is final yet reported as not done, never as
  # success: the operator must re-decide.
  export CONTRACT_COMMAND_FIXTURE=command-not-fulfilled.json
  run_operate --context rpi5 foo next-issue 122 --follow --request-id req-dd04ee05ff06
  [ "$CODE" -eq 0 ] || fail "next-issue-not-fulfilled: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "state:           final (not_fulfilled)" "next-issue-not-fulfilled (final)"
  assert_contains "$WORK_ROOT/out.txt" "not done" "next-issue-not-fulfilled (not done)"
  assert_not_contains "$WORK_ROOT/out.txt" "final (completed)" "next-issue-not-fulfilled (never success)"
  assert_single_request_id "next-issue-not-fulfilled" "req-dd04ee05ff06"
  info "ok: next-issue not_fulfilled reported as not done"

  # next-issue rejection is reported with the request ID; nothing is
  # stored, so there is no command follow-up.
  export CONTRACT_IDENTITY_FIXTURE=identity.json
  export CONTRACT_STATUS_FIXTURE=rejected.json
  run_operate --context rpi5 foo next-issue 122 --request-id req-dd05ee06ff07
  [ "$CODE" -eq 1 ] || fail "next-issue-rejection: exit $CODE, want 1"
  assert_contains "$WORK_ROOT/err.txt" "rejected" "next-issue-rejection"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-dd05ee06ff07" "next-issue-rejection (ID surfaced)"
  if grep -q -- '--contract 1 command' "$ARGV_LOG"; then
    fail "next-issue-rejection: nothing was stored, so no command follow-up may run"
  fi
  assert_mutation_carries_guards "next-issue-rejection" "req-dd05ee06ff07"
  assert_no_file_reads "next-issue-rejection"
  info "ok: next-issue rejection"

  # next-issue is refused before submission where the instance does not
  # advertise it, listing the advertised capabilities.
  export CONTRACT_IDENTITY_FIXTURE=identity-stop-only.json
  export CONTRACT_STATUS_FIXTURE=next-issue-accepted.json
  run_operate --context rpi5 foo next-issue 122 --request-id req-dd06ee07ff08
  [ "$CODE" -eq 3 ] || fail "next-issue-unadvertised: exit $CODE, want 3"
  assert_contains "$WORK_ROOT/err.txt" "does not advertise 'next-issue'" "next-issue-unadvertised"
  assert_contains "$WORK_ROOT/err.txt" "advertised_capabilities: stop-after" "next-issue-unadvertised (caps listed)"
  if grep -q -- '--contract 1 next' "$ARGV_LOG"; then
    fail "next-issue-unadvertised: the mutation was submitted anyway"
  fi
  info "ok: next-issue refused when unadvertised"

  # handoff commits where the instance advertises operator-handoff.
  export CONTRACT_IDENTITY_FIXTURE=identity-full.json
  export CONTRACT_STATUS_FIXTURE=handoff-accepted.json
  run_operate --context rpi5 foo handoff --request-id req-ee05ff06aa07
  [ "$CODE" -eq 0 ] || fail "handoff: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "Operator Handoff of the active attempt" "handoff (effect)"
  assert_contains "$WORK_ROOT/out.txt" "acknowledgement: accepted" "handoff"
  assert_contains "$WORK_ROOT/out.txt" "accepted (committed, effect not yet applied)" "handoff (accepted distinct)"
  assert_contains "$WORK_ROOT/out.txt" "command req-ee05ff06aa07" "handoff (follow-up keeps the ID)"
  grep -q -- '--contract 1 handoff now' "$ARGV_LOG" || fail "handoff: no 'handoff now' in mutation argv"
  assert_mutation_carries_guards "handoff" "req-ee05ff06aa07"
  assert_no_file_reads "handoff"
  info "ok: handoff (accepted distinct from final)"

  # handoff rejection is reported with the request ID; nothing is stored,
  # so there is no command follow-up.
  export CONTRACT_STATUS_FIXTURE=handoff-rejected.json
  run_operate --context rpi5 foo handoff --request-id req-ee06ff07aa08
  [ "$CODE" -eq 1 ] || fail "handoff-rejection: exit $CODE, want 1"
  assert_contains "$WORK_ROOT/err.txt" "rejected" "handoff-rejection"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-ee06ff07aa08" "handoff-rejection (ID surfaced)"
  if grep -q -- '--contract 1 command' "$ARGV_LOG"; then
    fail "handoff-rejection: nothing was stored, so no command follow-up may run"
  fi
  assert_mutation_carries_guards "handoff-rejection" "req-ee06ff07aa08"
  assert_no_file_reads "handoff-rejection"
  info "ok: handoff rejection"

  # recovery-retry commits where advertised, carrying the guards.
  export CONTRACT_STATUS_FIXTURE=recovery-retry-completed.json
  run_operate --context rpi5 foo recovery-retry stub-1 --request-id req-ff06aa07bb08
  [ "$CODE" -eq 0 ] || fail "recovery-retry: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "retry safe finalization of attempt stub-1" "recovery-retry (effect)"
  assert_contains "$WORK_ROOT/out.txt" "acknowledgement: completed" "recovery-retry"
  assert_contains "$WORK_ROOT/out.txt" "state:           final (completed)" "recovery-retry (final state)"
  grep -q -- '--contract 1 recovery retry stub-1' "$ARGV_LOG" || fail "recovery-retry: no 'recovery retry stub-1' in mutation argv"
  assert_mutation_carries_guards "recovery-retry" "req-ff06aa07bb08"
  assert_no_file_reads "recovery-retry"
  info "ok: recovery-retry"

  # recovery-retry is refused before submission when not advertised.
  export CONTRACT_IDENTITY_FIXTURE=identity.json
  run_operate --context rpi5 foo recovery-retry stub-1 --request-id req-aa07bb08cc09
  [ "$CODE" -eq 3 ] || fail "recovery-retry-unadvertised: exit $CODE, want 3"
  assert_contains "$WORK_ROOT/err.txt" "does not advertise 'recovery-retry'" "recovery-retry-unadvertised"
  assert_contains "$WORK_ROOT/err.txt" "advertised_capabilities:" "recovery-retry-unadvertised (caps listed)"
  if grep -q -- '--contract 1 recovery' "$ARGV_LOG"; then
    fail "recovery-retry-unadvertised: the mutation was submitted anyway"
  fi
  info "ok: recovery-retry refused when unadvertised"

  # recovery-retry rejection is reported with the request ID; nothing is
  # stored, so there is no command follow-up.
  export CONTRACT_IDENTITY_FIXTURE=identity-full.json
  export CONTRACT_STATUS_FIXTURE=recovery-retry-rejected.json
  run_operate --context rpi5 foo recovery-retry stub-1 --request-id req-bb08cc09dd10
  [ "$CODE" -eq 1 ] || fail "recovery-retry-rejection: exit $CODE, want 1"
  assert_contains "$WORK_ROOT/err.txt" "rejected" "recovery-retry-rejection"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-bb08cc09dd10" "recovery-retry-rejection (ID surfaced)"
  if grep -q -- '--contract 1 command' "$ARGV_LOG"; then
    fail "recovery-retry-rejection: nothing was stored, so no command follow-up may run"
  fi
  assert_mutation_carries_guards "recovery-retry-rejection" "req-bb08cc09dd10"
  assert_no_file_reads "recovery-retry-rejection"
  info "ok: recovery-retry rejection"

  # recovery-release commits where advertised, carrying --saved-at with the
  # location (never a credential).
  export CONTRACT_STATUS_FIXTURE=recovery-release-completed.json
  run_operate --context rpi5 foo recovery-release stub-1 --saved-at shelf-303 --request-id req-cc09dd10ee11
  [ "$CODE" -eq 0 ] || fail "recovery-release: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "secured at shelf-303" "recovery-release (location echoed)"
  assert_contains "$WORK_ROOT/out.txt" "acknowledgement: completed" "recovery-release"
  grep -q -- '--contract 1 recovery release stub-1 --saved-at shelf-303' "$ARGV_LOG" || fail "recovery-release: no 'recovery release stub-1 --saved-at shelf-303' in mutation argv"
  assert_mutation_carries_guards "recovery-release" "req-cc09dd10ee11"
  assert_no_file_reads "recovery-release"
  info "ok: recovery-release"

  # recovery-release is refused before submission when not advertised.
  export CONTRACT_IDENTITY_FIXTURE=identity.json
  run_operate --context rpi5 foo recovery-release stub-1 --saved-at shelf-303 --request-id req-dd10ee11ff12
  [ "$CODE" -eq 3 ] || fail "recovery-release-unadvertised: exit $CODE, want 3"
  assert_contains "$WORK_ROOT/err.txt" "does not advertise 'recovery-release'" "recovery-release-unadvertised"
  if grep -q -- '--contract 1 recovery' "$ARGV_LOG"; then
    fail "recovery-release-unadvertised: the mutation was submitted anyway"
  fi
  info "ok: recovery-release refused when unadvertised"

  # recovery-release without --saved-at is a usage error: nothing submitted.
  export CONTRACT_IDENTITY_FIXTURE=identity-full.json
  run_operate --context rpi5 foo recovery-release stub-1 --request-id req-ee11ff12aa13
  [ "$CODE" -eq 2 ] || fail "recovery-release-no-saved-at: exit $CODE, want 2"
  assert_contains "$WORK_ROOT/err.txt" "--saved-at" "recovery-release-no-saved-at (asks for a location)"
  if grep -q -- '--contract 1' "$ARGV_LOG"; then
    fail "recovery-release-no-saved-at: nothing may be submitted without --saved-at"
  fi
  info "ok: recovery-release without --saved-at refused"

  # recovery-release refuses a credential-shaped --saved-at before
  # submission and asks for a location instead; the value is never echoed
  # and no submission (not even identity) runs.
  for _secret in "ghp_0123456789abcdef0123456789abcdef0123" "token=0123456789abcdef0123456789abcdef" "0123456789abcdef0123456789abcdef0123456789abcdef"; do
    run_operate --context rpi5 foo recovery-release stub-1 --saved-at "$_secret" --request-id req-ff12aa13bb14
    [ "$CODE" -eq 2 ] || fail "recovery-release-secret: exit $CODE, want 2 for '$_secret'"
    assert_contains "$WORK_ROOT/err.txt" "looks like a credential" "recovery-release-secret (refused)"
    assert_contains "$WORK_ROOT/err.txt" "location" "recovery-release-secret (asks for a location)"
    if grep -q -- '--contract 1' "$ARGV_LOG"; then
      fail "recovery-release-secret: nothing may be submitted with a credential-shaped --saved-at"
    fi
    if grep -q "$_secret" "$WORK_ROOT/out.txt" || grep -q "$_secret" "$WORK_ROOT/err.txt"; then
      fail "recovery-release-secret: the refused value must never be echoed"
    fi
  done
  info "ok: recovery-release refuses credential-shaped --saved-at"

  # recovery-release rejection is reported with the request ID; nothing is
  # stored, so there is no command follow-up.
  export CONTRACT_STATUS_FIXTURE=recovery-release-rejected.json
  run_operate --context rpi5 foo recovery-release stub-1 --saved-at shelf-303 --request-id req-ff13aa14bb15
  [ "$CODE" -eq 1 ] || fail "recovery-release-rejection: exit $CODE, want 1"
  assert_contains "$WORK_ROOT/err.txt" "rejected" "recovery-release-rejection"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-ff13aa14bb15" "recovery-release-rejection (ID surfaced)"
  if grep -q -- '--contract 1 command' "$ARGV_LOG"; then
    fail "recovery-release-rejection: nothing was stored, so no command follow-up may run"
  fi
  assert_mutation_carries_guards "recovery-release-rejection" "req-ff13aa14bb15"
  assert_no_file_reads "recovery-release-rejection"
  info "ok: recovery-release rejection"

  # errors-reset commits where advertised, carrying the guards.
  export CONTRACT_STATUS_FIXTURE=errors-reset-completed.json
  run_operate --context rpi5 foo errors-reset --request-id req-aa13bb14cc15
  [ "$CODE" -eq 0 ] || fail "errors-reset: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "infrastructure-error guard" "errors-reset (effect)"
  assert_contains "$WORK_ROOT/out.txt" "acknowledgement: completed" "errors-reset"
  assert_contains "$WORK_ROOT/out.txt" "state:           final (completed)" "errors-reset (final state)"
  grep -q -- '--contract 1 errors reset' "$ARGV_LOG" || fail "errors-reset: no 'errors reset' in mutation argv"
  assert_mutation_carries_guards "errors-reset" "req-aa13bb14cc15"
  assert_no_file_reads "errors-reset"
  info "ok: errors-reset"

  # errors-reset is rejected with no change while the guard is already
  # clear; nothing is stored, so there is no command follow-up.
  export CONTRACT_STATUS_FIXTURE=errors-reset-rejected.json
  run_operate --context rpi5 foo errors-reset --request-id req-bb14cc15dd16
  [ "$CODE" -eq 1 ] || fail "errors-reset-rejection: exit $CODE, want 1"
  assert_contains "$WORK_ROOT/err.txt" "rejected" "errors-reset-rejection"
  if grep -q -- '--contract 1 command' "$ARGV_LOG"; then
    fail "errors-reset-rejection: nothing was stored, so no command follow-up may run"
  fi
  assert_mutation_carries_guards "errors-reset-rejection" "req-bb14cc15dd16"
  assert_no_file_reads "errors-reset-rejection"
  info "ok: errors-reset rejection when the guard is clear"

  # errors-reset is refused before submission when not advertised.
  export CONTRACT_IDENTITY_FIXTURE=identity.json
  run_operate --context rpi5 foo errors-reset --request-id req-cc15dd16ee17
  [ "$CODE" -eq 3 ] || fail "errors-reset-unadvertised: exit $CODE, want 3"
  assert_contains "$WORK_ROOT/err.txt" "does not advertise 'errors-reset'" "errors-reset-unadvertised"
  if grep -q -- '--contract 1 errors' "$ARGV_LOG"; then
    fail "errors-reset-unadvertised: the mutation was submitted anyway"
  fi
  info "ok: errors-reset refused when unadvertised"
  export CONTRACT_IDENTITY_FIXTURE=identity-full.json

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

  # Legacy path: stop --after passes the plan through to agentctl.
  run_operate --context rpi5 plain stop --after 2
  [ "$CODE" -eq 0 ] || fail "legacy-stop-after: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "legacy agentctl" "legacy-stop-after"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-legacy0000000001" "legacy-stop-after"
  grep -q 'agentctl stop --after 2 --expect-repo=example-owner/example-repo' "$ARGV_LOG" || fail "legacy-stop-after: no 'agentctl stop --after 2 --expect-repo=' in agentctl argv"
  info "ok: legacy stop --after"

  # Legacy path: recovery retry (the legacy grammar takes no --expect-repo).
  run_operate --context rpi5 plain recovery-retry att-7
  [ "$CODE" -eq 0 ] || fail "legacy-recovery-retry: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "legacy agentctl" "legacy-recovery-retry"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-legacy0000000002" "legacy-recovery-retry"
  grep -q 'agentctl recovery retry att-7' "$ARGV_LOG" || fail "legacy-recovery-retry: no 'agentctl recovery retry att-7' in argv"
  assert_not_contains "$ARGV_LOG" "expect-repo" "legacy-recovery-retry (legacy recovery takes no guard flag)"
  info "ok: legacy recovery retry"

  # Legacy path: recovery release carries --saved-at (and refuses a
  # credential-shaped one before running anything, as on the contract path).
  run_operate --context rpi5 plain recovery-release att-7 --saved-at shelf-303
  [ "$CODE" -eq 0 ] || fail "legacy-recovery-release: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-legacy0000000003" "legacy-recovery-release"
  grep -q 'agentctl recovery release att-7 --saved-at shelf-303' "$ARGV_LOG" || fail "legacy-recovery-release: no 'agentctl recovery release att-7 --saved-at shelf-303' in argv"
  assert_not_contains "$ARGV_LOG" "expect-repo" "legacy-recovery-release (legacy recovery takes no guard flag)"
  run_operate --context rpi5 plain recovery-release att-7 --saved-at "ghp_0123456789abcdef0123456789abcdef0123"
  [ "$CODE" -eq 2 ] || fail "legacy-recovery-release-secret: exit $CODE, want 2"
  assert_contains "$WORK_ROOT/err.txt" "looks like a credential" "legacy-recovery-release-secret"
  if grep -q 'agentctl recovery release' "$ARGV_LOG"; then
    fail "legacy-recovery-release-secret: nothing may run with a credential-shaped --saved-at"
  fi
  info "ok: legacy recovery release"

  # Legacy path: errors reset.
  run_operate --context rpi5 plain errors-reset
  [ "$CODE" -eq 0 ] || fail "legacy-errors-reset: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "request_id:      req-legacy0000000004" "legacy-errors-reset"
  grep -q 'agentctl errors reset' "$ARGV_LOG" || fail "legacy-errors-reset: no 'agentctl errors reset' in argv"
  info "ok: legacy errors reset"

  # Legacy path: command lookup reads the stored command.
  run_operate --context rpi5 plain command req-legacy0000000001
  [ "$CODE" -eq 0 ] || fail "legacy-command: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "acknowledgement: completed" "legacy-command"
  grep -q 'agentctl command req-legacy0000000001' "$ARGV_LOG" || fail "legacy-command: no agentctl command argv"
  info "ok: legacy command lookup"

  # Follow-up hints repeat --context/--worker when given (contract accepted).
  export CONTRACT_IDENTITY_FIXTURE=identity-full.json
  export CONTRACT_STATUS_FIXTURE=stop-accepted.json
  run_operate --context rpi5 --worker 1 foo stop --request-id req-follow01aa02bb
  [ "$CODE" -eq 0 ] || fail "follow-flags: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "follow up:" "follow-flags"
  assert_contains "$WORK_ROOT/out.txt" "--context rpi5" "follow-flags (context repeated)"
  assert_contains "$WORK_ROOT/out.txt" "--worker 1" "follow-flags (worker repeated)"
  assert_contains "$WORK_ROOT/out.txt" "command req-follow01aa02bb" "follow-flags (same ID)"
  info "ok: contract accepted follow-up repeats --context/--worker"

  # Without the selectors the hint contains neither flag.
  run_operate foo stop --request-id req-follow02bb03cc
  [ "$CODE" -eq 0 ] || fail "follow-noflags: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "follow up:" "follow-noflags"
  assert_not_contains "$WORK_ROOT/out.txt" "--context" "follow-noflags (no context flag)"
  assert_not_contains "$WORK_ROOT/out.txt" "--worker" "follow-noflags (no worker flag)"
  info "ok: contract accepted follow-up omits flags when not given"

  # Legacy follow-up repeats the selectors when given, omits them otherwise.
  unset CONTRACT_STATUS_FIXTURE
  unset CONTRACT_IDENTITY_FIXTURE
  unset CONTRACT_COMMAND_FIXTURE
  run_operate --context rpi5 --worker 1 plain stop
  [ "$CODE" -eq 0 ] || fail "legacy-follow-flags: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "follow up:" "legacy-follow-flags"
  assert_contains "$WORK_ROOT/out.txt" "--context rpi5" "legacy-follow-flags (context repeated)"
  assert_contains "$WORK_ROOT/out.txt" "--worker 1" "legacy-follow-flags (worker repeated)"
  info "ok: legacy follow-up repeats --context/--worker"
  run_operate plain stop
  [ "$CODE" -eq 0 ] || fail "legacy-follow-noflags: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "follow up:" "legacy-follow-noflags"
  assert_not_contains "$WORK_ROOT/out.txt" "--context" "legacy-follow-noflags (no context flag)"
  assert_not_contains "$WORK_ROOT/out.txt" "--worker" "legacy-follow-noflags (no worker flag)"
  info "ok: legacy follow-up omits flags when not given"

  # Malformed stdout follow-up repeats the selectors when given. Force the
  # helper's malformed branch (non-envelope mutation stdout) with a fake
  # agentfleet that answers the mutation with garbage but delegates
  # everything else (identity) to the real client.
  export CONTRACT_IDENTITY_FIXTURE=identity-full.json
  _real_agentfleet=$(command -v agentfleet)
  mkdir -p "$WORK_ROOT/fakebin"
  cat >"$WORK_ROOT/fakebin/agentfleet" <<EOF
#!/bin/sh
case " \$* " in
  *" req-follow03cc04dd "*|*" req-follow04dd05ee "*) printf 'not json at all\n'; exit 1 ;;
esac
exec "$_real_agentfleet" "\$@"
EOF
  chmod +x "$WORK_ROOT/fakebin/agentfleet"
  # shellcheck disable=SC2031 # PATH save/restore around the fake agentfleet above
  _saved_path=$PATH
  # shellcheck disable=SC2031 # fake agentfleet first on PATH for two run_operate calls
  export PATH="$WORK_ROOT/fakebin:$PATH"
  run_operate --context rpi5 --worker 1 foo stop --request-id req-follow03cc04dd
  [ "$CODE" -ne 0 ] || fail "malformed-follow-flags: exit 0, want non-zero"
  if ! grep -q 'malformed' "$WORK_ROOT/err.txt"; then
    grep -q 'malformed' "$WORK_ROOT/out.txt" || fail "malformed-follow-flags: expected 'malformed' in output"
  fi
  assert_contains "$WORK_ROOT/err.txt" "--context rpi5" "malformed-follow-flags (context repeated)"
  assert_contains "$WORK_ROOT/err.txt" "--worker 1" "malformed-follow-flags (worker repeated)"
  assert_contains "$WORK_ROOT/err.txt" "req-follow03cc04dd" "malformed-follow-flags (same ID)"
  info "ok: malformed stdout follow-up repeats --context/--worker"
  run_operate foo stop --request-id req-follow04dd05ee
  # shellcheck disable=SC2031 # restore the saved PATH
  export PATH="$_saved_path"
  [ "$CODE" -ne 0 ] || fail "malformed-follow-noflags: exit 0, want non-zero"
  assert_contains "$WORK_ROOT/err.txt" "req-follow04dd05ee" "malformed-follow-noflags (same ID)"
  assert_not_contains "$WORK_ROOT/err.txt" "--context" "malformed-follow-noflags (no context flag)"
  assert_not_contains "$WORK_ROOT/err.txt" "--worker" "malformed-follow-noflags (no worker flag)"
  info "ok: malformed stdout follow-up omits flags when not given"

  # No container on the selected context: names the context, suggests
  # --context, and never assumes the legacy path or a mutation.
  mkdir -p "$T_INSTANCES/agent-nocont"
  cat >"$T_INSTANCES/agent-nocont/compose.yaml" <<'EOF'
services:
  agent:
    image: nocont-image:latest
EOF
  printf 'TARGET_REPO=example-owner/example-repo\n' >"$T_INSTANCES/agent-nocont/.env"
  mkdir -p "$SCENE/agent-nocont"
  : >"$SCENE/agent-nocont/ps-agent.txt"
  : >"$SCENE/agent-nocont/ps-PROJECT.txt"
  run_operate --context rpi5 nocont stop --request-id req-nocont01aa02
  [ "$CODE" -ne 0 ] || fail "no-container: exit 0, want non-zero"
  assert_contains "$WORK_ROOT/err.txt" "no container" "no-container (names the miss)"
  assert_contains "$WORK_ROOT/err.txt" "rpi5" "no-container (names the context)"
  assert_contains "$WORK_ROOT/err.txt" "--context" "no-container (suggests --context)"
  assert_not_contains "$WORK_ROOT/out.txt" "legacy agentctl" "no-container (no legacy path)"
  assert_not_contains "$WORK_ROOT/err.txt" "legacy agentctl" "no-container (no legacy path)"
  assert_not_contains "$WORK_ROOT/out.txt" "unlabelled" "no-container (no unlabelled)"
  assert_not_contains "$WORK_ROOT/err.txt" "unlabelled" "no-container (no unlabelled)"
  info "ok: no container reports only the miss"
  run_operate --context rpi5 nocont command req-legacy0000000001
  [ "$CODE" -ne 0 ] || fail "no-container-command: exit 0, want non-zero"
  assert_contains "$WORK_ROOT/err.txt" "no container" "no-container-command"
  assert_not_contains "$WORK_ROOT/out.txt" "legacy agentctl" "no-container-command (no legacy path)"
  assert_not_contains "$WORK_ROOT/err.txt" "legacy agentctl" "no-container-command (no legacy path)"
  assert_not_contains "$WORK_ROOT/out.txt" "mutation" "no-container-command (no mutation mention)"
  assert_not_contains "$WORK_ROOT/err.txt" "mutation" "no-container-command (no mutation mention)"
  info "ok: no container command read stays mutation-free"

  # A mutation against a labelled but non-running container is refused before
  # any agentfleet call and before identity, with no request_id line.
  printf 'exited|1|2026-11-10T10:00:00Z|foo-image:latest\n' >"$SCENE/agent-foo/inspect-agent-foo-agent-1.txt"
  python3 - "$SCENE/fleet.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
for c in doc.get("containers", []):
    if c.get("name") == "foo":
        c["state"] = "exited"
json.dump(doc, open(path, "w"))
PYEOF
  export CONTRACT_IDENTITY_FIXTURE=identity-full.json
  export CONTRACT_STATUS_FIXTURE=stop-accepted.json
  run_operate --context rpi5 foo stop --request-id req-stopped01aa02
  [ "$CODE" -eq 1 ] || fail "stopped-refusal: exit $CODE, want 1"
  assert_not_contains "$WORK_ROOT/out.txt" "request_id:" "stopped-refusal (no request ID printed)"
  assert_contains "$WORK_ROOT/err.txt" "exited" "stopped-refusal (states the container state)"
  assert_contains "$WORK_ROOT/err.txt" "nothing was submitted" "stopped-refusal (nothing submitted)"
  assert_contains "$WORK_ROOT/err.txt" "never sent to a stopped instance" "stopped-refusal (never sent)"
  assert_contains "$WORK_ROOT/err.txt" "debug-agent" "stopped-refusal (offline read)"
  assert_contains "$WORK_ROOT/err.txt" "separate deployment action" "stopped-refusal (starting is separate)"
  if grep -q -- '--contract 1' "$ARGV_LOG"; then
    fail "stopped-refusal: refused before any agentfleet call (no --contract 1 in argv)"
  fi
  info "ok: stopped instance refused before submission"
  # Restore the running fixture for the safety-net case below.
  printf 'running|0|2026-11-10T10:00:00Z|foo-image:latest\n' >"$SCENE/agent-foo/inspect-agent-foo-agent-1.txt"

  # Safety net: the container stopped between the running check and the
  # submission (inspect says running, Fleet says stopped). agentfleet
  # refuses client-side; the helper reports nothing submitted with no
  # same-ID command follow-up.
  python3 - "$SCENE/fleet.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
for c in doc.get("containers", []):
    if c.get("name") == "foo":
        c["state"] = "exited"
json.dump(doc, open(path, "w"))
PYEOF
  run_operate --context rpi5 foo stop --request-id req-safety01bb03
  [ "$CODE" -eq 1 ] || fail "instance-stopped: exit $CODE, want 1"
  assert_contains "$WORK_ROOT/err.txt" "client.instance_stopped" "instance-stopped (code reported)"
  assert_contains "$WORK_ROOT/err.txt" "nothing was stored" "instance-stopped (nothing stored)"
  assert_contains "$WORK_ROOT/err.txt" "request ID was not used" "instance-stopped (ID not used)"
  assert_contains "$WORK_ROOT/err.txt" "never sent to a stopped instance" "instance-stopped (never sent)"
  assert_contains "$WORK_ROOT/err.txt" "debug-agent" "instance-stopped (offline read)"
  assert_not_contains "$WORK_ROOT/err.txt" "ambiguous outcome" "instance-stopped (never ambiguous)"
  if grep -q -- '--contract 1 command' "$ARGV_LOG"; then
    fail "instance-stopped: no same-ID command follow-up may run"
  fi
  info "ok: client.instance_stopped safety net (nothing submitted, no follow-up)"
  python3 - "$SCENE/fleet.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
for c in doc.get("containers", []):
    if c.get("name") == "foo":
        c["state"] = "running"
json.dump(doc, open(path, "w"))
PYEOF

  info "PASS: operate-agent helper behaves as specified (fixtures from the pinned tag, no copies)"
}

main
