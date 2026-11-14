#!/bin/sh
# contract-attempts.sh -- pin the contract-path Attempts listing and export.
#
# Covers adoption step 2 of the operator contract (agent-forge part): with an
# issue number, locate-agent lists that issue's Attempts from `attempts ls`
# (filtered by issue on the client side, paged with the opaque cursor, native
# outcome, delivery, attention_required, sealed); fetch-run exports an Attempt
# Archive through `agentfleet attempts export` into a separate contract cache
# (only Sealed archives reused after sha256 verification, unsealed refetched
# and labelled as moving snapshots, a sha256 mismatch fetched again, Offline
# Read for a stopped container, safe unique paths for `#`/`/` Attempt IDs).
#
# Usage (from anywhere in this repository):
#
#   .agents/skills/debug-agent/tests/contract-attempts.sh
#
# Hermeticity: HOME points at a scratch dir, AGENT_INSTANCES_DIR and (per
# case) AGENT_CONTRACT_CACHE at scratch fixtures, PATH starts with
# tests/stub/bin (fake docker plus a gh that fails if ever called).
# CONTRACT_FIXTURES_DIR points at the fixtures of the pinned
# agent-operator-contract tag (the installed package matching CONTRACT_TAG,
# or a checkout via CONTRACT_CHECKOUT); list pages and show envelopes for the
# suite's Attempts are symlinks into those pinned fixtures (never copied) or
# synthesized scene files like fleet.json; export tars are synthesized by the
# stub from scene archive dirs. Shell internals are not tested: only exit
# status, stdout/stderr content and the stub's argv log (no `docker cp`, no
# legacy file reads on the contract path).

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
  printf 'contract-attempts: %s\n' "$*"
}

fail() {
  printf 'contract-attempts: FAIL: %s\n' "$*" >&2
  exit 1
}

