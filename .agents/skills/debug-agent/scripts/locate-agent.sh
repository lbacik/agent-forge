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
#                    Default is the first Worker (service agent). With N>=2 and
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

. "$(dirname "$0")/lib/resolve.sh"

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
      echo "  $r  outcome=${o:-<none: still running or crashed before finishing>}"
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
