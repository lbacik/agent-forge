#!/bin/sh
# Copy attempt logs of a remote agent into a local cache, so they can be read
# with Read/Grep/jq exactly like the host path of a local (OrbStack) agent.
#
# Usage: fetch-run.sh [--context <docker-context>] [--worker <n|worker-id>] <name-fragment> <issue> [run|latest|all]
#   --context  docker context the agent runs on (default: orbstack, which is
#              local - use it only to learn the host path; fetching needs a
#              remote context)
#   --worker   which Worker of the instance to fetch from: a number (2) or a
#              worker id (<short-name>-2). Default is the first Worker.
#              A fetch for Worker 2+ caches under a per-Worker subdirectory;
#              the first Worker's cache path is unchanged.
#   run     an attempt dir name, e.g. 2026-09-25T07-25-10.531403Z
#   latest  (default) the newest attempt of the issue
#   all     every attempt of the issue (only for a cross-run view)
#
# Prints the local path of each fetched attempt dir (use it as $A in the jq
# recipes in references/log-layout.md). It works whether the container is
# running or stopped (`docker cp`), and falls back to a throwaway container
# if the container was removed. Finished runs are cached and reused. An
# unfinished run (active, or the process died) is fetched again on each call.
# repo/ is never copied (hundreds of MB): read it remotely, see SKILL.md.
#
# On the contract path (a container carrying the
# `io.github.lbacik.agent-operator.contract` label) this helper instead
# exports Attempt Archives through `agentfleet attempts export` into a
# separate contract cache (see lib/contract_attempts.sh): <run> is then a
# native Attempt ID (opaque: coding-agent uses `#<issue>/<n>`), the cache key
# is context, Managed Instance, backend, Target Repository and Attempt ID,
# only Sealed archives are reused (after `sha256` verification against the
# manifest), and unsealed archives are moving snapshots fetched again on
# every request. A stopped instance is read through Offline Read inside
# `agentfleet`: no `docker cp` and no legacy throwaway container.

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
fragment=${1:?usage: fetch-run.sh [--context <ctx>] [--worker <n|worker-id>] <name-fragment> <issue> [run|latest|all]}
issue=${2:?missing issue number}
which=${3:-latest}

. "$(dirname "$0")/lib/resolve.sh"
. "$(dirname "$0")/lib/contract.sh"
. "$(dirname "$0")/lib/contract_attempts.sh"

# Contract hint: same discovery as locate-agent.sh. Unlabelled instances skip
# the extra inspect below, so their fetch output stays exactly as today.
_use_contract=0
if [ -n "${container:-}" ] && [ -f "$root/$dir/compose.yaml" ] \
  && grep -q "$CONTRACT_LABEL" "$root/$dir/compose.yaml" 2>/dev/null; then
  _label=$(docker inspect -f '{{index .Config.Labels "io.github.lbacik.agent-operator.contract"}}' "$container" 2>/dev/null || true)
  case "$_label" in
    ""|"<no value>") _use_contract=0 ;;
    *) _use_contract=1 ;;
  esac
fi

