#!/bin/sh
# Resolve one simple-coding-agent instance from a name fragment and print where
# its files live and how to reach it with docker.
#
# Usage: locate-agent.sh [--context <docker-context>] <name-fragment> [issue-number]
#   --context        docker context the agent runs on (default: orbstack, the
#                    local mode where /data is readable on the host). Any other
#                    context is remote: /data is read through the Docker API.
#   <name-fragment>  full or unambiguous part of an agent-instances/agent-*/ directory name
#                    (e.g. "cli", "jsonhub-api", "agent-paysubscriptions")
#   [issue-number]   optional; also list that issue's runs (attempt dirs)
#
# Run from anywhere; instances are looked up in agent-forge's agent-instances/.

set -eu

context=""
if [ "${1:-}" = --context ]; then context=${2:?--context needs a value}; shift 2; fi
fragment=${1:?usage: locate-agent.sh [--context <ctx>] <name-fragment> [issue-number]}
issue=${2:-}

. "$(dirname "$0")/lib/resolve.sh"

echo "agent_dir:       $root/$dir"
echo "docker_context:  $context ($mode)"
echo "compose_project: $project"
echo "container:       ${container:-${project}-agent-1 (not created)}"
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
