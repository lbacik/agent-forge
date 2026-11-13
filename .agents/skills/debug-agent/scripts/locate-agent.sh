#!/bin/sh
# Resolve one simple-coding-agent instance from a name fragment and print where
# its files live and how to reach it with docker.
#
# Usage: locate-agent.sh [--context <docker-context>] [--worker <n|worker-id>] <name-fragment> [issue-number]
#   --context        docker context the agent runs on (default: orbstack, the
#                    local mode where /data is readable on the host). Any other
#                    context is remote: /data is read through the Docker API.
#   --worker         which Worker of the instance to inspect: a number (2) or a
#                    worker id (<short-name>-2, e.g. cli-2 for agent-cli).
#                    Default is the first Worker (service `agent` for
#                    simple-coding-agent, `worker` for a coding-agent Managed
#                    Instance, resolved from the discovery labels). With N>=2 and
#                    no --worker, all Workers are listed instead of guessing.
#   <name-fragment>  full or unambiguous part of an agent-instances/agent-*/ directory name
#                    (e.g. "cli", "jsonhub-api", "agent-paysubscriptions")
#   [issue-number]   optional; also list that issue's runs (attempt dirs)
#
# Run from anywhere; instances are looked up in agent-forge's agent-instances/.

set -eu

context=""
worker=""
while [ "${1:-}" = --context ] || [ "${1:-}" = --worker ]; do
  if [ "${1:-}" = --context ]; then
    context=${2:?--context needs a value}
  else
    worker=${2:?--worker needs a value}
  fi
  shift 2
done
fragment=${1:?usage: locate-agent.sh [--context <ctx>] [--worker <n|worker-id>] <name-fragment> [issue-number]}
issue=${2:-}

. "$(dirname "$0")/lib/contract.sh"
. "$(dirname "$0")/lib/resolve.sh"
. "$(dirname "$0")/lib/contract_attempts.sh"

# Contract hint: the compose label decides the path (see lib/contract.sh and
# lib/resolve.sh). A labelled Instance stays on the contract path even when no
# container exists yet, so unlabelled instances skip the extra inspect below
# and their argv and output stay exactly as today. A running container without
# the label, under a labelled compose file, is only a mismatch note: never a
# silent return to the legacy path.
_use_contract=${contract_compose:-0}
if [ "$_use_contract" -eq 1 ] && [ -n "${container:-}" ]; then
  _label=$(docker inspect -f '{{index .Config.Labels "io.github.lbacik.agent-operator.contract"}}' "$container" 2>/dev/null || true)
  case "$_label" in
    ""|"<no value>")
      echo "note: container $container carries no $CONTRACT_LABEL label (mismatch; staying on the contract path)" >&2
      ;;
  esac
fi

