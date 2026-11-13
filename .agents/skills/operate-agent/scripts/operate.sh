#!/bin/sh
# operate.sh -- submit one Operator Command to one Worker of an instance.
#
# Usage:
#   operate.sh [--context <ctx>] [--worker <n|worker-id>]
#              [--expect-repo <owner/repo>] [--request-id <id>] [--follow]
#              <name-fragment> <stop [--after <n>]|resume|next-issue <n>|handoff
#                             |recovery-retry <attempt-id>
#                             |recovery-release <attempt-id> --saved-at <location>
#                             |errors-reset|command <request-id>>
#
#   --context     docker context the instance runs on (default: orbstack).
#   --worker      which Worker: a number (2) or a worker id (<short>-2).
#                 Default is the first Worker.
#   --expect-repo Target Repository as owner/name. Default: TARGET_REPO from
#                 the instance env file (simple-coding-agent), else
#                 target.repository from the Workflow Configuration
#                 (coding-agent). Never taken from the instance's identity.
#   --request-id  durable request ID. Default: generated before submission
#                 with agentfleet's own generator.
#   --follow      follow an `accepted` command to its final state
#                 (completed, superseded, not_fulfilled) with `command`
#                 reads using the same request ID. Without it, an accepted
#                 command is reported with its request ID and how to check it.
#   --after <n>   with `stop`: close Intake after N finalized attempts
#                 (1-999, only where the instance advertises `stop-after`).
#   --saved-at <location>
#                 with `recovery-release`: where the retained work was secured
#                 (a shelf, path or URL — never a credential; anything
#                 token- or key-shaped is refused before submission).
#
# Run from anywhere; instances are looked up in agent-forge's agent-instances/.
# Every mutation runs only on the operator's explicit request: invoking this
# helper IS the request. The skill restates the target before it is run.
#
# Contract path (labelled container): every mutation is submitted through
# `agentfleet` with an explicit --expect-repo and --request-id, once
# (--max-attempts 1); an ambiguous outcome is followed up with
# `agentfleet command <instance> <same-id>`, never with a new submission.
# An `accepted` acknowledgement is reported distinctly from the final states.
# `stop` drains (closes Intake) and is never `docker stop`/`docker compose
# stop; `resume` reopens Intake only and never starts a container.
#
# Legacy path (unlabelled container): today's `agentctl` usage, marked
# "legacy agentctl". Goes away when the legacy path is removed.

set -eu

context=""
worker=""
expect_repo=""
request_id=""
follow=0
after=""
saved_at=""
_positionals=""
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --context) context=${2:?--context needs a value}; shift 2 ;;
    --worker) worker=${2:?--worker needs a value}; shift 2 ;;
    --expect-repo) expect_repo=${2:?--expect-repo needs a value}; shift 2 ;;
    --request-id) request_id=${2:?--request-id needs a value}; shift 2 ;;
    --after) after=${2:?--after needs a value (1-999, with 'stop')}; shift 2 ;;
    --saved-at) saved_at=${2:?--saved-at needs a location (with 'recovery-release')}; shift 2 ;;
    --follow) follow=1; shift ;;
    --) shift
      while [ $# -gt 0 ]; do _positionals="$_positionals $1"; shift; done
      ;;
    -*) echo "error: unknown flag '$1'" >&2; exit 2 ;;
    *) _positionals="$_positionals $1"; shift ;;
  esac
