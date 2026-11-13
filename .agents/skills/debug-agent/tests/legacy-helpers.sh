#!/bin/sh
# legacy-helpers.sh -- pin the legacy debug-agent helpers against stubbed Docker.
#
# Runs locate-agent.sh, fetch-run.sh and pool-status.sh for an unlabelled
# simple-coding-agent container with a fake `docker` on PATH (replaying
# recorded replies, no Docker host, no real agent) and checks each helper's
# argv, stdout and exit status against the recorded behaviour. Covers local
# and remote mode, the first Worker and a --worker Worker, a finished vs an
# unfinished attempt in fetch-run, a stopped container, and the resolution
# error paths (no matching instance exits 3, an ambiguous name exits 4, an
# unreadable remote volume exits 5).
#
# Usage (from anywhere in this repository):
#
#   .agents/skills/debug-agent/tests/legacy-helpers.sh
#
# The CI workflow (.github/workflows/legacy-helpers.yml) only calls this
# script. It first parses every skill script with its shebang shell (on
# Ubuntu `sh` is dash, which like macOS `/bin/sh` rejects the #68 pattern)
# and shellchecks them, then runs the behaviour cases below. To pin more
# behaviour, add a fixture or a case plus its golden files under tests/golden
# (stdout/exit via .stdout/.stderr, argv via .argv); to cover a new docker
# reply, add a file under tests/stub/replies/<scenario>/<project>/ (a missing
# reply fails loudly with the exact path, an empty ps reply means the daemon
# lists no container). A new scenario is a new replies subdirectory, selected
# per case through STUB_SCENARIO_DIR; the helpers themselves never change.
#
# The fetch-run cases share one remote cache and run in order: latest fetches
# the unfinished attempt, then the finished attempt is fetched twice (the
# second hit must come from the cache with no `docker cp`), then `all`.
#
# Hermeticity: HOME points at a scratch dir (host volume paths and the remote
# cache land there), AGENT_INSTANCES_DIR at a scratch fixture, and PATH starts
# with tests/stub/bin (fake docker plus a gh that fails if ever called). No
# test reads real credentials (the fixture .env files carry only TARGET_REPO)
# or contacts a real Docker host. Shell internals are not tested: only argv
# (via the stub's log, diffed in full against .argv goldens), stdout (via
# .stdout goldens) and exit status.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
ROOT_DIR=$(cd "$SCRIPT_DIR/../../../.." && pwd) || exit 1
SCRIPTS_DIR="$ROOT_DIR/.agents/skills/debug-agent/scripts"
SKILLS_DIR="$ROOT_DIR/.agents/skills"
STUB_BIN="$SCRIPT_DIR/stub/bin"
STUB_LIB="$SCRIPT_DIR/stub/lib"
SCENARIO_BASE="$SCRIPT_DIR/stub/replies"
GOLDEN_DIR="$SCRIPT_DIR/golden"

WORK_ROOT=""
T_HOME=""
T_INSTANCES=""
ARGV_LOG=""
ERROR_LOG=""
VOLUMES=""
CODE=0

info() {
  printf 'legacy-helpers: %s\n' "$*"
}

fail() {
  printf 'legacy-helpers: FAIL: %s\n' "$*" >&2
  exit 1
}

normalize() {
  sed "s|$WORK_ROOT|@T@|g" "$1"
}