setup_fixture() {
  T_INSTANCES="$WORK_ROOT/instances"
  T_HOME="$WORK_ROOT/home"
  ARGV_LOG="$WORK_ROOT/argv.log"
  ERROR_LOG="$WORK_ROOT/stub-errors.log"
  : >"$ARGV_LOG"
  : >"$ERROR_LOG"

  mkdir -p "$T_HOME/OrbStack/docker/volumes/agent-foo_agent_data" "$T_HOME/OrbStack/docker/volumes/agent-plain_agent_data"
  mkdir -p "$T_INSTANCES/agent-foo" "$T_INSTANCES/agent-plain" "$T_INSTANCES/agent-cw"
  cat >"$T_INSTANCES/agent-foo/compose.yaml" <<'EOF'
services:
  agent:
    image: foo-image:latest
    labels:
      io.github.lbacik.agent-operator.contract: "1"
      io.github.lbacik.agent-operator.instance: "foo"
      io.github.lbacik.agent-operator.exec-user: "agent"
      io.github.lbacik.agent-operator.backend: "coding-agent"
EOF
  cat >"$T_INSTANCES/agent-plain/compose.yaml" <<'EOF'
services:
  agent:
    image: plain-image:latest
EOF
  cat >"$T_INSTANCES/agent-cw/compose.yaml" <<'EOF'
services:
  agent:
    image: coding-agent-seat:latest
  validate:
    image: coding-agent-validate:latest
  worker:
    image: cw-image:latest
    labels:
      io.github.lbacik.agent-operator.contract: "1"
      io.github.lbacik.agent-operator.instance: "cw"
      io.github.lbacik.agent-operator.exec-user: "agent"
      io.github.lbacik.agent-operator.backend: "coding-agent"
EOF
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-foo/.env"
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-plain/.env"
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-cw/.env"

  SCENE="$WORK_ROOT/scene"
  mkdir -p "$SCENE/agent-foo" "$SCENE/agent-plain" "$SCENE/agent-cw"
  printf 'agent-foo-agent-1\n' >"$SCENE/agent-foo/ps-agent.txt"
  printf 'agent-foo-agent-1\n' >"$SCENE/agent-foo/ps-PROJECT.txt"
  printf 'running|0|2026-11-06T10:00:00Z|foo-image:latest\n' >"$SCENE/agent-foo/inspect-agent-foo-agent-1.txt"
  printf '1\n' >"$SCENE/agent-foo/contract-label-agent-foo-agent-1.txt"
  printf 'agent-plain-agent-1\n' >"$SCENE/agent-plain/ps-agent.txt"
  printf 'agent-plain-agent-1\n' >"$SCENE/agent-plain/ps-PROJECT.txt"
  printf 'running|0|2026-11-06T10:00:00Z|plain-image:latest\n' >"$SCENE/agent-plain/inspect-agent-plain-agent-1.txt"
  # Worker-layout instance: only `worker` carries the discovery labels; the
  # unlabelled `agent`/`validate` seats have no container and are never
  # addressed (no ps-agent.txt here, so a seat lookup fails loudly).
  printf 'agent-cw-worker-1\n' >"$SCENE/agent-cw/ps-worker.txt"
  printf 'agent-cw-worker-1\n' >"$SCENE/agent-cw/ps-PROJECT.txt"
  printf 'running|0|2026-11-06T10:00:00Z|cw-image:latest\n' >"$SCENE/agent-cw/inspect-agent-cw-worker-1.txt"
  printf '1\n' >"$SCENE/agent-cw/contract-label-agent-cw-worker-1.txt"
  cat >"$SCENE/fleet.json" <<'EOF'
{"containers": [
  {"id": "cid-foo-1", "name": "foo", "backend": "coding-agent", "contract": "1", "exec_user": "agent", "state": "running", "image": "foo-image:latest", "volumes": [{"name": "agent-foo_agent_data", "path": "/data"}]},
  {"id": "cid-cw-1", "name": "cw", "backend": "coding-agent", "contract": "1", "exec_user": "agent", "state": "running", "image": "cw-image:latest"}
]}
EOF

  # Attempts list pages, synthesized in the scene like fleet.json: the
  # first page holds the unsealed attempt plus an opaque cursor, the second
  # page the sealed attempt and no further cursor. The attempt summaries
  # come from the pinned show fixtures, so list, show and export agree.
  CURSOR="eyJvZmZzZXQ6MX0="
  CURSOR_SAN=$(printf '%s' "$CURSOR" | tr -c 'A-Za-z0-9' '_')
  export CURSOR CURSOR_SAN
  python3 - "$FIXDIR/attempts-show-unsealed.json" "$FIXDIR/attempts-show-sealed.json" \
      "$SCENE/attempts-list.json" "$SCENE/attempts-list-before-$CURSOR_SAN.json" "$CURSOR" <<'PYEOF'
import json, sys
unsealed = json.loads(json.load(open(sys.argv[1]))["stdout"])["result"]["attempt"]
sealed = json.loads(json.load(open(sys.argv[2]))["stdout"])["result"]["attempt"]
first = {"contract": "1.0", "ok": True,
         "result": {"attempts": [unsealed], "next_cursor": sys.argv[5]}}
second = {"contract": "1.0", "ok": True,
          "result": {"attempts": [sealed], "next_cursor": None}}
open(sys.argv[3], "w").write(json.dumps(first) + "\n")
open(sys.argv[4], "w").write(json.dumps(second) + "\n")
PYEOF

  # Show envelopes are the pinned fixtures (never copied): #41/1 sealed,
  # #42/1 unsealed (sanitized `#`/`/` -> `_`).
  ln -s "$FIXDIR/attempts-show-sealed.json" "$SCENE/attempts-show-_41_1.json"
  ln -s "$FIXDIR/attempts-show-unsealed.json" "$SCENE/attempts-show-_42_1.json"

  # Archive sources the stub synthesizes export tars from. The attempt
  # summaries come from the pinned show fixtures, so export and show agree.
  for pair in _41_1:attempts-show-sealed.json _42_1:attempts-show-unsealed.json; do
    safe=${pair%%:*}
    fix=${pair#*:}
    python3 - "$FIXDIR/$fix" "$SCENE/archive-$safe.json" <<'PYEOF'
import json, sys
show = json.load(open(sys.argv[1]))
attempt = json.loads(show["stdout"])["result"]["attempt"]
kinds = {"events.jsonl": {"kind": "events", "media_type": "application/x-ndjson"}}
if attempt["attempt_id"] == "#41/1":
    kinds["transcript.jsonl"] = {"kind": "transcript", "media_type": "application/x-ndjson"}
json.dump({"attempt": attempt, "file_kinds": kinds}, open(sys.argv[2], "w"), indent=1)
PYEOF
    mkdir -p "$SCENE/archive-$safe"
    printf '%s\n' '{"at":"2026-11-06T08:50:00Z","level":"info","event":"claim_opened","text":"claimed issue","attempt_id":"'"$(python3 -c 'import json; print(json.load(open("'"$SCENE"'/archive-'"$safe"'.json"))["attempt"]["attempt_id"])')"'"}' >"$SCENE/archive-$safe/events.jsonl"
    if [ "$safe" = "_41_1" ]; then
      printf '%s\n' '{"role":"assistant","content":"done"}' >"$SCENE/archive-$safe/transcript.jsonl"
    fi
  done

  # Stopped scene: the same Attempts, but the container is stopped, so every
  # contract read goes through Offline Read (`docker run ... --offline`).
  STOPPED="$WORK_ROOT/stopped"
  mkdir -p "$STOPPED/agent-foo"
  printf 'agent-foo-agent-1\n' >"$STOPPED/agent-foo/ps-agent.txt"
  printf 'agent-foo-agent-1\n' >"$STOPPED/agent-foo/ps-PROJECT.txt"
  printf 'exited|1|2026-11-06T11:00:00Z|foo-image:latest\n' >"$STOPPED/agent-foo/inspect-agent-foo-agent-1.txt"
  printf '1\n' >"$STOPPED/agent-foo/contract-label-agent-foo-agent-1.txt"
  cat >"$STOPPED/fleet.json" <<'EOF'
{"containers": [
  {"id": "cid-foo-1", "name": "foo", "backend": "coding-agent", "contract": "1", "exec_user": "agent", "state": "exited", "image": "foo-image:latest", "volumes": [{"name": "agent-foo_agent_data", "path": "/data"}]}
]}
EOF
  for f in attempts-list.json attempts-list-before-$CURSOR_SAN.json attempts-show-_41_1.json attempts-show-_42_1.json; do
    ln -s "$SCENE/$f" "$STOPPED/$f"
  done
  for safe in _41_1 _42_1; do
    ln -s "$SCENE/archive-$safe.json" "$STOPPED/archive-$safe.json"
    ln -s "$SCENE/archive-$safe" "$STOPPED/archive-$safe"
  done
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
  [ -f "$FIXDIR/attempts-show-sealed.json" ] || fail "fixtures missing attempts-show-sealed.json in $FIXDIR"
  [ -f "$FIXDIR/attempts-show-unsealed.json" ] || fail "fixtures missing attempts-show-unsealed.json in $FIXDIR"
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
  if grep -q -- '-v .*_data.*:ro' "$ARGV_LOG"; then
    fail "$1: contract path mounted a volume read-only (a legacy file read)"
  fi
  if grep -q 'agentctl status' "$ARGV_LOG" && ! grep -q -- '--contract' "$ARGV_LOG"; then
    fail "$1: contract path ran legacy 'agentctl status'"
  fi
}

export_count() {
  grep -c -- 'attempts export' "$ARGV_LOG" || true
}

main() {
  WORK_ROOT=$(mktemp -d) || fail "cannot create a scratch directory"
  trap 'rm -rf "$WORK_ROOT"' EXIT INT TERM

  resolve_fixtures
  setup_fixture
  export CONTRACT_FIXTURES_DIR="$FIXDIR"

  export HOME="$T_HOME"
  export AGENT_INSTANCES_DIR="$T_INSTANCES"
  export STUB_ARGV_LOG="$ARGV_LOG"
  export STUB_ERROR_LOG="$ERROR_LOG"
  export STUB_SCENARIO_DIR="$WORK_ROOT/scene"
  export STUB_VOLUMES_ROOT="$T_HOME/OrbStack/docker/volumes"
  export STUB_PROJECTS="agent-foo agent-plain agent-cw"
  export STUB_LIB
  export PATH="$STUB_BIN:$PATH"

  [ "$(command -v docker)" = "$STUB_BIN/docker" ] || fail "stub docker is not first on PATH"

  command -v agentfleet >/dev/null 2>&1 || fail "agentfleet is not installed; install from the pinned tag"
  info "agentfleet version: $(agentfleet --version 2>/dev/null || true)"

  export CONTRACT_IDENTITY_FIXTURE=identity.json
  export CONTRACT_STATUS_FIXTURE=status-active.json

  # Listing: that issue's Attempts across pages of `attempts ls`, with the
  # native outcome, delivery, attention_required and sealed.
  export AGENT_CONTRACT_CACHE="$WORK_ROOT/cache-listing"
  run_helper locate-agent.sh --context rpi5 foo 42
  [ "$CODE" -eq 0 ] || fail "locate 42: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "attempts_for_issue_42:" "locate 42"
  assert_contains "$WORK_ROOT/out.txt" "#42/1" "locate 42"
  assert_contains "$WORK_ROOT/out.txt" "delivered" "locate 42 native outcome"
  assert_contains "$WORK_ROOT/out.txt" "delivery none" "locate 42 open attempt has no delivery yet"
  assert_contains "$WORK_ROOT/out.txt" "attention_required false" "locate 42"
  assert_contains "$WORK_ROOT/out.txt" "sealed false" "locate 42"
  assert_contains "$WORK_ROOT/out.txt" "moving snapshot" "locate 42 unsealed label"
  assert_contains "$WORK_ROOT/out.txt" "attempts for issue #42: #42/1" "locate 42 report names the native Attempt ID"
  assert_contains "$WORK_ROOT/out.txt" "managed_instance: foo" "locate 42 report"
  assert_contains "$WORK_ROOT/out.txt" "backend:" "locate 42 report"
  if ! grep -q -- "--before $CURSOR" "$ARGV_LOG"; then
    fail "locate 42: the opaque cursor did not page (no --before in $(cat "$ARGV_LOG"))"
  fi
  if sed -n '/^attempts_for_issue_42:/,/^report:/p' "$WORK_ROOT/out.txt" | grep -q '#41/1'; then
    fail "locate 42 filters by issue on the client side: #41/1 leaked into the issue-42 section"
  fi
  assert_no_file_reads "locate 42"
  info "ok: listing pages with the opaque cursor and filters by issue"

  run_helper locate-agent.sh --context rpi5 foo 41
  [ "$CODE" -eq 0 ] || fail "locate 41: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "#41/1" "locate 41"
  assert_contains "$WORK_ROOT/out.txt" "sealed true" "locate 41"
  assert_contains "$WORK_ROOT/out.txt" "Sealed" "locate 41"
  assert_contains "$WORK_ROOT/out.txt" "PR #77" "locate 41 delivery"
  if sed -n '/^attempts_for_issue_41:/,/^report:/p' "$WORK_ROOT/out.txt" | grep -q '#42/1'; then
    fail "locate 41 filters by issue on the client side: #42/1 leaked into the issue-41 section"
  fi
  info "ok: listing shows the sealed attempt"

  # Export: an unsealed archive is a moving snapshot, fetched again on every
  # request, into a safe cache path under a contract-only root.
  export AGENT_CONTRACT_CACHE="$WORK_ROOT/cache-unsealed"
  run_helper fetch-run.sh --context rpi5 foo 42 latest
  [ "$CODE" -eq 0 ] || fail "fetch unsealed: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "moving snapshot" "fetch unsealed"
  assert_contains "$WORK_ROOT/out.txt" "rpi5/foo/coding-agent/example-owner%2Fexample-repo/%2342%2F1" "fetch unsealed cache path"
  assert_contains "$WORK_ROOT/out.txt" "report: .*context rpi5.*managed instance foo.*backend coding-agent.*example-owner/example-repo.*#42/1" "fetch unsealed report"
  [ "$(export_count)" -ge 1 ] || fail "fetch unsealed: no attempts export in $(cat "$ARGV_LOG")"
  assert_no_file_reads "fetch unsealed"
  _dest42=$(head -n 1 "$WORK_ROOT/out.txt" | awk '{print $1}')
  [ -f "$_dest42/manifest.json" ] || fail "fetch unsealed: no cached manifest.json"
  [ -f "$_dest42/events.jsonl" ] || fail "fetch unsealed: no cached events.jsonl"
  python3 "$SCRIPTS_DIR/lib/verify_archive.py" "$_dest42" || fail "fetch unsealed: cached copy fails verification"
  run_helper fetch-run.sh --context rpi5 foo 42 latest
  [ "$CODE" -eq 0 ] || fail "fetch unsealed again: exit $CODE"
  assert_contains "$WORK_ROOT/out.txt" "moving snapshot" "fetch unsealed again"
  [ "$(export_count)" -ge 1 ] || fail "fetch unsealed again: the moving snapshot was not fetched again"
  info "ok: unsealed exports are moving snapshots under a safe cache path"

  # Export: a sealed archive is cached and reused after sha256 verification;
  # a corrupted cache is fetched again.
  export AGENT_CONTRACT_CACHE="$WORK_ROOT/cache-sealed"
  run_helper fetch-run.sh --context rpi5 foo 41 latest
  [ "$CODE" -eq 0 ] || fail "fetch sealed: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "rpi5/foo/coding-agent/example-owner%2Fexample-repo/%2341%2F1" "fetch sealed cache path"
  assert_not_contains "$WORK_ROOT/out.txt" "moving snapshot" "fetch sealed is not a moving snapshot"
  _dest41=$(head -n 1 "$WORK_ROOT/out.txt" | awk '{print $1}')
  [ -f "$_dest41/manifest.json" ] || fail "fetch sealed: no cached manifest.json"
  [ -f "$_dest41/transcript.jsonl" ] || fail "fetch sealed: no cached transcript.jsonl"
  run_helper fetch-run.sh --context rpi5 foo 41 latest
  [ "$CODE" -eq 0 ] || fail "fetch sealed again: exit $CODE"
  assert_contains "$WORK_ROOT/out.txt" "(cached, sealed, verified)" "fetch sealed again reuses the cache"
  [ "$(export_count)" -eq 0 ] || fail "fetch sealed again: the sealed archive was exported again: $(cat "$ARGV_LOG")"
  printf 'corrupted\n' >>"$_dest41/events.jsonl"
  run_helper fetch-run.sh --context rpi5 foo 41 latest
  [ "$CODE" -eq 0 ] || fail "fetch sealed corrupted: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  [ "$(export_count)" -ge 1 ] || fail "fetch sealed corrupted: the cache failed verification but was not fetched again"
  python3 "$SCRIPTS_DIR/lib/verify_archive.py" "$_dest41" || fail "fetch sealed corrupted: refetched copy fails verification"
  info "ok: sealed exports are reused after sha256 verification, corruption refetches"

  # Export: a sha256 mismatch in an unsealed export is a torn read and is
  # fetched again (agentfleet refetches within its bound; the helper succeeds).
  export AGENT_CONTRACT_CACHE="$WORK_ROOT/cache-torn"
  touch "$WORK_ROOT/scene/export-torn-once-_42_1"
  run_helper fetch-run.sh --context rpi5 foo 42 '#42/1'
  [ "$CODE" -eq 0 ] || fail "fetch torn: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  [ "$(export_count)" -ge 2 ] || fail "fetch torn: one torn export did not trigger a refetch: $(cat "$ARGV_LOG")"
  assert_contains "$WORK_ROOT/out.txt" "moving snapshot" "fetch torn"
  info "ok: a sha256 mismatch is fetched again"

  # Export: a stopped container is read through Offline Read, with no
  # `docker cp` and no legacy throwaway container.
  export STUB_SCENARIO_DIR="$WORK_ROOT/stopped"
  export AGENT_CONTRACT_CACHE="$WORK_ROOT/cache-offline"
  run_helper fetch-run.sh --context rpi5 foo 41 latest
  [ "$CODE" -eq 0 ] || fail "fetch offline: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "%2341%2F1" "fetch offline"
  if ! grep -q -- '--offline' "$ARGV_LOG"; then
    fail "fetch offline: no Offline Read in $(cat "$ARGV_LOG")"
  fi
  if ! grep -q 'docker run .*attempts export' "$ARGV_LOG"; then
    fail "fetch offline: no offline attempts export in $(cat "$ARGV_LOG")"
  fi
  assert_no_file_reads "fetch offline"
  export STUB_SCENARIO_DIR="$WORK_ROOT/scene"
  info "ok: Offline Read is used for a stopped container"

  # The contract cache root is separate from the legacy cache: the default
  # root (no AGENT_CONTRACT_CACHE override) lives next to the legacy cache
  # under contract-attempts/, never under a logs/ dir.
  unset AGENT_CONTRACT_CACHE
  run_helper fetch-run.sh --context rpi5 foo 41 latest
  [ "$CODE" -eq 0 ] || fail "fetch default root: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" ".cache/simple-coding-agent-env/contract-attempts/rpi5/foo/" "fetch default root"
  assert_not_contains "$WORK_ROOT/out.txt" "/logs/" "fetch default root stays out of the legacy cache"
  info "ok: the contract cache root is separate from the legacy cache"

  # Worker-layout instance: fetch goes through the contract path under the
  # Managed Instance name, never through a legacy host path.
  export AGENT_CONTRACT_CACHE="$WORK_ROOT/cache-cw"
  run_helper fetch-run.sh --context rpi5 cw 42 latest
  [ "$CODE" -eq 0 ] || fail "fetch cw: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  assert_contains "$WORK_ROOT/out.txt" "rpi5/cw/coding-agent/example-owner%2Fexample-repo/%2342%2F1" "fetch cw cache path"
  assert_contains "$WORK_ROOT/out.txt" "managed instance cw" "fetch cw report"
  assert_contains "$WORK_ROOT/out.txt" "backend coding-agent" "fetch cw report"
  assert_not_contains "$WORK_ROOT/out.txt" "agent_data" "fetch cw (no legacy host path)"
  assert_not_contains "$WORK_ROOT/out.txt" "host_data" "fetch cw (no legacy host path)"
  assert_not_contains "$WORK_ROOT/out.txt" "legacy" "fetch cw (contract path only)"
  if ! grep -q 'service=worker' "$ARGV_LOG"; then
    fail "fetch cw: no service=worker lookup in $(cat "$ARGV_LOG")"
  fi
  assert_not_contains "$ARGV_LOG" "service=agent" "fetch cw (the seat is never addressed)"
  assert_no_file_reads "fetch cw"
  info "ok: worker-layout fetch takes the contract path"

  # Unlabelled containers stay on the legacy path with today's output.
  unset CONTRACT_STATUS_FIXTURE
  unset CONTRACT_IDENTITY_FIXTURE
  run_helper locate-agent.sh --context rpi5 plain
  [ "$CODE" -eq 0 ] || fail "unlabelled: exit $CODE"
  assert_contains "$WORK_ROOT/out.txt" "state_files:" "unlabelled legacy output"
  assert_not_contains "$WORK_ROOT/out.txt" "agentfleet_identity:" "unlabelled must not take the contract path"
  info "ok: unlabelled stays on the legacy path"

  # The log-layout reference documents the backend-neutral archive section
  # with per-backend notes; legacy-only sections are marked for step 5.
  _layout="$ROOT_DIR/.agents/skills/debug-agent/references/log-layout.md"
  for _want in "Attempt Archive" "kind" "media_type" "events.jsonl" "Sealed" \
      "Figure Basis" "simple-coding-agent" "coding-agent" "native_outcome\|native outcome" \
      "outside the contract" "step 5"; do
    grep -qi "$_want" "$_layout" || fail "log-layout reference misses '$_want'"
  done
  info "ok: the log-layout reference covers the backend-neutral archive"

  # Legacy helpers (and their goldens) still pass: the unlabelled `fetch-run`
  # output is unchanged and the extended stub stays clean.
  "$SCRIPT_DIR/legacy-helpers.sh" || fail "legacy-helpers regressed"

  info "PASS: contract-path Attempts listing and export behave as specified"
}

main