done
_usage="usage: operate.sh [options] <name-fragment> <stop [--after <n>]|resume|next-issue <n>|handoff|recovery-retry <attempt-id>|recovery-release <attempt-id> --saved-at <location>|errors-reset|command <request-id>>"
# shellcheck disable=SC2086 # positionals hold no spaces by construction below
set -- $_positionals
fragment=${1:?$_usage}
op=${2:?$_usage}
op_arg=${3:-}
op_extra=${4:-}
[ -z "${5:-}" ] || { echo "error: too many arguments" >&2; exit 2; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
# shellcheck disable=SC1091 # resolved at runtime, not statically
. "$SCRIPT_DIR/../../debug-agent/scripts/lib/resolve.sh"
# shellcheck disable=SC1091 # resolved at runtime, not statically
. "$SCRIPT_DIR/../../debug-agent/scripts/lib/contract.sh"

ENVELOPE="$SCRIPT_DIR/lib/envelope.py"

# --- Operation dispatch and validation -------------------------------------
issue=""
attempt=""
lookup_id=""
required_cap=""
effect=""
case "$op" in
  stop)
    [ -z "$op_arg" ] || { echo "error: usage: operate.sh <name> stop [--after <1-999>]" >&2; exit 2; }
    [ -z "$op_extra" ] || { echo "error: usage: operate.sh <name> stop [--after <1-999>]" >&2; exit 2; }
    [ -z "$saved_at" ] || { echo "error: --saved-at only applies to 'recovery-release'" >&2; exit 2; }
    if [ -n "$after" ]; then
      case "$after" in ''|*[!0-9]*|0) echo "error: --after must be 1-999, got '$after'" >&2; exit 2 ;; esac
      if [ "$after" -gt 999 ]; then echo "error: --after must be 1-999, got '$after'" >&2; exit 2; fi
      required_cap="stop-after"
      effect="close Intake after $after finalized attempts (stop plan)"
    else
      effect="close Intake after the active attempt finishes (drain)"
    fi
    ;;
  resume)
    [ -z "$op_arg" ] || { echo "error: usage: operate.sh <name> resume" >&2; exit 2; }
    [ -z "$op_extra" ] || { echo "error: usage: operate.sh <name> resume" >&2; exit 2; }
    [ -z "$after" ] || { echo "error: --after only applies to 'stop'" >&2; exit 2; }
    [ -z "$saved_at" ] || { echo "error: --saved-at only applies to 'recovery-release'" >&2; exit 2; }
    effect="reopen Intake (never starts a container)"
    ;;
  next-issue)
    issue=${op_arg:?usage: operate.sh <name> next-issue <issue-number>}
    case "$issue" in ''|*[!0-9]*|0) echo "error: issue must be a positive number, got '$issue'" >&2; exit 2 ;; esac
    [ -z "$op_extra" ] || { echo "error: usage: operate.sh <name> next-issue <issue-number>" >&2; exit 2; }
    [ -z "$after" ] || { echo "error: --after only applies to 'stop'" >&2; exit 2; }
    [ -z "$saved_at" ] || { echo "error: --saved-at only applies to 'recovery-release'" >&2; exit 2; }
    required_cap="next-issue"
    effect="one-shot priority: issue #$issue is preferred for the next claim (may end not_fulfilled)"
    ;;
  handoff)
    [ -z "$op_arg" ] || { echo "error: usage: operate.sh <name> handoff" >&2; exit 2; }
    [ -z "$op_extra" ] || { echo "error: usage: operate.sh <name> handoff" >&2; exit 2; }
    [ -z "$after" ] || { echo "error: --after only applies to 'stop'" >&2; exit 2; }
    [ -z "$saved_at" ] || { echo "error: --saved-at only applies to 'recovery-release'" >&2; exit 2; }
    required_cap="operator-handoff"
    effect="complete an Operator Handoff of the active attempt"
    ;;
  recovery-retry)
    attempt=${op_arg:?usage: operate.sh <name> recovery-retry <attempt-id>}
    [ -z "$op_extra" ] || { echo "error: usage: operate.sh <name> recovery-retry <attempt-id>" >&2; exit 2; }
    [ -z "$after" ] || { echo "error: --after only applies to 'stop'" >&2; exit 2; }
    [ -z "$saved_at" ] || { echo "error: --saved-at only applies to 'recovery-release'" >&2; exit 2; }
    required_cap="recovery-retry"
    effect="retry safe finalization of attempt $attempt from retained evidence"
    ;;
  recovery-release)
    attempt=${op_arg:?usage: operate.sh <name> recovery-release <attempt-id> --saved-at <location>}
    [ -z "$op_extra" ] || { echo "error: usage: operate.sh <name> recovery-release <attempt-id> --saved-at <location>" >&2; exit 2; }
    [ -z "$after" ] || { echo "error: --after only applies to 'stop'" >&2; exit 2; }
    [ -n "$saved_at" ] || { echo "error: 'recovery-release' needs --saved-at <location>: where the retained work was secured (never a credential)" >&2; exit 2; }
    required_cap="recovery-release"
    effect="record work for attempt $attempt as secured at $saved_at, release the issue and finalize"
    ;;
  errors-reset)
    [ -z "$op_arg" ] || { echo "error: usage: operate.sh <name> errors-reset" >&2; exit 2; }
    [ -z "$op_extra" ] || { echo "error: usage: operate.sh <name> errors-reset" >&2; exit 2; }
    [ -z "$after" ] || { echo "error: --after only applies to 'stop'" >&2; exit 2; }
    [ -z "$saved_at" ] || { echo "error: --saved-at only applies to 'recovery-release'" >&2; exit 2; }
    required_cap="errors-reset"
    effect="reset the durable infrastructure-error guard"
    ;;
  command)
    lookup_id=${op_arg:?usage: operate.sh <name> command <request-id>}
    [ -z "$op_extra" ] || { echo "error: usage: operate.sh <name> command <request-id>" >&2; exit 2; }
    [ -z "$after" ] || { echo "error: --after only applies to 'stop'" >&2; exit 2; }
    [ -z "$saved_at" ] || { echo "error: --saved-at only applies to 'recovery-release'" >&2; exit 2; }
    effect="read the committed Operator Command $lookup_id"
    ;;
  *) echo "error: unknown operation '$op': expected stop, resume, next-issue, handoff, recovery-retry, recovery-release, errors-reset or command" >&2; exit 2 ;;
