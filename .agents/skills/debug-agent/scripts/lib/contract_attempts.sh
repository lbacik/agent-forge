#!/bin/sh
# shellcheck disable=SC2034 # library: sourced by locate-agent.sh and fetch-run.sh, whose use of these constants shellcheck cannot see.
# Shared Attempt Archive helpers for the contract path. Source it, don't run it.
#
# Listing and export go through `agentfleet`, the host-side client shipped by
# the operator contract — never by reading the container's files. A stopped
# instance is read through Offline Read inside `agentfleet` (no `docker cp`
# and no legacy throwaway container). `locate-agent.sh` and `fetch-run.sh`
# decide the path per container (see lib/contract.sh); this file holds what
# both contract branches share: the separate contract cache, safe cache paths
# for opaque Attempt IDs, paged Attempts listing filtered by issue on the
# client side, and export with manifest verification.
#
# Cache rules (the contract cache root is separate from the legacy cache, so
# legacy `fetch-run` output for an unlabelled container is unchanged):
# the key is context, Managed Instance, backend, Target Repository and
# Attempt ID. Only Sealed archives are reused, after `sha256` verification
# against the manifest. Unsealed archives (including the active Attempt) are
# moving snapshots: fetched again on every request. A `sha256` mismatch in a
# fresh export is a torn read and is fetched again. The legacy `"outcome"`
# file heuristic does not exist on the contract path: Sealed comes from
# `attempts show`, never from a file on disk.

# Contract cache root: separate from the legacy remote cache
# ($AGENT_LOG_CACHE/<ctx>/<project>/logs/...). AGENT_CONTRACT_CACHE overrides
# it (tests point it at a scratch dir); otherwise it lives next to the legacy
# cache under contract-attempts/.
contract_cache_root() {
  _base=${AGENT_LOG_CACHE:-$HOME/.cache/simple-coding-agent-env}
  printf '%s' "${AGENT_CONTRACT_CACHE:-$_base/contract-attempts}"
}

# Percent-encode one key component, so opaque Attempt IDs (coding-agent uses
# `#<issue>/<n>`) become one safe, unique path component. Every byte outside
# [A-Za-z0-9._-] is escaped, so the encoding is injective: two different IDs
# never share a directory.
contract_encode() {
  python3 -c 'import sys,urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Full cache directory for one Attempt Archive. Key: context, Managed
# Instance, backend, Target Repository, Attempt ID.
contract_cache_dir() {
  _root=$(contract_cache_root)
  printf '%s/%s/%s/%s/%s/%s' "$_root" "$1" "$2" \
    "$(contract_encode "$3")" "$(contract_encode "$4")" "$(contract_encode "$5")"
}

# Relay one `agentfleet identity --json` envelope for a Managed Instance to a
# file. Reports the failure (no legacy fallback) and returns agentfleet's
# exit code when the read fails.
contract_identity_envelope() {
  _managed=$1
  _out=$2
  _err=$(mktemp) || return 1
  if agentfleet identity "$_managed" --json >"$_out" 2>"_err"; then
    rm -f "$_err"
    return 0
  fi
  _code=$?
  cat "$_err" >&2 || true
  rm -f "$_err"
  echo "error: agentfleet identity failed for managed instance '$_managed' (no legacy fallback)" >&2
  return "$_code"
}

# One attempts-ls page (`--json`) to a file, optionally continuing from an
# opaque cursor. Reports the failure (no legacy fallback) and returns
# agentfleet's exit code when the list fails.
contract_attempts_ls_page() {
  _managed=$1
  _out=$2
  _cursor=${3:-}
  _err=$(mktemp) || return 1
  if [ -n "$_cursor" ]; then
    _ok=0
    agentfleet attempts ls "$_managed" --json --before "$_cursor" >"$_out" 2>"_err" || _ok=$?
  else
    _ok=0
    agentfleet attempts ls "$_managed" --json >"$_out" 2>"_err" || _ok=$?
  fi
  if [ "$_ok" -eq 0 ]; then
    rm -f "$_err"
    return 0
  fi
  cat "$_err" >&2 || true
  rm -f "$_err"
  echo "error: agentfleet attempts ls failed for managed instance '$_managed' (no legacy fallback)" >&2
  return "$_ok"
}

# Page through `attempts ls` with the opaque cursor and print the native
# Attempt IDs of one issue, newest first. Pages land in <tmpdir> as
# page-1.json, page-2.json, ... (only fetched pages); <tmpdir> must exist.
# Filtering happens on the client side: every page is fetched, even when an
# early page already holds the issue's Attempts. Returns agentfleet's exit
# code when a page fails (no legacy fallback).
contract_list_issue_pages() {
  _managed=$1
  _issue=$2
  _tmpdir=$3
  _cursor=""
  _n=0
  while :; do
    _n=$((_n + 1))
    if ! contract_attempts_ls_page "$_managed" "$_tmpdir/page-$_n.json" "$_cursor"; then
      return $?
    fi
    python3 "$(dirname "$0")/lib/render_attempts.py" --ids-only "$_issue" "$_tmpdir/page-$_n.json" || return 1
    _cursor=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d.get("result",{}) if isinstance(d.get("result"),dict) else {}; c=r.get("next_cursor"); sys.stdout.write(c if isinstance(c,str) else "")' "$_tmpdir/page-$_n.json") || return 1
    [ -n "$_cursor" ] || break
  done
  return 0
}

# One attempts-show envelope (`--json`) for an Attempt ID to a file.
# A not_found producer reply stays a readable envelope in the file (exit 0
# here); only a failed read returns non-zero.
contract_attempt_show() {
  _managed=$1
  _attempt=$2
  _out=$3
  _err=$(mktemp) || return 1
  if agentfleet attempts show "$_managed" "$_attempt" --json >"$_out" 2>"_err"; then
    rm -f "$_err"
    return 0
  fi
  _code=$?
  if grep -q '"code"[ ]*:[ ]*"not_found"' "$_out" 2>/dev/null; then
    rm -f "$_err"
    return 0
  fi
  cat "$_err" >&2 || true
  rm -f "$_err"
  echo "error: agentfleet attempts show failed for attempt '$_attempt' (no legacy fallback)" >&2
  return "$_code"
}

# Export one Attempt Archive tar to a file. agentfleet verifies size and
# `sha256` against the streamed manifest and refetches a torn read within
# its bound; a tar that stays torn exits non-zero and nothing is cached.
contract_attempt_export() {
  _managed=$1
  _attempt=$2
  _tar=$3
  _err=$(mktemp) || return 1
  if agentfleet attempts export "$_managed" "$_attempt" --output "$_tar" 2>"$_err"; then
    rm -f "$_err"
    return 0
  fi
  _code=$?
  cat "$_err" >&2 || true
  rm -f "$_err" "$_tar"
  echo "error: agentfleet attempts export failed for attempt '$_attempt' (no legacy fallback)" >&2
  return "$_code"
}
