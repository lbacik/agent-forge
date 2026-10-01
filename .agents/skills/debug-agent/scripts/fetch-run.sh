#!/bin/sh
# Copy attempt logs of a remote agent into a local cache, so they can be read
# with Read/Grep/jq exactly like the host path of a local (OrbStack) agent.
#
# Usage: fetch-run.sh --context <docker-context> <name-fragment> <issue> [run|latest|all]
#   run     an attempt dir name, e.g. 2026-09-25T07-25-10.531403Z
#   latest  (default) the newest attempt of the issue
#   all     every attempt of the issue (only for a cross-run view)
#
# Prints the local path of each fetched attempt dir (use it as $A in the jq
# recipes). A finished attempt (attempt.json has an outcome) never changes, so
# a cached copy of it is reused; an unfinished one is fetched again every time.
# repo/ is never copied (hundreds of MB): read it remotely, see SKILL.md.

set -eu

[ "${1:-}" = --context ] || { echo "usage: fetch-run.sh --context <ctx> <name-fragment> <issue> [run|latest|all]" >&2; exit 1; }
context=${2:?--context needs a value}
fragment=${3:?missing name-fragment}
issue=${4:?missing issue number}
which=${5:-latest}

. "$(dirname "$0")/lib/resolve.sh"

if [ "$mode" = local ]; then
  echo "error: context $context is local; read $host_data/logs/$issue directly" >&2
  exit 1
fi

runs=$(data_sh "ls logs/$issue 2>/dev/null | sort" || true)
[ -n "$runs" ] || { echo "error: no runs for issue $issue in $volume on $context" >&2; exit 6; }
case "$which" in
  latest) runs=$(echo "$runs" | tail -1) ;;
  all) ;;
  *) echo "$runs" | grep -qx "$which" || { echo "error: no run $which for issue $issue. Runs:" >&2; echo "$runs" >&2; exit 6; }
     runs=$which ;;
esac

dest="$cache_data/logs/$issue"
mkdir -p "$dest"
for r in $runs; do
  if grep -q '"outcome"' "$dest/$r/attempt.json" 2>/dev/null; then
    echo "$dest/$r   (cached, finished)"
    continue
  fi
  rm -rf "$dest/$r"
  if [ -n "$container" ]; then
    # docker cp reads the volume through the container, running or stopped.
    docker cp -q "$container:/data/logs/$issue/$r" "$dest/"
  else
    data_sh "tar -C logs/$issue -cf - '$r'" | tar -xf - -C "$dest"
  fi
  if grep -q '"outcome"' "$dest/$r/attempt.json" 2>/dev/null; then
    echo "$dest/$r"
  else
    echo "$dest/$r   (unfinished: still running or crashed; fetch again for newer files)"
  fi
done