esac

# Fail-closed guard: --saved-at names where the work was secured (a shelf,
# path or URL). Refuse anything token- or key-shaped before submission so
# secrets never land in the command store; the refused value is never
# echoed back.
saved_at_is_secret() {
  _s=$1
  case "$_s" in
    ghp_*|gho_*|ghu_*|ghs_*|ghr_*|github_pat_*|sk-*|xoxa-*|xoxb-*|xoxo-*|xoxp-*|xoxs-*|AKIA*|ASIA*|-----BEGIN*|eyJ[A-Za-z0-9_-]*.*) return 0 ;;
  esac
  _low=$(printf '%s' "$_s" | tr '[:upper:]' '[:lower:]')
  case "$_low" in
    *token=*|*secret=*|*passwd=*|*password=*|*api-key=*|*apikey=*|*api_key=*) return 0 ;;
  esac
  if [ "${#_s}" -ge 40 ]; then
    case "$_s" in
      *[[:space:]/]*) return 1 ;;
    esac
    case "$_s" in
      *[!A-Za-z0-9_.+:=/-]*) return 1 ;;
      *) return 0 ;;
    esac
  fi
  return 1
}
if [ -n "$saved_at" ] && saved_at_is_secret "$saved_at"; then
  echo "error: --saved-at looks like a credential (token- or key-shaped); pass the location where the work was secured instead (a shelf, path or URL), never the credential itself" >&2
  exit 2
fi

# Report a final Acknowledgement: completed and superseded are done;
# not_fulfilled is final but explicitly not done (a one-shot priority that
# lost the race or was ineligible), so it is never mistaken for success.
report_final_state() {
  case "$1" in
    completed|superseded) echo "state:           final ($1)" ;;
    not_fulfilled)
      echo "state:           final (not_fulfilled) - not done"
      echo "note:            not_fulfilled is not success: the priority lost the race or was ineligible; re-decide and submit again if still wanted"
      ;;
    *) echo "state:           $1" ;;
  esac
}

case "$expect_repo" in
  ""|*/*) : ;;
  *) echo "error: --expect-repo must be owner/repo, got '$expect_repo'" >&2; exit 2 ;;
esac

# --- Target Repository: flag, else the instance configuration ---------------
# simple-coding-agent keeps TARGET_REPO in the instance env file;
# coding-agent keeps target.repository in its Workflow Configuration.
if [ -z "$expect_repo" ]; then
  env_file="$root/$dir/${AGENT_ENV_FILE:-.env}"
  expect_repo=$(grep -h '^TARGET_REPO=' "$env_file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)
  expect_repo=$(printf '%s' "$expect_repo" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//')
  if [ -z "$expect_repo" ]; then
    wf_repo=$(grep -h -E '^[[:space:]]*repository:' "$root/$dir"/workflow.yml "$root/$dir"/workflow.yaml 2>/dev/null | head -n 1 | sed 's/^[^:]*:[[:space:]]*//;s/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//' || true)
    expect_repo=$wf_repo
  fi