# check_shell_sources -- the parse and lint half of this check: every skill
# script must parse with its shebang shell (the #68 regression class) and
# pass shellcheck at error severity, including the extensionless stub fakes
# on PATH, which the *.sh globs below would otherwise miss.
check_shell_sources() {
  info "parsing every skill script with its shebang shell"
  find "$SKILLS_DIR" -type f -name '*.sh' -exec sh -c 'for f do case $(head -n 1 "$f") in *bash*) bash -n "$f" ;; *) sh -n "$f" ;; esac || exit 1; done' sh {} +
  for f in "$STUB_BIN"/*; do
    sh -n "$f" || fail "stub fake does not parse: $f"
  done
  info "shellchecking skill scripts and stub fakes"
  command -v shellcheck >/dev/null 2>&1 || fail "shellcheck not found on PATH"
  find "$SKILLS_DIR" -type f -name '*.sh' -exec shellcheck -x -P SCRIPTDIR -S error -e SC2148 {} +
  # shellcheck disable=SC2046 # word-splitting the fake list is intended
  shellcheck -x -P SCRIPTDIR -S error -e SC2148 $(find "$STUB_BIN" "$STUB_LIB" -type f) || fail "shellcheck rejects a stub fake"
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
  # The helpers swallow docker failures on several paths (resolve.sh
  # degrades via `|| true`), so a missing recorded reply would otherwise look
  # exactly like "no container". Fail on the stub's error log instead.
  [ ! -s "$ERROR_LOG" ] || fail "stub errors during $name $*: $(cat "$ERROR_LOG")"
}

# Note: POSIX sh has no locals, so every named assignment here is global.
# check_golden deliberately uses _cg_-prefixed names: it runs between the
# caller's other golden checks and must not clobber the caller's $golden.
check_golden() {
  _cg_golden=$1
  _cg_actual=$2
  if diff -u "$GOLDEN_DIR/$_cg_golden" "$_cg_actual"; then
    :
  else
    fail "$_cg_golden: output differs from the golden file (see diff above)"
  fi
}

check_argv() {
  normalize "$ARGV_LOG" >"$WORK_ROOT/got-argv.txt"
  check_golden "$1.argv" "$WORK_ROOT/got-argv.txt"
}

expect_ok() {
  golden=$1
  shift
  run_helper "$@"
  [ "$CODE" -eq 0 ] || fail "$golden: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  [ -s "$WORK_ROOT/err.txt" ] && fail "$golden: unexpected stderr: $(cat "$WORK_ROOT/err.txt")"
  normalize "$WORK_ROOT/out.txt" >"$WORK_ROOT/got.txt"
  check_golden "$golden.stdout" "$WORK_ROOT/got.txt"
  check_argv "$golden"
  info "ok: $golden (exit 0)"
}

expect_fail() {
  golden=$1
  want=$2
  shift 2
  run_helper "$@"
  [ "$CODE" -eq "$want" ] || fail "$golden: exit $CODE, want $want"
  [ -s "$WORK_ROOT/out.txt" ] && fail "$golden: unexpected stdout: $(cat "$WORK_ROOT/out.txt")"
  normalize "$WORK_ROOT/err.txt" >"$WORK_ROOT/got.txt"
  check_golden "$golden.stderr" "$WORK_ROOT/got.txt"
  info "ok: $golden (exit $want)"
}

# expect_fail_out -- like expect_fail, but the helper prints a partial report
# to stdout before failing (locate-agent with an unreadable remote volume).
expect_fail_out() {
  golden=$1
  want=$2
  shift 2
  run_helper "$@"
  [ "$CODE" -eq "$want" ] || fail "$golden: exit $CODE, want $want"
  normalize "$WORK_ROOT/out.txt" >"$WORK_ROOT/got.txt"
  check_golden "$golden.stdout" "$WORK_ROOT/got.txt"
  normalize "$WORK_ROOT/err.txt" >"$WORK_ROOT/got.txt"
  check_golden "$golden.stderr" "$WORK_ROOT/got.txt"
  check_argv "$golden"
  info "ok: $golden (exit $want)"
}

argv_empty() {
  [ ! -s "$ARGV_LOG" ] || fail "argv after $1: expected no docker calls"
}

setup_fixture() {
  T_INSTANCES="$WORK_ROOT/instances"
  T_HOME="$WORK_ROOT/home"
  ARGV_LOG="$WORK_ROOT/argv.log"
  ERROR_LOG="$WORK_ROOT/stub-errors.log"
  VOLUMES="$T_HOME/OrbStack/docker/volumes"
  : >"$ARGV_LOG"

  mkdir -p "$T_INSTANCES/agent-solo" "$T_INSTANCES/agent-duo"
  mkdir -p "$T_INSTANCES/agent-amb-one" "$T_INSTANCES/agent-amb-two"
  cat >"$T_INSTANCES/agent-solo/compose.yaml" <<'EOF'
services:
  agent:
    image: agent-solo-image:latest
EOF
  cat >"$T_INSTANCES/agent-duo/compose.yaml" <<'EOF'
services:
  agent:
    image: agent-duo-image:latest
  agent-2:
    image: agent-duo-image:latest
EOF
  cat >"$T_INSTANCES/agent-amb-one/compose.yaml" <<'EOF'
services:
  agent:
    image: x
EOF
  cat >"$T_INSTANCES/agent-amb-two/compose.yaml" <<'EOF'
services:
  agent:
    image: x
EOF
  # Only the repository line: the fixture carries no credentials, and the
  # cases below never pass --github, so the gh fake must stay silent.
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-solo/.env"
  printf 'TARGET_REPO=testowner/testrepo\n' >"$T_INSTANCES/agent-duo/.env"

  mkdir -p "$VOLUMES/agent-solo_agent_data/state"
  mkdir -p "$VOLUMES/agent-solo_agent_data/logs/42/2026-11-01T10-00-00.000000Z"
  mkdir -p "$VOLUMES/agent-solo_agent_data/logs/42/2026-11-02T10-00-00.000000Z"
  mkdir -p "$VOLUMES/agent-duo_agent_data/state"
  mkdir -p "$VOLUMES/agent-duo_agent_data/logs/7/2026-11-03T10-00-00.000000Z"
  mkdir -p "$VOLUMES/agent-duo_data_2/state"
  mkdir -p "$VOLUMES/agent-duo_data_2/logs/7/2026-11-04T10-00-00.000000Z"
  printf '{"consecutive_errors":0}\n' >"$VOLUMES/agent-solo_agent_data/state/consecutive_errors.json"
  printf '{"consecutive_errors":1}\n' >"$VOLUMES/agent-duo_agent_data/state/consecutive_errors.json"
  printf '{"consecutive_errors":2}\n' >"$VOLUMES/agent-duo_data_2/state/consecutive_errors.json"
  printf '{"outcome":"complete","attempt_kind":"ordinary","duration_seconds":61}\n' \
    >"$VOLUMES/agent-solo_agent_data/logs/42/2026-11-01T10-00-00.000000Z/attempt.json"
  printf '{"attempt_kind":"ordinary","started_at":"2026-11-02T10:00:00Z"}\n' \
    >"$VOLUMES/agent-solo_agent_data/logs/42/2026-11-02T10-00-00.000000Z/attempt.json"
  printf '{"outcome":"complete","attempt_kind":"ordinary","duration_seconds":33}\n' \
    >"$VOLUMES/agent-duo_agent_data/logs/7/2026-11-03T10-00-00.000000Z/attempt.json"
  printf '{"attempt_kind":"ordinary","started_at":"2026-11-04T10:00:00Z"}\n' \
    >"$VOLUMES/agent-duo_data_2/logs/7/2026-11-04T10-00-00.000000Z/attempt.json"

  if grep -rE '^(GITHUB_TOKEN|META_API_KEY|MODEL_API_KEY)=' "$T_INSTANCES" >/dev/null 2>&1; then
    fail "fixture must not set credentials"
  fi
}

main() {
  WORK_ROOT=$(mktemp -d) || fail "cannot create a scratch directory"
  trap 'rm -rf "$WORK_ROOT"' EXIT INT TERM

  check_shell_sources
  setup_fixture

  export HOME="$T_HOME"
  export AGENT_INSTANCES_DIR="$T_INSTANCES"
  export STUB_ARGV_LOG="$ARGV_LOG"
  export STUB_ERROR_LOG="$ERROR_LOG"
  export STUB_SCENARIO_DIR="$SCENARIO_BASE/unlabelled"
  export STUB_VOLUMES_ROOT="$VOLUMES"
  export STUB_PROJECTS="agent-solo agent-duo"
  export STUB_LIB
  export PATH="$STUB_BIN:$PATH"

  [ "$(command -v docker)" = "$STUB_BIN/docker" ] || fail "stub docker is not first on PATH"
  [ "$(command -v gh)" = "$STUB_BIN/gh" ] || fail "stub gh is not first on PATH"

  # locate-agent: local mode, first Worker, without and with an issue (the
  # finished vs unfinished attempts are listed with their outcomes).
  expect_ok locate-solo-local locate-agent.sh solo
  expect_ok locate-solo-local-issue locate-agent.sh solo 42

  # locate-agent: remote mode, first Worker, without and with an issue.
  expect_ok locate-solo-remote locate-agent.sh --context rpi5 solo
  expect_ok locate-solo-remote-issue locate-agent.sh --context rpi5 solo 42

  # locate-agent: remote mode with a stopped container reads /data through a
  # throwaway container (`docker run`) instead of `docker exec`.
  STUB_SCENARIO_DIR="$SCENARIO_BASE/unlabelled-stopped"
  export STUB_SCENARIO_DIR
  expect_ok locate-solo-remote-stopped locate-agent.sh --context rpi5 solo
  STUB_SCENARIO_DIR="$SCENARIO_BASE/unlabelled"
  export STUB_SCENARIO_DIR

  # locate-agent: --worker addressing, local and remote (Worker 2 keeps its
  # own volume and its own remote cache subdirectory).
  expect_ok locate-duo-worker2-local locate-agent.sh --worker 2 duo
  expect_ok locate-duo-worker2-remote locate-agent.sh --context rpi5 --worker duo-2 duo

  # locate-agent: a --worker Worker with no container of its own. Local mode
  # reports the volume as missing; remote mode cannot read it (exit 5).
  expect_ok locate-solo-worker2-local locate-agent.sh --worker 2 solo
  expect_fail_out error-locate-remote-no-container 5 locate-agent.sh --context rpi5 --worker 2 solo

  # locate-agent: N>=2 without --worker lists every Worker instead of guessing.
  expect_ok locate-duo-listing locate-agent.sh duo

  # fetch-run: remote only. Latest is the unfinished attempt; a finished
  # attempt is fetched once, then served from the cache with no `docker cp`.
  expect_ok fetch-solo-latest fetch-run.sh --context rpi5 solo 42
  expect_ok fetch-solo-finished fetch-run.sh --context rpi5 solo 42 2026-11-01T10-00-00.000000Z
  expect_ok fetch-solo-finished-cached fetch-run.sh --context rpi5 solo 42 2026-11-01T10-00-00.000000Z
  expect_ok fetch-solo-all fetch-run.sh --context rpi5 solo 42 all

  # fetch-run: --worker fetches into the Worker's own cache subdirectory.
  expect_ok fetch-duo-worker2 fetch-run.sh --context rpi5 --worker duo-2 duo 7

  # pool-status: one block per Worker from one shared `docker ps` plus one
  # `docker exec` (agentctl status) per running Worker; a stopped container
  # is reported inline and never aborts the rest.
  expect_ok pool-solo-local pool-status.sh solo
  expect_ok pool-solo-remote pool-status.sh --context rpi5 solo
  expect_ok pool-duo-local pool-status.sh duo
  expect_ok pool-duo-remote pool-status.sh --context rpi5 duo
  STUB_SCENARIO_DIR="$SCENARIO_BASE/unlabelled-stopped"
  export STUB_SCENARIO_DIR
  expect_ok pool-solo-stopped pool-status.sh solo
  STUB_SCENARIO_DIR="$SCENARIO_BASE/unlabelled"
  export STUB_SCENARIO_DIR

  # --github Conflict requeue on the legacy path: a live Conflict attempt
  # (marked in the Worker's block with its standing), a queued attempt, a
  # Conflict escalation, and the bare ready-for-human triage label (never
  # listed). Comment reads go only to the candidate issues.
  printf 'MAX_CONFLICT_ATTEMPTS=3\n' >>"$T_INSTANCES/agent-solo/.env"
  printf 'MAX_CONFLICT_ATTEMPTS=3\n' >>"$T_INSTANCES/agent-duo/.env"
  mkdir -p "$WORK_ROOT/gh-views"
  cat >"$WORK_ROOT/gh-conflict-list.txt" <<'EOF'
42 issue
42 conflict merge-conflict
42 assignee some-login
15 issue
15 conflict merge-conflict
9 issue
9 conflict ready-for-human
21 issue
21 conflict ready-for-human
EOF
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
  export STUB_GH_REPLY="$WORK_ROOT/gh-conflict-list.txt"
  export STUB_GH_VIEW_DIR="$WORK_ROOT/gh-views"

  run_helper pool-status.sh --github solo
  [ "$CODE" -eq 0 ] || fail "pool-conflict-solo: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  conflict_assert() {
    grep -q "$1" "$WORK_ROOT/out.txt" || fail "pool-conflict-solo: expected '$1' in pool-status output"
  }
  conflict_assert 'Conflict requeue: MAX_CONFLICT_ATTEMPTS=3 (markers read from any author)'
  conflict_assert 'active_attempt: *issue #42 .* — Conflict attempt (1/3)'
  conflict_assert '#42 live (worker 1) 1/3'
  conflict_assert '#15 queued 2/3'
  conflict_assert '#9 escalated 3/3'
  if grep -q '  #21 ' "$WORK_ROOT/out.txt"; then
    fail "pool-conflict-solo: bare ready-for-human issue #21 must not be listed"
  fi
  [ "$(grep -c 'gh issue view' "$ARGV_LOG")" -eq 4 ] \
    || fail "pool-conflict-solo: comment reads must go to the 4 candidates only"
  grep -q 'gh issue view 42 ' "$ARGV_LOG" || fail "pool-conflict-solo: no comment read for #42"
  info "ok: pool-conflict-solo (live, queued, escalated, triage label ignored)"

  # The same issues from an Instance with no Worker on them: #42 is queued
  # here (no duo Worker is active on it) and no block carries a Conflict mark.
  run_helper pool-status.sh --github duo
  [ "$CODE" -eq 0 ] || fail "pool-conflict-duo: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  grep -q '#42 queued 1/3' "$WORK_ROOT/out.txt" \
    || fail "pool-conflict-duo: expected '#42 queued 1/3' in pool-status output"
  grep -q '#15 queued 2/3' "$WORK_ROOT/out.txt" \
    || fail "pool-conflict-duo: expected '#15 queued 2/3' in pool-status output"
  grep -q '#9 escalated 3/3' "$WORK_ROOT/out.txt" \
    || fail "pool-conflict-duo: expected '#9 escalated 3/3' in pool-status output"
  if grep -q 'Conflict attempt' "$WORK_ROOT/out.txt"; then
    fail "pool-conflict-duo: no Worker block may carry a Conflict mark"
  fi
  info "ok: pool-conflict-duo (queued and escalated, no live attempt)"

  # Requeue off: the header says so, leftover labels are still listed with
  # the stale/historical note.
  grep -v '^MAX_CONFLICT_ATTEMPTS=' "$T_INSTANCES/agent-solo/.env" >"$WORK_ROOT/env-tmp" \
    && cat "$WORK_ROOT/env-tmp" >"$T_INSTANCES/agent-solo/.env"
  run_helper pool-status.sh --github solo
  [ "$CODE" -eq 0 ] || fail "pool-conflict-off: exit $CODE, stderr: $(cat "$WORK_ROOT/err.txt")"
  grep -q 'Conflict requeue: MAX_CONFLICT_ATTEMPTS=0 (requeue off; markers read from any author)' "$WORK_ROOT/out.txt" \
    || fail "pool-conflict-off: expected the requeue-off header"
  grep -q 'stale' "$WORK_ROOT/out.txt" || fail "pool-conflict-off: expected the stale/historical note"
  grep -q 'historical' "$WORK_ROOT/out.txt" || fail "pool-conflict-off: expected the stale/historical note"
  grep -q '#42 live (worker 1)' "$WORK_ROOT/out.txt" \
    || fail "pool-conflict-off: leftover live row must still be listed"
  grep -q '#9 escalated' "$WORK_ROOT/out.txt" \
    || fail "pool-conflict-off: past escalation must still be listed"
  info "ok: pool-conflict-off (requeue off still lists leftovers)"

  # A failed comment read exits 1.
  export STUB_GH_VIEW_FAIL="15"
  run_helper pool-status.sh --github duo
  [ "$CODE" -eq 1 ] || fail "pool-conflict-view-fail: exit $CODE, want 1"
  grep -q 'failed to read comments of issue #15' "$WORK_ROOT/err.txt" \
    || fail "pool-conflict-view-fail: expected the #15 read failure on stderr"
  unset STUB_GH_VIEW_FAIL
  unset STUB_GH_REPLY STUB_GH_VIEW_DIR
  info "ok: pool-conflict-view-fail (failed comment read exits 1)"

  # Resolution error paths keep their exit codes and make no docker calls.
  expect_fail error-no-match 3 locate-agent.sh zzz-no-such
  argv_empty error-no-match
  expect_fail error-ambiguous 4 locate-agent.sh amb
  argv_empty error-ambiguous
  expect_fail error-fetch-no-match 3 fetch-run.sh --context rpi5 zzz-no-such 42
  argv_empty error-fetch-no-match
  expect_fail error-fetch-local 1 fetch-run.sh solo 42
  check_argv error-fetch-local

  info "PASS: legacy helpers behave as recorded (stubbed Docker, no host, no secrets)"
}

main
