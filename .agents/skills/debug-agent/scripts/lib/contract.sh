#!/bin/sh
# shellcheck disable=SC2034 # library: sourced by locate-agent.sh, whose use of these constants shellcheck cannot see.
# Shared contract-path helpers for the debug-agent skill. Source it, don't run it.
#
# The operator contract (major 1) is consumed through `agentfleet`, the
# host-side client shipped by agent-operator-contract. Forge ships no Python
# package and vendors no library code: `agentfleet` is installed on the
# operator's host from the pinned tag below. This file is the one place in
# the skills that names the tag; README.md names it in its Operator contract
# section, which is the one place in the docs.
#
# Path selection: the Instance compose file carrying the
# `io.github.lbacik.agent-operator.contract` Compose label is observed only
# through `agentfleet`, whether or not a container exists yet. A compose file
# without the label stays on the legacy path. The container's own label is
# still checked per Worker (see pool-status.sh): a running container without
# the label, under a labelled compose file, is reported as a mismatch rather
# than silently treated as legacy. Compatibility is decided by `agentfleet`'s
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

# compose_has_contract_label <compose-file> -- true when the Instance compose
# file carries the contract discovery label. The compose label decides the
# path: a labelled Instance is observed only through `agentfleet`, whether or
# not a container exists yet. An unlabelled Instance stays on the legacy path.
compose_has_contract_label() {
  [ -n "${1:-}" ] && [ -f "$1" ] && grep -q "$CONTRACT_LABEL" "$1" 2>/dev/null
}

# compose_service_for_instance <compose-file> <instance> -- print the Compose
# service whose `instance` discovery label equals <instance>. The service name
# is never assumed: simple-coding-agent renders `agent` / `agent-<n>`, the
# coding-agent adapter renders `worker`. Reads the compose file on disk (the
# same file the helpers already parse for the Worker list); the rendered
# Compose model carries the same labels. Prints nothing and returns non-zero
# when no service names that instance.
compose_service_for_instance() {
  _csf=${1:-}
  _want=${2:-}
  [ -n "$_csf" ] && [ -f "$_csf" ] && [ -n "$_want" ] || return 1
  _cur=""
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "  "*)
        case "$_line" in
          "   "* | "	"*) ;;
          *)
            _cur=${_line#"  "}
            _cur=${_cur%%:*}
            ;;
        esac
        ;;
    esac
    case "$_line" in
      *"$INSTANCE_LABEL:"*)
        _v=${_line##*:}
        _v=$(printf '%s' "$_v" | sed 's/^[ 	]*//;s/[ 	]*$//;s/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//')
        if [ "$_v" = "$_want" ] && [ -n "$_cur" ]; then
          printf '%s' "$_cur"
          return 0
        fi
        ;;
    esac
  done < "$_csf"
  return 1
}

# contract_service_for_worker <compose-file> <short> <n> [worker-id] -- print
# the Compose service of one Worker of a labelled Instance: the service whose
# `instance` label is that Worker's Managed Instance name. Falls back to the
# backend mapping (`coding-agent` -> `worker`) for the first Worker when no
# service names it; returns non-zero when neither resolves.
contract_service_for_worker() {
  _cwf=$1
  _cwshort=${2:-}
  _cwnum=${3:-1}
  _cwwid=${4:-}
  _cwmanaged=$(managed_instance_name "$_cwshort" "$_cwnum" "$_cwwid")
  _cwsvc=$(compose_service_for_instance "$_cwf" "$_cwmanaged" || true)
  if [ -n "$_cwsvc" ]; then
    printf '%s' "$_cwsvc"
    return 0
  fi
  if [ "$_cwnum" -eq 1 ] \
    && grep -q "$BACKEND_LABEL.*coding-agent" "$_cwf" 2>/dev/null; then
    printf 'worker'
    return 0
  fi
  return 1
}

# contract_worker_services <compose-file> <short> -- print one `n|service`
# line per labelled Worker service of a labelled Instance, in compose-file
# order: the Worker number follows from the service's `instance` label
# (`<short>` is Worker 1, `<short>-<n>` is Worker n >= 2). Unlabelled
# services (one-off seats like the coding-agent `agent` and `validate`, or a
# foreign service) print nothing.
contract_worker_services() {
  _cwsf=${1:-}
  _cwsshort=${2:-}
  [ -n "$_cwsf" ] && [ -f "$_cwsf" ] && [ -n "$_cwsshort" ] || return 1
  _cur=""
  _has=0
  _inst=""
  _emit_worker_service() {
    if [ "$_has" -eq 1 ] && [ -n "$_inst" ] && [ -n "$_cur" ]; then
      if [ "$_inst" = "$_cwsshort" ]; then
        printf '1|%s\n' "$_cur"
      else
        case "$_inst" in
          "$_cwsshort"-*)
            _n=${_inst#"$_cwsshort-"}
            case "$_n" in
              ''|*[!0-9]*|0) ;;
              *) printf '%s|%s\n' "$_n" "$_cur" ;;
            esac
            ;;
        esac
      fi
    fi
  }
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "  "*)
        case "$_line" in
          "   "* | "	"*) ;;
          *)
            _emit_worker_service
            _cur=${_line#"  "}
            _cur=${_cur%%:*}
            _has=0
            _inst=""
            ;;
        esac
        ;;
    esac
    case "$_line" in
      *"$CONTRACT_LABEL:"*) _has=1 ;;
    esac
    case "$_line" in
      *"$INSTANCE_LABEL:"*)
        _v=${_line##*:}
        _v=$(printf '%s' "$_v" | sed 's/^[ 	]*//;s/[ 	]*$//;s/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//')
        _inst=$_v
        ;;
    esac
  done < "$_cwsf"
  _emit_worker_service
  return 0
}