if [ "$_use_contract" -eq 1 ]; then
  if ! require_agentfleet; then
    exit 3
  fi
  _managed=$(managed_instance_name "$short" "$worker_num" "${worker_id:-}")
  echo "agent_dir:       $root/$dir"
  echo "docker_context:  $context ($mode)"
  echo "compose_project: $project"
  echo "forge_instance:  $dir (short $short)"
  echo "managed_instance: $_managed"
  if [ -n "$worker" ]; then
    if [ "$worker_num" -eq 1 ]; then
      echo "worker:          1 (first Worker)"
    else
      echo "worker:          $worker_num ($worker_id)"
    fi
    echo "service:         $service"
  fi
  echo "container:       ${container:-${project}-${service}-1 (not created)}"
  echo "container_state: $container_state"
  echo "image:           ${image:-unknown}"
  echo "agentfleet_identity:"
  if agentfleet identity "$_managed"; then
    :
  else
    _code=$?
    echo "error: agentfleet identity failed for managed instance '$_managed' (no legacy fallback)" >&2
    exit "$_code"
  fi
  # The backend for the report line comes from the machine-readable envelope
  # (the same read fetch-run.sh uses for its cache key); the human block above
  # stays the report's identity section.
  _idjson=$(mktemp) || exit 1
  if contract_identity_envelope "$_managed" "$_idjson"; then
    :
  else
    _code=$?
    rm -f "$_idjson"
    exit "$_code"
  fi
  _backend=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d.get("result",{}) if isinstance(d.get("result"),dict) else {}; sys.stdout.write(r.get("backend","") if isinstance(r.get("backend"),str) else "")' "$_idjson") || {
    rm -f "$_idjson"
    echo "error: cannot read backend from agentfleet identity for '$_managed'" >&2
    exit 1
  }
  rm -f "$_idjson"
  if [ -z "$_backend" ]; then
    echo "error: agentfleet identity for '$_managed' names no backend" >&2
    exit 1
  fi
  echo "status_snapshot:"
  _tmp=$(mktemp) || exit 1
  _tmperr=$(mktemp) || { rm -f "$_tmp"; exit 1; }
  if agentfleet status "$_managed" --json >"$_tmp" 2>"$_tmperr"; then
    if python3 "$(dirname "$0")/lib/render_status.py" <"$_tmp"; then
      :
    else
      _code=$?
      echo "error: cannot render Status Snapshot for '$_managed'" >&2
      cat "$_tmperr" >&2 || true
      rm -f "$_tmp" "$_tmperr"
      exit "$_code"
    fi
    rm -f "$_tmp" "$_tmperr"
  else
    _code=$?
    cat "$_tmp" >&2 || true
    cat "$_tmperr" >&2 || true
    echo "error: agentfleet status failed for managed instance '$_managed' (no legacy fallback)" >&2
    rm -f "$_tmp" "$_tmperr"
    exit "$_code"
  fi
  if [ -n "$issue" ]; then
    # That issue's Attempts from `attempts ls`, filtered by issue on the
    # client side and paged with the opaque cursor (newest first). Each line
    # names the native Attempt ID, native outcome, delivery,
    # `attention_required` and `sealed`.
    echo "attempts_for_issue_$issue:"
    _tmpdir=$(mktemp -d) || exit 1
    _ids=$(contract_list_issue_pages "$_managed" "$issue" "$_tmpdir") || {
      _code=$?
      rm -rf "$_tmpdir"
      exit "$_code"
    }
    if [ -z "$_ids" ]; then
      echo "  none"
      _ids="<none>"
    else
      for _page in "$_tmpdir"/page-*.json; do
        python3 "$(dirname "$0")/lib/render_attempts.py" "$issue" "$_page" || {
          _code=$?
          echo "error: cannot render Attempts listing for '$_managed' (no legacy fallback)" >&2
          rm -rf "$_tmpdir"
          exit "$_code"
        }
      done
      # shellcheck disable=SC2086 # word-splitting the collected IDs is intended
      set -- $_ids
      _ids="$*"
    fi
    rm -rf "$_tmpdir"
  fi
  if [ -n "$issue" ]; then
    echo "report:          context $context, forge instance $dir, managed instance $_managed, backend $_backend, attempts for issue #$issue: $_ids"
  else
    echo "report:          context $context, forge instance $dir, managed instance $_managed, backend $_backend"
  fi
  exit 0
fi