fi
case "$expect_repo" in
  */*) : ;;
  *) echo "error: cannot read the Target Repository for $dir: pass --expect-repo owner/repo" >&2; exit 2 ;;
esac

# --- Request ID: flag, else generated before submission ----------------------
if [ -z "$request_id" ] && [ "$op" != "command" ]; then
  request_id=$(python3 -c 'from agent_operator_contract.client import new_request_id; print(new_request_id())' 2>/dev/null || true)
  if [ -z "$request_id" ]; then
    # Same shape as agentfleet's own generator (req- plus 16 hex digits).
    request_id="req-$(od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%s%s' "$$" "$(date +%s)")"
  fi
fi
if [ "$op" = "command" ]; then
  request_id=$lookup_id
fi
case "$request_id" in
  [A-Za-z0-9][A-Za-z0-9._:-]*|"") : ;;
  *) echo "error: invalid request ID: '$request_id'" >&2; exit 2 ;;
esac
if [ "$op" != "command" ] && [ -z "$request_id" ]; then
  echo "error: cannot establish a request ID" >&2; exit 2
fi

# --- Path selection (same hint as locate-agent.sh) ---------------------------
_use_contract=0
if [ -n "${container:-}" ] && [ -f "$root/$dir/compose.yaml" ] \
  && grep -q "$CONTRACT_LABEL" "$root/$dir/compose.yaml" 2>/dev/null; then
  _label=$(docker inspect -f '{{index .Config.Labels "io.github.lbacik.agent-operator.contract"}}' "$container" 2>/dev/null || true)
  case "$_label" in
    ""|"<no value>") _use_contract=0 ;;
    *) _use_contract=1 ;;
  esac
fi
_managed=$(managed_instance_name "$short" "$worker_num" "${worker_id:-}")

echo "forge_instance:  $dir (short $short)"
echo "managed_instance: $_managed"
echo "docker_context:  $context ($mode)"
echo "target_repo:     $expect_repo"
echo "operation:       $op"
echo "effect:          $effect"

if [ "$_use_contract" -eq 1 ]; then
  echo "path:            contract (agentfleet)"
  if ! require_agentfleet; then
    exit 3
  fi
  echo "container:       ${container:-${project}-${service}-1 (not created)}"

  # Identity pre-flight: refuse an unadvertised operation before submission,
  # listing the advertised Operator Capabilities.
  _idout=$(mktemp) || exit 1
  _iderr=$(mktemp) || { rm -f "$_idout"; exit 1; }
  if agentfleet identity "$_managed" --json >"$_idout" 2>"$_iderr"; then
    :
  else
    _idcode=$?
    cat "$_iderr" >&2 || true
    echo "error: agentfleet identity failed for managed instance '$_managed' (no legacy fallback)" >&2
    rm -f "$_idout" "$_iderr"
    exit "$_idcode"
  fi
  if ! python3 "$ENVELOPE" "$_idout" ok >/dev/null; then
    cat "$_idout" >&2 || true
    echo "error: malformed identity stdout for '$_managed' (no legacy fallback)" >&2
    rm -f "$_idout" "$_iderr"
    exit 7
  fi
  _backend=$(python3 "$ENVELOPE" "$_idout" backend)
  _caps=$(python3 "$ENVELOPE" "$_idout" caps)
  _mode=$(python3 "$ENVELOPE" "$_idout" mode)
  echo "backend:         ${_backend:-unknown}"
  echo "capabilities:    ${_caps:-<none advertised>}"
  rm -f "$_idout" "$_iderr"
  if [ -n "$required_cap" ]; then
    case ",$_caps," in
      *",$required_cap,"*) : ;;
      *)
        echo "error: instance '$_managed' does not advertise '$required_cap'; refusing the $op mutation before submission" >&2
        echo "advertised_capabilities: ${_caps:-<none>}" >&2
        exit 3
        ;;
    esac
  fi

  if [ "$op" = "command" ]; then
    _cout=$(mktemp) || exit 1
    _cerr=$(mktemp) || { rm -f "$_cout"; exit 1; }
    if agentfleet command "$_managed" "$request_id" --json >"$_cout" 2>"$_cerr"; then
      _ccode=0
    else
      _ccode=$?
    fi
    if ! python3 "$ENVELOPE" "$_cout" ok >/dev/null; then
      cat "$_cout" >&2 || true
      cat "$_cerr" >&2 || true
      echo "error: malformed command stdout for request '$request_id' (no legacy fallback)" >&2
      rm -f "$_cout" "$_cerr"
      exit "$_ccode"
    fi
    _cok=$(python3 "$ENVELOPE" "$_cout" ok)
    rm -f "$_cerr"
    if [ "$_cok" = "true" ]; then
      _ack=$(python3 "$ENVELOPE" "$_cout" ack)
      _kind=$(python3 "$ENVELOPE" "$_cout" kind)
      _detail=$(python3 "$ENVELOPE" "$_cout" detail)
      echo "request_id:      $request_id"
      echo "kind:            $_kind"
      echo "acknowledgement: $_ack"
      echo "detail:          $_detail"
      rm -f "$_cout"
      _polls=${OPERATE_FOLLOW_POLLS:-12}
      _interval=${OPERATE_FOLLOW_INTERVAL:-5}
      while [ "$follow" -eq 1 ] && [ "$_ack" = "accepted" ] && [ "$_polls" -gt 0 ]; do
        sleep "$_interval"
        _polls=$((_polls - 1))
        _cout=$(mktemp) || exit 1
        if agentfleet command "$_managed" "$request_id" --json >"$_cout" 2>/dev/null; then
          if python3 "$ENVELOPE" "$_cout" ok >/dev/null; then
            _ack=$(python3 "$ENVELOPE" "$_cout" ack)
          fi
        fi
        rm -f "$_cout"
      done
      case "$_ack" in
        accepted) echo "state:           accepted (still finalizing; re-run with command $request_id to check again)" ;;
        completed|superseded|not_fulfilled) report_final_state "$_ack" ;;
        *) echo "state:           $_ack" ;;
      esac
      exit 0
    fi
    _code=$(python3 "$ENVELOPE" "$_cout" code)
    rm -f "$_cout"
    echo "request_id:      $request_id"
    # shellcheck disable=SC2086 # _ccode is a plain number
    echo "error: command lookup for '$request_id' failed: $_code" >&2
    exit "$_ccode"
  fi

  echo "request_id:      $request_id"
  _mout=$(mktemp) || exit 1
  _merr=$(mktemp) || { rm -f "$_mout"; exit 1; }
  # shellcheck disable=SC2086 # $after/$issue are digits-only by validation above
  case "$op" in
    stop)
      if [ -n "$after" ]; then
        set -- stop-after "$_managed" $after --expect-repo "$expect_repo" --request-id "$request_id" --max-attempts 1 --json
      else
        set -- stop "$_managed" --expect-repo "$expect_repo" --request-id "$request_id" --max-attempts 1 --json
      fi
      ;;
    resume) set -- resume "$_managed" --expect-repo "$expect_repo" --request-id "$request_id" --max-attempts 1 --json ;;
    next-issue) set -- next-issue "$_managed" $issue --expect-repo "$expect_repo" --request-id "$request_id" --max-attempts 1 --json ;;
    handoff) set -- handoff "$_managed" --expect-repo "$expect_repo" --request-id "$request_id" --max-attempts 1 --json ;;
    recovery-retry) set -- recovery-retry "$_managed" "$attempt" --expect-repo "$expect_repo" --request-id "$request_id" --max-attempts 1 --json ;;
    recovery-release) set -- recovery-release "$_managed" "$attempt" --saved-at "$saved_at" --expect-repo "$expect_repo" --request-id "$request_id" --max-attempts 1 --json ;;
    errors-reset) set -- errors-reset "$_managed" --expect-repo "$expect_repo" --request-id "$request_id" --max-attempts 1 --json ;;
  esac
  if agentfleet "$@" >"$_mout" 2>"$_merr"; then
    _mcode=0
  else
    _mcode=$?
  fi
  if ! python3 "$ENVELOPE" "$_mout" ok >/dev/null; then
    cat "$_mout" >&2 || true
    cat "$_merr" >&2 || true
    echo "request_id:      $request_id" >&2
    echo "error: malformed mutation stdout for request '$request_id'; the outcome is unknown." >&2
    echo "follow up with 'operate.sh $fragment command $request_id' (same ID, never a new submission)" >&2
    rm -f "$_mout" "$_merr"
    # shellcheck disable=SC2086 # _mcode is a plain number
    exit "$_mcode"
  fi
  _mok=$(python3 "$ENVELOPE" "$_mout" ok)
  if [ "$_mok" = "true" ]; then
    _ack=$(python3 "$ENVELOPE" "$_mout" ack)
    _replayed=$(python3 "$ENVELOPE" "$_mout" replayed)
    _mdetail=$(python3 "$ENVELOPE" "$_mout" detail)
    echo "acknowledgement: $_ack"
    echo "replayed:        $_replayed"
    echo "detail:          $_mdetail"
    rm -f "$_mout" "$_merr"
    if [ "$_replayed" = "true" ]; then
      echo "note:            replayed: the command was already committed under this request ID; nothing new happened"
    fi
    case "$_ack" in
      accepted)
        echo "state:           accepted (committed, effect not yet applied)"
        if [ "$follow" -eq 1 ]; then
          # shellcheck disable=SC2086 # internal re-invocation with known-safe fields
          exec "$0" ${context:+--context "$context"} ${worker:+--worker "$worker"} --expect-repo "$expect_repo" --follow "$fragment" command "$request_id"
        else
          echo "follow up:       operate.sh $fragment command $request_id"
        fi
        ;;
      completed|superseded|not_fulfilled)
        report_final_state "$_ack"
        ;;
      *)
        echo "state:           $_ack"
        ;;
    esac
    exit 0
  fi
  _code=$(python3 "$ENVELOPE" "$_mout" code)
  _retryable=$(python3 "$ENVELOPE" "$_mout" retryable)
  _stored=$(python3 "$ENVELOPE" "$_mout" stored)
  _mdetail=$(python3 "$ENVELOPE" "$_mout" detail)
  rm -f "$_mout"
  _ambiguous=0
  case "$_code" in
    agent_unreachable|timeout|client.docker_unavailable|client.exec_failed)
      if [ "$_retryable" = "true" ]; then
        _ambiguous=1
      fi
      ;;
    internal)
      if [ "$_stored" = "false" ]; then
        _code="internal (nothing stored)"
      elif [ "$_retryable" = "true" ]; then
        _ambiguous=1
      fi
      ;;
  esac
  if [ "$_ambiguous" = "1" ]; then
    cat "$_merr" >&2 || true
    echo "error: ambiguous outcome ($_code) for request '$request_id'; the outcome is unknown." >&2
    echo "checking with command $request_id (same ID, never a new submission):" >&2
    rm -f "$_merr"
    # shellcheck disable=SC2086 # internal re-invocation with known-safe fields
    exec "$0" ${context:+--context "$context"} ${worker:+--worker "$worker"} --expect-repo "$expect_repo" "$fragment" command "$request_id"
  fi
  cat "$_merr" >&2 || true
  rm -f "$_merr"
  echo "error: mutation for request '$request_id' failed: $_code: $_mdetail" >&2
  case "$_code" in
    contract_mismatch) echo "note:            contract mismatch is reported as such (no legacy fallback)" >&2 ;;
    unsupported) echo "note:            unsupported is reported as such (no legacy fallback)" >&2 ;;
  esac
  # shellcheck disable=SC2086 # _mcode is a plain number
  exit "$_mcode"
fi

# --- Legacy path: today's agentctl usage ("legacy agentctl") ----------------
echo "path:            legacy agentctl (unlabelled instance)"
if [ -z "${container:-}" ]; then
  echo "error: no container for project $project service $service on context $context; legacy agentctl needs a container" >&2
  echo "note:            a stopped instance takes no mutations; starting the container is a separate deployment action" >&2
  exit 1
fi
echo "container:       $container"
if [ "$op" != "command" ]; then
  case "${container_state:-unknown}" in
    running*) : ;;
    *)
      echo "error: container state is '$container_state'; legacy agentctl needs a running container" >&2
      echo "note:            starting a stopped container is a separate deployment action that needs the operator's authorization" >&2
      exit 1
      ;;
  esac
fi

legacy_agentctl() {
  docker exec -u agent "$container" sh -c "/usr/local/bin/agentctl $1" 2>&1
}

# --expect-repo was added to agentctl in simple-coding-agent 0.8.0. The status
# line prints the version without a leading v (e.g. "0.9.1"); accept one
# optional leading v and compare numerically so 0.10.0 counts as newer than
# 0.9.x. A pre-release or local suffix (e.g. 0.9.2.dev1, 0.9.1+local) is
# compared on its numeric core only.
legacy_supports_expect_repo() {
  _lv=${1:-}
  case "$_lv" in
    v*) _lv=${_lv#v} ;;
  esac
  _lcore=$(printf '%s' "$_lv" | sed -n 's/^\([0-9][0-9]*\(\.[0-9][0-9]*\)\{0,2\}\).*/\1/p')
  [ -n "${_lcore:-}" ] || return 1
  case "$_lcore" in
    *[!0-9.]* ) return 1 ;;
  esac
  _lmaj=${_lcore%%.*}
  _lrest=${_lcore#"$_lmaj"}
  _lmin=0
  _lpatch=0
  if [ -n "$_lrest" ]; then
    case "$_lrest" in
      .*) _lrest=${_lrest#.} ;;
      *) return 1 ;;
    esac
    _lmin=${_lrest%%.*}
    _ltmp=${_lrest#"$_lmin"}
    if [ -n "$_ltmp" ]; then
      case "$_ltmp" in
        .*) _lpatch=${_ltmp#.} ;;
        *) return 1 ;;
      esac
    fi
  fi
  case "$_lmaj$_lmin$_lpatch" in
    *[!0-9]* ) return 1 ;;
  esac
  _lmaj=$(printf '%s' "$_lmaj" | sed 's/^0*//;s/^$/0/')
  _lmin=$(printf '%s' "$_lmin" | sed 's/^0*//;s/^$/0/')
  _lpatch=$(printf '%s' "$_lpatch" | sed 's/^0*//;s/^$/0/')
  if [ "$_lmaj" -gt 0 ]; then return 0; fi
  if [ "$_lmaj" -eq 0 ] && [ "$_lmin" -gt 8 ]; then return 0; fi
  if [ "$_lmaj" -eq 0 ] && [ "$_lmin" -eq 8 ]; then return 0; fi
  return 1
}