if [ "$_use_contract" -eq 1 ]; then
  if ! require_agentfleet; then
    exit 3
  fi
  _managed=$(managed_instance_name "$short" "$worker_num" "${worker_id:-}")
  _tmpdir=$(mktemp -d) || exit 1
  if ! contract_identity_envelope "$_managed" "$_tmpdir/identity.json"; then
    _code=$?
    rm -rf "$_tmpdir"
    exit "$_code"
  fi
  _backend=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d.get("result",{}) if isinstance(d.get("result"),dict) else {}; sys.stdout.write(r.get("backend","") if isinstance(r.get("backend"),str) else "")' "$_tmpdir/identity.json") || {
    rm -rf "$_tmpdir"
    echo "error: cannot read backend from agentfleet identity for '$_managed'" >&2
    exit 1
  }
  _repo=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d.get("result",{}) if isinstance(d.get("result"),dict) else {}; sys.stdout.write(r.get("repository","") if isinstance(r.get("repository"),str) else "")' "$_tmpdir/identity.json") || {
    rm -rf "$_tmpdir"
    echo "error: cannot read repository from agentfleet identity for '$_managed'" >&2
    exit 1
  }
  if [ -z "$_backend" ] || [ -z "$_repo" ]; then
    rm -rf "$_tmpdir"
    echo "error: agentfleet identity for '$_managed' names no backend or repository" >&2
    exit 1
  fi
  case "$which" in
    latest|all)
      _ids=$(contract_list_issue_pages "$_managed" "$issue" "$_tmpdir") || {
        _code=$?
        rm -rf "$_tmpdir"
        exit "$_code"
      }
      if [ -z "$_ids" ]; then
        rm -rf "$_tmpdir"
        echo "error: no attempts for issue $issue on managed instance '$_managed'" >&2
        exit 6
      fi
      if [ "$which" = latest ]; then
        # Newest first: the first match is the latest Attempt.
        # shellcheck disable=SC2086 # word-splitting the IDs is intended
        set -- $_ids
        _ids=$1
      fi
      ;;
    *)
      if ! contract_attempt_show "$_managed" "$which" "$_tmpdir/show.json"; then
        _code=$?
        rm -rf "$_tmpdir"
        exit "$_code"
      fi
      _show_issue=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d.get("result",{}) if isinstance(d.get("result"),dict) else {}; a=r.get("attempt",{}) if isinstance(r.get("attempt"),dict) else {}; i=a.get("issue",{}) if isinstance(a.get("issue"),dict) else {}; n=i.get("number"); sys.stdout.write(str(n) if isinstance(n,int) else "")' "$_tmpdir/show.json") || {
        rm -rf "$_tmpdir"
        echo "error: cannot read attempts show for '$which'" >&2
        exit 1
      }
      _show_ok=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.stdout.write("yes" if d.get("ok") is True else "no")' "$_tmpdir/show.json") || {
        rm -rf "$_tmpdir"
        echo "error: cannot read attempts show for '$which'" >&2
        exit 1
      }
      if [ "$_show_ok" != yes ]; then
        rm -rf "$_tmpdir"
        echo "error: no attempt '$which' is recorded on managed instance '$_managed'" >&2
        exit 6
      fi
      if [ "$_show_issue" != "$issue" ]; then
        rm -rf "$_tmpdir"
        echo "error: attempt '$which' is for issue #${_show_issue:-unknown}, not #$issue" >&2
        exit 6
      fi
      _ids=$which
      ;;
  esac
  _fetched=""
  # shellcheck disable=SC2086 # word-splitting the IDs is intended
  for _id in $_ids; do
    if ! contract_attempt_show "$_managed" "$_id" "$_tmpdir/show.json"; then
      _code=$?
      rm -rf "$_tmpdir"
      exit "$_code"
    fi
    _sealed=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d.get("result",{}) if isinstance(d.get("result"),dict) else {}; a=r.get("attempt",{}) if isinstance(r.get("attempt"),dict) else {}; s=a.get("sealed"); sys.stdout.write("yes" if s is True else ("no" if s is False else ""))' "$_tmpdir/show.json") || {
      rm -rf "$_tmpdir"
      echo "error: cannot read attempts show for '$_id'" >&2
      exit 1
    }
    if [ -z "$_sealed" ]; then
      rm -rf "$_tmpdir"
      echo "error: attempts show for '$_id' names no sealed flag" >&2
      exit 1
    fi
    _dest=$(contract_cache_dir "$context" "$_managed" "$_backend" "$_repo" "$_id")
    if [ "$_sealed" = yes ] && [ -f "$_dest/manifest.json" ] \
      && python3 "$(dirname "$0")/lib/verify_archive.py" "$_dest" >/dev/null 2>&1; then
      echo "$_dest   (cached, sealed, verified)"
      _fetched="$_fetched $_id"
      continue
    fi
    # Sealed but unverifiable, or unsealed: export again. A `sha256`
    # mismatch in the fresh export is a torn read: export again, bounded.
    _done=0
    _try=1
    while [ "$_try" -le 3 ]; do
      rm -rf "$_dest"
      mkdir -p "$_dest"
      if ! contract_attempt_export "$_managed" "$_id" "$_tmpdir/export.tar"; then
        _code=$?
        rm -rf "$_tmpdir" "$_dest"
        exit "$_code"
      fi
      tar -xf "$_tmpdir/export.tar" -C "$_dest"
      rm -f "$_tmpdir/export.tar"
      if python3 "$(dirname "$0")/lib/verify_archive.py" "$_dest" >/dev/null 2>&1; then
        _done=1
        break
      fi
      echo "warning: export of attempt '$_id' does not match its manifest sha256 (torn read); fetching again" >&2
      _try=$((_try + 1))
    done
    if [ "$_done" -eq 0 ]; then
      rm -rf "$_tmpdir" "$_dest"
      echo "error: export of attempt '$_id' stayed torn after 3 fetches" >&2
      exit 7
    fi
    if [ "$_sealed" = yes ]; then
      echo "$_dest   (sealed)"
    else
      echo "$_dest   (moving snapshot: unsealed, fetched again on every request)"
    fi
    _fetched="$_fetched $_id"
  done
  rm -rf "$_tmpdir"
  # shellcheck disable=SC2086 # word-splitting the fetched IDs is intended
  set -- $_fetched
  echo "report:          context $context, forge instance $dir, managed instance $_managed, backend $_backend, target repository $_repo, attempt(s) $* for issue #$issue"
  exit 0
fi

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
