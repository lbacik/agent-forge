#!/bin/sh
# Fleet overview: which Managed Instances run on one Docker context, and which
# local containers agentfleet cannot manage. Read-only.
#
# Usage: fleet.sh [--context <docker-context>]
#   --context  docker context to inspect (default: orbstack, local)
#
# The contract Fleet comes from `agentfleet ls` (one line per Managed
# Instance: backend, Target Repository, contract, instance state and Intake;
# the per-instance state and Intake are read through `agentfleet status`, via
# Offline Read for a stopped instance). A member whose status cannot be read
# is listed with a `status unavailable` note and the overview still exits
# non-zero, but the remaining members are always listed.
#
# The legacy list holds the containers of every Instance directory whose
# compose file carries no contract discovery label, resolved from the
# Instance directories on disk (never from `docker volume ls`, where stale
# volumes from old project names linger). Compose one-off containers are
# skipped: consumers ignore them, as does `agentfleet`.
#
# Exit codes: 0 when every member status rendered; 1 on usage, missing docker
# or an unreadable `agentfleet ls` document; 3 when `agentfleet` is missing
# or speaks another contract major; the first `agentfleet` failure code when
# any member status could not be rendered.

set -eu

usage="usage: fleet.sh [--context <ctx>]"

context=""
while [ $# -gt 0 ]; do
  case "$1" in
    --context)
      context=${2:?$usage}
      shift 2
      ;;
    -h|--help)
      echo "$usage"
      exit 0
      ;;
    --*)
      echo "error: unknown option $1" >&2
      echo "$usage" >&2
      exit 1
      ;;
    *)
      echo "$usage" >&2
      exit 1
      ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "error: docker not found on PATH" >&2; exit 1; }

. "$(dirname "$0")/lib/contract.sh"

# Instance root and Docker context, as in lib/resolve.sh but without naming
# an instance: the overview spans every agent-instances/agent-*/ directory.
root=${AGENT_INSTANCES_DIR:-$(cd "$(dirname "$0")/../../../.." && pwd)/agent-instances}
if ! ls -d "$root"/agent-*/ >/dev/null 2>&1; then
  echo "error: no agent-*/ directories under $root" >&2
  exit 2
fi
context=${context:-orbstack}
export DOCKER_CONTEXT=$context
if [ "$context" = orbstack ]; then
  mode=local
else
  mode=remote
fi

if ! require_agentfleet; then
  exit 3
fi

ls_tmp=$(mktemp) || exit 1
ls_err=$(mktemp) || { rm -f "$ls_tmp"; exit 1; }
if ! agentfleet ls --json >"$ls_tmp" 2>"$ls_err"; then
  ls_code=$?
  cat "$ls_tmp" 2>/dev/null || true
  cat "$ls_err" >&2 || true
  echo "error: agentfleet ls failed (exit $ls_code)" >&2
  rm -f "$ls_tmp" "$ls_err"
  exit "$ls_code"
fi

failcode=0
count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("instances", [])))' "$ls_tmp" 2>/dev/null || echo "?")
echo "fleet (context $context, $mode): $count managed instance(s)"
python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
for item in doc.get("instances", []):
    if not isinstance(item, dict):
        continue
    name = item.get("name", "")
    if not name:
        continue
    dup = "1" if item.get("duplicate") is True else "0"
    print("%s|%s|%s|%s|%s" % (name, item.get("backend", "") or "",
          item.get("contract", "") or "", item.get("state", "") or "", dup))
' "$ls_tmp" >"$ls_tmp.members" 2>/dev/null || {
  echo "error: cannot parse agentfleet ls output:" >&2
  cat "$ls_tmp" >&2 || true
  rm -f "$ls_tmp" "$ls_tmp.members" "$ls_err"
  exit 1
}
while IFS= read -r m || [ -n "$m" ]; do
  [ -n "$m" ] || continue
  mname=${m%%|*}; mrest=${m#*|}
  mbackend=${mrest%%|*}; mrest2=${mrest#*|}
  mcontract=${mrest2%%|*}; mrest3=${mrest2#*|}
  mstate=${mrest3%%|*}; mdup=${mrest3#*|}
  st_tmp=$(mktemp) || exit 1
  st_err=$(mktemp) || { rm -f "$st_tmp"; exit 1; }
  if agentfleet status "$mname" --json >"$st_tmp" 2>"$st_err"; then
    st_code=0
  else
    st_code=$?
  fi
  if python3 "$(dirname "$0")/lib/render_fleet_member.py" \
    --name "$mname" --backend "$mbackend" --contract "$mcontract" \
    --state "$mstate" --duplicate "$mdup" <"$st_tmp"; then
    render_code=0
  else
    render_code=$?
  fi
  if [ "$st_code" -ne 0 ] && [ "$failcode" -eq 0 ]; then
    failcode=$st_code
  elif [ "$render_code" -ne 0 ] && [ "$failcode" -eq 0 ]; then
    failcode=1
  fi
  rm -f "$st_tmp" "$st_err"
done < "$ls_tmp.members"
rm -f "$ls_tmp" "$ls_tmp.members" "$ls_err"

# Legacy containers: every Instance directory whose compose file carries no
# contract label, with its containers from one shared `docker ps`. Stale
# volumes never anchor this list; one-off containers are skipped.
legacy_dirs=""
for d in "$root"/agent-*/; do
  dname=$(basename "$d")
  if [ -f "$root/$dname/compose.yaml" ] \
    && grep -q "$CONTRACT_LABEL" "$root/$dname/compose.yaml" 2>/dev/null; then
    continue
  fi
  legacy_dirs="$legacy_dirs $dname"
done
# shellcheck disable=SC2086
legacy_dirs=$(echo $legacy_dirs | tr ' ' '\n' | sort -u | tr '\n' ' ')
if [ -n "$legacy_dirs" ]; then
  legacy_ps=$(docker ps -a \
    --format '{{.Label "com.docker.compose.project"}}|{{.Names}}|{{.Status}}|{{.Label "com.docker.compose.oneoff"}}' 2>/dev/null || true)
  echo "legacy (not managed by agentfleet):"
  # shellcheck disable=SC2086
  for d in $legacy_dirs; do
    rows=$(printf '%s\n' "$legacy_ps" | grep "^$d|" || true)
    if [ -n "$rows" ]; then
      rows=$(printf '%s\n' "$rows" | grep -v '|True$' || true)
    fi
    if [ -n "$rows" ]; then
      printf '%s\n' "$rows" | while IFS= read -r row || [ -n "$row" ]; do
        [ -n "$row" ] || continue
        rname=$(echo "$row" | cut -d'|' -f2)
        rstate=$(echo "$row" | cut -d'|' -f3)
        echo "  $d: $rname [$rstate]"
      done
    else
      echo "  $d: (no containers)"
    fi
  done
else
  echo "legacy (not managed by agentfleet): (none)"
fi

exit "$failcode"