# With N>=2 and no --worker, list every Worker with container and volume
# instead of guessing. N comes from the compose services on disk, so it works
# without docker and without SSH round trips.
if [ -z "$worker" ]; then
  compose_file="$root/$dir/compose.yaml"
  worker_list=""
  if [ -f "$compose_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "  agent:"*) worker_list="$worker_list 1" ;;
        "  agent-"*)
          rest=${line#"  agent-"}
          n=${rest%%[!0-9]*}
          case "$n" in ''|*[!0-9]*) continue ;; esac
          case "$rest" in "$n:"*) worker_list="$worker_list $n" ;; *) continue ;; esac
          ;;
      esac
    done < "$compose_file"
  fi
  if [ -n "$worker_list" ]; then
    # shellcheck disable=SC2086
    worker_list=$(echo $worker_list | tr ' ' '\n' | sort -n -u | tr '\n' ' ')
    count=$(echo "$worker_list" | wc -w | tr -d ' ')
    if [ "$count" -ge 2 ]; then
      echo "agent_dir:       $root/$dir"
      echo "docker_context:  $context ($mode)"
      echo "compose_project: $project"
      echo "workers:         $(echo "$worker_list" | tr -s ' ' | tr ' ' ',' | sed 's/^,//;s/,$//') (use --worker <n|worker-id> to inspect one Worker)"
      # shellcheck disable=SC2086
      for n in $worker_list; do
        if [ "$n" -eq 1 ]; then
          svc=agent
          vol="${project}_agent_data"
          wid="$short-1"
        else
          svc="agent-$n"
          vol="${project}_data_$n"
          wid="$short-$n"
        fi
        cont=$(docker ps -a --filter "label=com.docker.compose.project=$project" \
          --filter "label=com.docker.compose.service=$svc" --format '{{.Names}}' 2>/dev/null | head -1 || true)
        [ -z "$cont" ] && cont="${project}-${svc}-1 (not created)"
        echo "worker $n ($wid): service=$svc container=$cont volume=$vol"
      done
      if [ -n "$issue" ]; then
        echo "note:            pass --worker <n|worker-id> to list runs for issue $issue of one Worker"
      fi
      exit 0
    fi
  fi
fi

echo "agent_dir:       $root/$dir"
echo "docker_context:  $context ($mode)"
echo "compose_project: $project"
if [ -n "$worker" ]; then
  if [ "$worker_num" -eq 1 ]; then
    echo "worker:          1 (first Worker)"
  else
    echo "worker:          $worker_num ($worker_id)"
  fi
  echo "service:         $service"
fi
echo "container:       ${container:-${project}-${service}-1 (not created)}"
echo "container_state: $container_state"
echo "image:           ${image:-unknown}"
echo "volume:          $volume"

# Summary of /data, as a script that runs where the files are. State files are
# printed except control.sqlite3* (binary; query live state with agentctl).
summary='
for f in state/*.json; do [ -e "$f" ] && echo "  $(basename "$f"): $(cat "$f")"; done
[ -d logs ] && echo "issues_with_logs: $(ls logs | sort -n | tr "\n" " ")"
if [ -n "$1" ]; then
  echo "runs_for_issue_$1:"
  if [ -d "logs/$1" ]; then
    for r in $(ls "logs/$1" | sort); do
      o=$(sed -n "s/.*\"outcome\": *\"\([^\"]*\)\".*/\1/p" "logs/$1/$r/attempt.json" 2>/dev/null || true)
      k=$(sed -n "s/.*\"attempt_kind\": *\"\([^\"]*\)\".*/\1/p" "logs/$1/$r/attempt.json" 2>/dev/null || true)
      if [ -f "logs/$1/$r/attempt.json" ] && [ -z "$k" ]; then k=ordinary; fi
      echo "  $r  outcome=${o:-<none: still running or crashed before finishing>} attempt_kind=${k:-<none>}"
    done
  else
    echo "  (none)"
  fi
fi'

if [ "$mode" = local ]; then
  if [ ! -d "$host_data" ]; then
    echo "host_data:       $host_data   (MISSING - volume not created yet, or OrbStack not running)"
    exit 0
  fi
  echo "host_data:       $host_data   (= /data in the container)"
  echo "state_files:"
  (cd "$host_data" && sh -c "$summary" sh "$issue")
else
  echo "data_access:     remote - read with fetch-run.sh, then work on the local copy"
  echo "local_cache:     $cache_data   (mirrors /data/logs/...)"
  echo "state_files:"
  data_sh "set -- '$issue'; $summary"
fi
exit 0
