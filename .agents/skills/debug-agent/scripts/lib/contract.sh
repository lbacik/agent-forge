#!/bin/sh
# Shared contract-path helpers for the debug-agent skill. Source it, don't run it.
#
# The operator contract (major 1) is consumed through `agentfleet`, the
# host-side client shipped by agent-operator-contract. Forge ships no Python
# package and vendors no library code: `agentfleet` is installed on the
# operator's host from the pinned tag below. This file is the one place in
# the skills that names the tag; README.md names it in its Operator contract
# section, which is the one place in the docs.
#
# Path selection (see locate-agent.sh): a container carrying the
# `io.github.lbacik.agent-operator.contract` Compose label is observed only
# through `agentfleet`. A container without the label stays on the legacy
# path. The label is only a hint; compatibility is decided by `agentfleet`'s
# runtime `--contract` check. A `contract_mismatch`, `unsupported` or
# `agent_unreachable` reply is reported as such and never retried through the
# legacy grammar.

# Pinned agent-operator-contract release tag. To move to a newer v1.x.y,
# change this line; a new major also means reviewing CONTEXT.md.
CONTRACT_TAG=v1.0.4
# Contract major spoken by the pinned tag (agentfleet --version reports it).
CONTRACT_MAJOR=1

CONTRACT_LABEL=io.github.lbacik.agent-operator.contract
INSTANCE_LABEL=io.github.lbacik.agent-operator.instance
BACKEND_LABEL=io.github.lbacik.agent-operator.backend
EXEC_USER_LABEL=io.github.lbacik.agent-operator.exec-user

# Print the install command for `agentfleet` from the pinned tag.
contract_install_command() {
  printf '%s' "uv tool install \"agent-operator-contract @ git+https://github.com/lbacik/agent-operator-contract@$CONTRACT_TAG\""
}

# Stop unless `agentfleet` is present and speaks the expected contract major.
# Prints the install command; never reads container files. Call before any
# contract-path `agentfleet` invocation.
require_agentfleet() {
  if ! command -v agentfleet >/dev/null 2>&1; then
    echo "error: agentfleet is not installed (contract path needs it)" >&2
    echo "install: $(contract_install_command)" >&2
    echo "expected contract major: $CONTRACT_MAJOR (tag $CONTRACT_TAG)" >&2
    return 3
  fi
  _ver=$(agentfleet --version 2>/dev/null || true)
  case "$_ver" in
    *"contract major $CONTRACT_MAJOR"*)
      return 0
      ;;
    *)
      echo "error: agentfleet speaks an unexpected contract major: ${_ver:-<no version output>}" >&2
      echo "expected contract major: $CONTRACT_MAJOR (tag $CONTRACT_TAG)" >&2
      echo "install: $(contract_install_command)" >&2
      return 3
      ;;
  esac
}

# Managed Instance name for one Worker of a Forge Instance: the short name
# (directory without the `agent-` prefix) for the first Worker, the Worker id
# `<short>-<n>` for Worker n >= 2. Matches the `instance` discovery label
# rendered by create-agent.
managed_instance_name() {
  _short=$1
  _num=${2:-1}
  _wid=${3:-}
  if [ "$_num" -eq 1 ]; then
    printf '%s' "$_short"
  else
    if [ -n "$_wid" ]; then
      printf '%s' "$_wid"
    else
      printf '%s-%s' "$_short" "$_num"
    fi
  fi
}