if [ "$op" = "command" ]; then
  out=$(legacy_agentctl "command $request_id") || _lcode=$?
  _lcode=${_lcode:-0}
  printf '%s\n' "$out"
  # shellcheck disable=SC2086 # _lcode is a plain number
  exit "$_lcode"
fi

_status=$(legacy_agentctl "status") || {
  echo "error: legacy agentctl status failed on $container" >&2
  exit 1
}
_version=$(printf '%s' "$_status" | grep -E '^agent version:' | head -n 1 | sed 's/^agent version:[[:space:]]*//' || true)
_expect_flag=""
if legacy_supports_expect_repo "$_version"; then
  _expect_flag=" --expect-repo=$expect_repo"
else
  _repo_line=$(printf '%s' "$_status" | grep -E '^repository:' | head -n 1 || true)
  echo "note:            legacy agentctl $_version predates --expect-repo; ${_repo_line:-no repository line in status}"
fi

case "$op" in
  stop)
    if [ -n "$after" ]; then
      _argv="stop --after $after$_expect_flag"
    else
      _argv="stop$_expect_flag"
    fi
    ;;
  resume) _argv="resume$_expect_flag" ;;
  next-issue) _argv="next issue $issue$_expect_flag" ;;
  handoff) _argv="handoff now$_expect_flag" ;;
  # The legacy recovery/errors grammar takes no --expect-repo guard flag.
  recovery-retry) _argv="recovery retry $attempt" ;;
  recovery-release) _argv="recovery release $attempt --saved-at $saved_at" ;;
  errors-reset) _argv="errors reset" ;;
esac
echo "legacy_agentctl: agentctl $_argv"
out=$(legacy_agentctl "$_argv") || _lcode=$?
_lcode=${_lcode:-0}
printf '%s\n' "$out"
_leg_id=$(printf '%s' "$out" | grep -E '^request_id:' | head -n 1 | sed 's/^request_id:[[:space:]]*//' || true)
if [ -n "$_leg_id" ]; then
  echo "request_id:      $_leg_id"
  if [ "$follow" -eq 1 ]; then
    _polls=${OPERATE_FOLLOW_POLLS:-12}
    _interval=${OPERATE_FOLLOW_INTERVAL:-5}
    _ack=""
    while [ "$_polls" -gt 0 ]; do
      sleep "$_interval"
      _polls=$((_polls - 1))
      _cout=$(legacy_agentctl "command $_leg_id" 2>&1 || true)
      printf '%s\n' "$_cout"
      _ack=$(printf '%s' "$_cout" | grep -E '^(acknowledgement|outcome):' | head -n 1 | sed 's/^[^:]*:[[:space:]]*//' || true)
      case "$_ack" in
        completed|superseded|not_fulfilled|"not fulfilled") break ;;
      esac
    done
  else
    echo "follow up:       operate.sh $fragment command $_leg_id"
  fi
fi
# shellcheck disable=SC2086 # _lcode is a plain number
exit "$_lcode"
