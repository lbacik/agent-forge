#!/bin/sh
# dashboard.sh -- deploy one agent-dashboard per Docker context.
#
# Usage: dashboard.sh [--context <ctx>] <command> [args]
#
#   init --ref <tag|sha> [--profile local|tunnel|lan|readonly] [--port <n>]
#        [--local-port <n>]                              (tunnel)
#        [--proxy-network <net> --virtual-host <name>
#         [--letsencrypt-host <name>]]                   (lan)
#        [--bind <lan-ip> --host <name>[,<name>...]]     (readonly)
#        [--force]
#   up
#   upgrade --ref <tag|sha>
#   account add|reset|role|remove|list [args]
#   tunnel [--local-port <n>] [--ssh-host <[user@]host>]
#   status
#   down
#
# A deployment lives in dashboards/<ctx>/ (git-ignored): the upstream
# docker-compose.yml, docker-compose.lan.yml and .env.example fetched at the
# pinned ref, .upstream-ref, the forge overlay docker-compose.forge.yml (the
# upstream git build context at ${DASHBOARD_REF}) and .env. It is not a
# Managed Instance and never lives under agent-instances/.
#
# Every Docker and Compose call goes through the context (DOCKER_CONTEXT,
# default orbstack). The image builds on that daemon, at its native
# architecture. --ref is a tag or a full 40-character commit SHA; a branch,
# a short SHA or an unknown ref is rejected before anything is fetched or
# written. up and upgrade refuse to build while .upstream-ref and
# DASHBOARD_REF in .env differ. Nothing here passes -v or removes a volume:
# the state volume holds the Operator accounts and the Control audit.
#
# Exit codes: 0 success; 1 failure (ref rejected or mismatched, existing .env
# without --force, missing proxy network, Docker/Compose failure, a status
# problem); 2 usage error.
#
# Test seam (set only by tests/dashboard-helpers.sh): DASHBOARDS_DIR, the
# dashboards/ root.

set -eu

UPSTREAM_REPO=lbacik/agent-dashboard
UPSTREAM_GIT=https://github.com/$UPSTREAM_REPO.git
UPSTREAM_RAW=https://raw.githubusercontent.com/$UPSTREAM_REPO
UPSTREAM_FILES="docker-compose.yml docker-compose.lan.yml .env.example"
OVERLAY=docker-compose.forge.yml
FILES_BASE=docker-compose.yml:$OVERLAY
FILES_LAN=$FILES_BASE:docker-compose.lan.yml
GID_PROBE_IMAGE=alpine:3
SOCK=/var/run/docker.sock
# Forge-only .env keys: none of them is an upstream variable name.
FORGE_KEYS="DASHBOARD_REF FORGE_PROFILE FORGE_TUNNEL_LOCAL_PORT"
# Keys the helper writes; a value in the caller's environment would win over
# .env inside Compose, so they are cleared below.
MANAGED_KEYS="COMPOSE_FILE COMPOSE_PROJECT_NAME DASHBOARD_REF DOCKER_GID DASHBOARD_BIND DASHBOARD_PORT AGENT_DASHBOARD_LAN_MODE AGENT_DASHBOARD_ALLOWED_HOSTS AGENT_DASHBOARD_CONTROL AGENT_DASHBOARD_UNAUTHENTICATED_CONTROL PROXY_NETWORK VIRTUAL_HOST LETSENCRYPT_HOST AGENT_DASHBOARD_TRUSTED_PROXIES"

usage="usage: dashboard.sh [--context <ctx>] init|up|upgrade|account|tunnel|status|down [args] (see the header of this script)"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
ROOT=${DASHBOARDS_DIR:-$(cd "$SCRIPT_DIR/../../../.." && pwd)/dashboards}
FLEET_SH=$SCRIPT_DIR/../../debug-agent/scripts/fleet.sh

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage_error() {
  printf 'error: %s\n' "$1" >&2
  printf '%s\n' "$usage" >&2
  exit 2
}

warn() {
  printf 'warning: %s\n' "$1" >&2
}

# need_value <option> <remaining-arg-count>: an option's value is missing.
need_value() {
  [ "$2" -ge 2 ] || usage_error "$1 needs a value"
}

# --- value checks (they keep newlines and shell syntax out of .env) --------

check_port() {
  case "$2" in
    ''|*[!0-9]*) usage_error "$1 must be a port number: '$2'" ;;
  esac
  [ "$2" -ge 1 ] && [ "$2" -le 65535 ] || usage_error "$1 must be between 1 and 65535: '$2'"
}

check_name() {
  case "$2" in
    ''|*[!A-Za-z0-9._-]*) usage_error "$1 must be a name of letters, digits, '.', '_' or '-': '$2'" ;;
  esac
}

check_hosts() {
  case "$2" in
    ''|*[!A-Za-z0-9.,:_-]*) usage_error "$1 must be host names or addresses, comma-separated: '$2'" ;;
  esac
}

check_host() {
  case "$2" in
    ''|*[!A-Za-z0-9.:_-]*) usage_error "$1 must be one host name: '$2'" ;;
  esac
}

check_ip() {
  case "$2" in
    ''|*[!0-9A-Fa-f.:]*) usage_error "$1 must be an IP address: '$2'" ;;
  esac
}

# --- .env access -----------------------------------------------------------

env_get() {
  sed -n "s/^$1=//p" "$2" | tail -n 1
}

# env_set KEY VALUE FILE: replace KEY's line, keep every other line as is.
env_set() {
  _es_tmp=$(mktemp "$3.XXXXXX") || exit 1
  awk -v k="$1" -v v="$2" '
    index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$3" >"$_es_tmp"
  mv "$_es_tmp" "$3"
}

# Variable names an env file assigns, commented-out examples included.
env_keys() {
  sed -n 's/^#\{0,1\}\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$1" | sort -u
}

# --- upstream ref ----------------------------------------------------------

is_full_sha() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

# validate_ref <ref>: a tag or a full commit SHA that exists upstream. Runs
# before anything is fetched or written.
validate_ref() {
  _ref=$1
  case "$_ref" in
    '') usage_error "--ref needs a tag or a full 40-character commit SHA" ;;
    -*|*[!A-Za-z0-9._/+-]*|*..*|*/) die "ref '$_ref' is not a valid tag or commit SHA" ;;
  esac
  if is_full_sha "$_ref"; then
    command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
    curl -fsSI -o /dev/null "$UPSTREAM_RAW/$_ref/docker-compose.yml" 2>/dev/null \
      || die "commit $_ref does not exist upstream ($UPSTREAM_REPO), or GitHub is unreachable"
    return 0
  fi
  if printf '%s' "$_ref" | grep -Eq '^[0-9a-f]{7,39}$'; then
    die "ref '$_ref' looks like a short commit SHA; pin the full 40-character SHA or a tag"
  fi
  command -v git >/dev/null 2>&1 || die "git not found on PATH"
  _refs=$(git ls-remote "$UPSTREAM_GIT" "refs/tags/$_ref" "refs/heads/$_ref") \
    || die "cannot list the refs of $UPSTREAM_GIT (git ls-remote failed)"
  if printf '%s\n' "$_refs" | awk -v r="refs/tags/$_ref" '$2 == r { f = 1 } END { exit !f }'; then
    return 0
  fi
  if printf '%s\n' "$_refs" | awk -v r="refs/heads/$_ref" '$2 == r { f = 1 } END { exit !f }'; then
    die "ref '$_ref' is a branch of $UPSTREAM_REPO; pin a tag or a full 40-character commit SHA"
  fi
  die "ref '$_ref' is not a tag of $UPSTREAM_REPO (nor a full 40-character commit SHA)"
}

# fetch_upstream <ref> <dir>: the three upstream files, into a scratch dir.
fetch_upstream() {
  command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
  for _f in $UPSTREAM_FILES; do
    curl -fsSL -o "$2/$_f" "$UPSTREAM_RAW/$1/$_f" \
      || die "cannot fetch $_f at $1 from $UPSTREAM_REPO"
  done
}

# install_upstream <ref> <scratch-dir>: put the fetched files, the overlay and
# .upstream-ref into the deployment directory.
install_upstream() {
  mkdir -p "$DIR"
  for _f in $UPSTREAM_FILES; do cp "$2/$_f" "$DIR/$_f"; done
  write_overlay
  printf '%s\n' "$1" >"$DIR/.upstream-ref"
}

write_overlay() {
  cat >"$DIR/$OVERLAY" <<EOF
# Written by agent-forge (deploy-dashboard skill, dashboard.sh); do not edit.
# The only change to upstream: build the image from the upstream git build
# context at DASHBOARD_REF (a tag or full commit SHA, set in .env and equal
# to .upstream-ref), on the target daemon at its native architecture.
services:
  dashboard:
    build:
      context: "$UPSTREAM_GIT#\${DASHBOARD_REF:?set DASHBOARD_REF in .env to a tag or full commit SHA}"
EOF
}

# --- Docker ----------------------------------------------------------------

compose() {
  (cd "$DIR" && docker compose "$@")
}

# proxy_subnets <network>: the network's subnets, comma-separated; fails when
# the network does not exist on the context.
proxy_subnets() {
  _subs=$(docker network inspect "$1" --format '{{range .IPAM.Config}}{{.Subnet}},{{end}}' 2>/dev/null) \
    || return 1
  printf '%s' "${_subs%,}"
}

require_proxy_network() {
  proxy_subnets "$1" >/dev/null \
    || die "proxy network '$1' does not exist on context '$CONTEXT'; create the reverse proxy first (docker --context $CONTEXT network ls)"
}

detect_gid() {
  _gid=$(docker run --rm -v "$SOCK:$SOCK" "$GID_PROBE_IMAGE" stat -c %g "$SOCK") \
    || die "cannot read the group of $SOCK on context '$CONTEXT'"
  case "$_gid" in
    ''|*[!0-9]*) die "unexpected group id of $SOCK on context '$CONTEXT': '$_gid'" ;;
  esac
  printf '%s' "$_gid"
}

# --- deployment ------------------------------------------------------------

require_deployment() {
  [ -f "$DIR/.env" ] || die "no dashboard deployment for context '$CONTEXT' ($DIR/.env missing); run init first"
  PROFILE=$(env_get FORGE_PROFILE "$DIR/.env")
  PORT=$(env_get DASHBOARD_PORT "$DIR/.env")
}

check_ref_match() {
  [ -f "$DIR/.upstream-ref" ] || die "$DIR/.upstream-ref is missing; re-run init or upgrade"
  _up=$(sed -n '1p' "$DIR/.upstream-ref")
  _env=$(env_get DASHBOARD_REF "$DIR/.env")
  [ -n "$_env" ] || die "DASHBOARD_REF is not set in $DIR/.env"
  [ "$_up" = "$_env" ] \
    || die "ref mismatch: .upstream-ref is '$_up' but DASHBOARD_REF in .env is '$_env'; the compose files and the build must come from one ref (use upgrade --ref)"
}

# base_url: the address operators open, also the account --url.
base_url() {
  case "$PROFILE" in
    local) printf 'http://localhost:%s' "$PORT" ;;
    tunnel) printf 'http://localhost:%s' "$(env_get FORGE_TUNNEL_LOCAL_PORT "$DIR/.env")" ;;
    lan) printf 'https://%s' "$(env_get VIRTUAL_HOST "$DIR/.env")" ;;
    readonly) printf 'http://%s:%s' "$(env_get DASHBOARD_BIND "$DIR/.env")" "$PORT" ;;
    *) die "unknown FORGE_PROFILE '$PROFILE' in $DIR/.env" ;;
  esac
}

readonly_warning() {
  warn "profile readonly has no sign-in: anyone who can reach $(base_url) sees the fleet"
}

build_and_start() {
  check_ref_match
  if [ "$PROFILE" = lan ]; then
    require_proxy_network "$(env_get PROXY_NETWORK "$DIR/.env")"
  fi
  compose config -q || die "docker compose config failed in $DIR"
  compose up -d --build --wait || die "docker compose up failed on context '$CONTEXT'"
  printf 'dashboard up on context %s (profile %s, ref %s)\n' "$CONTEXT" "$PROFILE" "$(env_get DASHBOARD_REF "$DIR/.env")"
  case "$PROFILE" in
    tunnel) printf 'open %s through: dashboard.sh --context %s tunnel\n' "$(base_url)" "$CONTEXT" ;;
    *) printf 'open %s\n' "$(base_url)" ;;
  esac
  if [ "$PROFILE" = readonly ]; then readonly_warning; fi
}

# --- commands --------------------------------------------------------------

cmd_init() {
  ref=""; profile=""; port=8000; local_port=""; proxy_network=""
  virtual_host=""; letsencrypt_host=""; bind=""; hosts=""; force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref) need_value "$1" $#; ref=$2; shift 2 ;;
      --profile) need_value "$1" $#; profile=$2; shift 2 ;;
      --port) need_value "$1" $#; check_port "$1" "$2"; port=$2; shift 2 ;;
      --local-port) need_value "$1" $#; check_port "$1" "$2"; local_port=$2; shift 2 ;;
      --proxy-network) need_value "$1" $#; check_name "$1" "$2"; proxy_network=$2; shift 2 ;;
      --virtual-host) need_value "$1" $#; check_host "$1" "$2"; virtual_host=$2; shift 2 ;;
      --letsencrypt-host) need_value "$1" $#; check_host "$1" "$2"; letsencrypt_host=$2; shift 2 ;;
      --bind) need_value "$1" $#; check_ip "$1" "$2"; bind=$2; shift 2 ;;
      --host) need_value "$1" $#; check_hosts "$1" "$2"; hosts=$2; shift 2 ;;
      --force) force=1; shift ;;
      *) usage_error "init: unknown argument '$1'" ;;
    esac
  done
  [ -n "$ref" ] || usage_error "init needs --ref <tag|full-commit-sha>"
  if [ -z "$profile" ]; then
    if [ "$CONTEXT" = orbstack ]; then profile=local; else profile=tunnel; fi
  fi
  case "$profile" in
    local|tunnel|lan|readonly) ;;
    *) usage_error "unknown profile '$profile' (local, tunnel, lan or readonly)" ;;
  esac
  # Profile options belong to one profile each.
  if [ -n "$local_port" ] && [ "$profile" != tunnel ]; then usage_error "--local-port is a tunnel option"; fi
  if [ "$profile" != lan ] && [ -n "$proxy_network$virtual_host$letsencrypt_host" ]; then
    usage_error "--proxy-network, --virtual-host and --letsencrypt-host are lan options"
  fi
  if [ "$profile" != readonly ] && [ -n "$bind$hosts" ]; then usage_error "--bind and --host are readonly options"; fi
  if [ "$profile" = lan ]; then
    [ -n "$proxy_network" ] || usage_error "profile lan needs --proxy-network <net>"
    [ -n "$virtual_host" ] || usage_error "profile lan needs --virtual-host <name>"
  fi
  if [ "$profile" = readonly ]; then
    [ -n "$bind" ] || usage_error "profile readonly needs --bind <lan-ip>"
    [ -n "$hosts" ] || usage_error "profile readonly needs --host <name>[,<name>...]"
  fi
  if [ -f "$DIR/.env" ] && [ "$force" -ne 1 ]; then
    die "$DIR/.env exists; pass --force to overwrite it (the state volume is kept either way)"
  fi

  validate_ref "$ref"
  subnets=""
  if [ "$profile" = lan ]; then
    require_proxy_network "$proxy_network"
    subnets=$(proxy_subnets "$proxy_network")
    [ -n "$subnets" ] || die "proxy network '$proxy_network' on context '$CONTEXT' has no subnet"
  fi
  gid=$(detect_gid)

  scratch=$(mktemp -d) || exit 1
  trap 'rm -rf "$scratch"' EXIT
  fetch_upstream "$ref" "$scratch"

  install_upstream "$ref" "$scratch"

  compose_file=$FILES_BASE
  lan_mode=on
  allowed=localhost
  control=""
  dash_bind=127.0.0.1
  case "$profile" in
    lan)
      compose_file=$FILES_LAN
      allowed=$virtual_host
      ;;
    readonly)
      lan_mode=off
      allowed=$hosts
      control=off
      dash_bind=$bind
      ;;
  esac
  {
    printf '# Written by agent-forge dashboard.sh init (context %s, profile %s).\n' "$CONTEXT" "$profile"
    printf '# DASHBOARD_REF must equal .upstream-ref: change both with dashboard.sh upgrade --ref.\n'
    printf 'COMPOSE_FILE=%s\n' "$compose_file"
    printf 'DASHBOARD_REF=%s\n' "$ref"
    printf 'FORGE_PROFILE=%s\n' "$profile"
    printf 'DOCKER_GID=%s\n' "$gid"
    printf 'DASHBOARD_BIND=%s\n' "$dash_bind"
    printf 'DASHBOARD_PORT=%s\n' "$port"
    printf 'AGENT_DASHBOARD_LAN_MODE=%s\n' "$lan_mode"
    printf 'AGENT_DASHBOARD_ALLOWED_HOSTS=%s\n' "$allowed"
    printf 'AGENT_DASHBOARD_CONTROL=%s\n' "$control"
    printf 'AGENT_DASHBOARD_UNAUTHENTICATED_CONTROL=off\n'
    case "$profile" in
      tunnel)
        printf 'FORGE_TUNNEL_LOCAL_PORT=%s\n' "${local_port:-$port}"
        ;;
      lan)
        printf 'PROXY_NETWORK=%s\n' "$proxy_network"
        printf 'VIRTUAL_HOST=%s\n' "$virtual_host"
        printf 'LETSENCRYPT_HOST=%s\n' "$letsencrypt_host"
        printf 'AGENT_DASHBOARD_TRUSTED_PROXIES=%s\n' "$subnets"
        ;;
    esac
  } >"$DIR/.env"

  PROFILE=$profile
  PORT=$port
  printf 'initialised %s (context %s, profile %s, ref %s, DOCKER_GID %s)\n' "$DIR" "$CONTEXT" "$profile" "$ref" "$gid"
  printf 'next: dashboard.sh --context %s up\n' "$CONTEXT"
  if [ "$profile" = readonly ]; then readonly_warning; fi
}

cmd_up() {
  [ $# -eq 0 ] || usage_error "up takes no arguments"
  require_deployment
  build_and_start
}

cmd_upgrade() {
  ref=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref) need_value "$1" $#; ref=$2; shift 2 ;;
      *) usage_error "upgrade: unknown argument '$1'" ;;
    esac
  done
  [ -n "$ref" ] || usage_error "upgrade needs --ref <tag|full-commit-sha>"
  require_deployment
  validate_ref "$ref"

  scratch=$(mktemp -d) || exit 1
  trap 'rm -rf "$scratch"' EXIT
  fetch_upstream "$ref" "$scratch"

  # Variables of the new .env.example against .env, forge-only keys aside.
  # "new" lists those the previous .env.example did not list either; the
  # optional upstream knobs .env leaves unset are only counted.
  env_keys "$DIR/.env" >"$scratch/env.keys"
  env_keys "$scratch/.env.example" >"$scratch/new.keys"
  if [ -f "$DIR/.env.example" ]; then env_keys "$DIR/.env.example" >"$scratch/old.keys"; else : >"$scratch/old.keys"; fi
  # shellcheck disable=SC2086 # word-splitting the key list is intended
  printf '%s\n' $FORGE_KEYS | sort -u >"$scratch/forge.keys"
  comm -23 "$scratch/new.keys" "$scratch/env.keys" >"$scratch/unset.keys"
  added=$(comm -23 "$scratch/unset.keys" "$scratch/old.keys" | tr '\n' ' ')
  known=$(comm -12 "$scratch/unset.keys" "$scratch/old.keys" | wc -l | tr -d ' ')
  removed=$(comm -23 "$scratch/env.keys" "$scratch/new.keys" | comm -23 - "$scratch/forge.keys" | tr '\n' ' ')
  printf '.env.example at %s against .env:\n' "$ref"
  printf '  new (in .env.example, not in .env): %s\n' "${added:-none}"
  printf '  removed (in .env, not in .env.example): %s\n' "${removed:-none}"
  printf '  unchanged upstream variables left unset in .env: %s\n' "$known"

  install_upstream "$ref" "$scratch"
  env_set DASHBOARD_REF "$ref" "$DIR/.env"
  printf 'upgraded %s to %s (.env kept, DASHBOARD_REF updated)\n' "$DIR" "$ref"
  build_and_start
}

cmd_account() {
  [ $# -ge 1 ] || usage_error "account needs add|reset|role|remove|list"
  sub=$1
  case "$sub" in
    add|reset|role|remove|list) ;;
    *) usage_error "unknown account command '$sub' (add, reset, role, remove or list)" ;;
  esac
  require_deployment
  for a in "$@"; do
    case "$a" in
      --url|--url=*) usage_error "account: --url is set from the profile's base address" ;;
    esac
  done
  if [ "$sub" = add ] || [ "$sub" = reset ]; then
    [ "$PROFILE" != readonly ] || die "profile readonly has no sign-in, so its accounts can never sign in; re-run init with another profile"
    url=$(base_url)
    set -- "$@" --url "$url"
  fi
  # The Set-password link goes to the operator's terminal only: no copy is
  # kept in a file or log.
  compose exec -T dashboard agent-dashboard account "$@"
}

cmd_tunnel() {
  lport=""; ssh_host=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --local-port) need_value "$1" $#; check_port "$1" "$2"; lport=$2; shift 2 ;;
      --ssh-host) need_value "$1" $#; check_host "$1" "${2#*@}"; ssh_host=$2; shift 2 ;;
      *) usage_error "tunnel: unknown argument '$1'" ;;
    esac
  done
  require_deployment
  case "$PROFILE" in
    lan|readonly)
      printf 'profile %s needs no tunnel: open %s\n' "$PROFILE" "$(base_url)"
      return 0
      ;;
  esac
  stored=$(env_get FORGE_TUNNEL_LOCAL_PORT "$DIR/.env")
  if [ -z "$lport" ]; then lport=${stored:-$PORT}; fi
  if [ -n "$stored" ] && [ "$lport" != "$stored" ]; then
    warn "Set-password links point at local port $stored; open them on that port, or re-run init with --local-port $lport"
  fi
  ssh_port=""
  if [ -z "$ssh_host" ]; then
    endpoint=$(docker context inspect "$CONTEXT" --format '{{.Endpoints.docker.Host}}') \
      || die "cannot inspect docker context '$CONTEXT'"
    case "$endpoint" in
      ssh://*)
        hostpart=${endpoint#ssh://}
        hostpart=${hostpart%%/*}
        case "$hostpart" in
          *:*) ssh_port=${hostpart##*:}; ssh_host=${hostpart%:*} ;;
          *) ssh_host=$hostpart ;;
        esac
        ;;
      *)
        if [ "$PROFILE" = local ]; then
          printf 'profile local on a local daemon needs no tunnel: open %s\n' "$(base_url)"
          return 0
        fi
        printf 'error: context %s has a non-SSH endpoint (%s), so the tunnel host cannot be derived.\n' "$CONTEXT" "$endpoint" >&2
        printf 'Which host runs this daemon? Re-run with --ssh-host <[user@]host>, or use:\n' >&2
        printf '  ssh -L %s:127.0.0.1:%s <host>\n' "$lport" "$PORT" >&2
        exit 1
        ;;
    esac
  fi
  if [ -n "$ssh_port" ]; then
    printf 'ssh -p %s -L %s:127.0.0.1:%s %s\n' "$ssh_port" "$lport" "$PORT" "$ssh_host"
  else
    printf 'ssh -L %s:127.0.0.1:%s %s\n' "$lport" "$PORT" "$ssh_host"
  fi
  printf 'then open http://localhost:%s\n' "$lport"
}

cmd_status() {
  [ $# -eq 0 ] || usage_error "status takes no arguments"
  require_deployment
  problem=0
  up_ref=$(sed -n '1p' "$DIR/.upstream-ref" 2>/dev/null || true)
  printf 'dashboard (context %s, profile %s, ref %s, .upstream-ref %s)\n' \
    "$CONTEXT" "$PROFILE" "$(env_get DASHBOARD_REF "$DIR/.env")" "${up_ref:-missing}"

  ps_out=$(compose ps -a --format '{{.Name}}|{{.State}}|{{.Health}}' dashboard 2>/dev/null) || ps_out=""
  ps_line=$(printf '%s\n' "$ps_out" | sed -n '1p')
  state=""
  if [ -z "$ps_line" ]; then
    printf 'container: not created (run up)\n'
    problem=1
  else
    cname=${ps_line%%|*}; rest=${ps_line#*|}
    state=${rest%%|*}; health=${rest#*|}
    printf 'container: %s %s (health %s)\n' "$cname" "$state" "${health:-none}"
    if [ "$state" != running ]; then problem=1; fi
    case "$health" in
      unhealthy|starting) problem=1 ;;
    esac
  fi

  if [ "$state" = running ]; then
    startup=$(compose logs --no-color --no-log-prefix dashboard 2>/dev/null | grep '^agent-dashboard: ' | tail -n 3 || true)
    if [ -n "$startup" ]; then
      printf 'startup:\n'
      printf '%s\n' "$startup" | sed 's/^/  /'
    else
      printf 'startup: no startup line (LAN mode off, Host check on)\n'
    fi

    set +e
    sock_out=$(compose exec -T dashboard docker version --format '{{.Server.Version}}' 2>&1)
    sock_code=$?
    set -e
    if [ "$sock_code" -eq 0 ]; then
      printf 'docker socket: ok (server %s)\n' "$sock_out"
    else
      problem=1
      case "$sock_out" in
        *"permission denied"*)
          printf 'docker socket: permission denied: DOCKER_GID=%s in .env is likely wrong for context %s;\n' "$(env_get DOCKER_GID "$DIR/.env")" "$CONTEXT"
          printf '  check it with: docker --context %s run --rm -v %s:%s %s stat -c %%g %s\n' "$CONTEXT" "$SOCK" "$SOCK" "$GID_PROBE_IMAGE" "$SOCK"
          ;;
        *)
          printf 'docker socket: error: %s\n' "$(printf '%s\n' "$sock_out" | sed -n '1p')"
          ;;
      esac
    fi

    printf 'accounts:\n'
    set +e
    acc_out=$(compose exec -T dashboard agent-dashboard account list 2>&1)
    acc_code=$?
    set -e
    printf '%s\n' "$acc_out" | sed 's/^/  /'
    if [ "$acc_code" -ne 0 ]; then problem=1; fi
  else
    printf 'startup, docker socket, accounts: skipped (container not running)\n'
  fi

  # The dashboard shows labelled Managed Instances only.
  fleet_err=$(mktemp) || exit 1
  set +e
  fleet_out=$("$FLEET_SH" --context "$CONTEXT" 2>"$fleet_err")
  fleet_code=$?
  set -e
  legacy=$(printf '%s\n' "$fleet_out" | sed -n '/^legacy (/,$p')
  if [ -n "$legacy" ]; then
    printf '%s\n' "$legacy" | sed '1s/^legacy (not managed by agentfleet)/legacy containers (not shown by the dashboard)/'
  else
    printf 'legacy containers: unavailable (fleet.sh exit %s: %s)\n' "$fleet_code" "$(sed -n '1p' "$fleet_err")"
  fi
  rm -f "$fleet_err"

  if [ "$PROFILE" = readonly ]; then readonly_warning; fi
  if [ "$problem" -ne 0 ]; then
    printf 'error: the dashboard on context %s needs attention (see above)\n' "$CONTEXT" >&2
    exit 1
  fi
}

cmd_down() {
  [ $# -eq 0 ] || usage_error "down takes no arguments (it never removes volumes)"
  require_deployment
  compose down || die "docker compose down failed on context '$CONTEXT'"
  printf 'dashboard on context %s stopped; the state volume is kept\n' "$CONTEXT"
}

# --- main ------------------------------------------------------------------

CONTEXT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --context) need_value "$1" $#; CONTEXT=$2; shift 2 ;;
    -h|--help) printf '%s\n' "$usage"; exit 0 ;;
    -*) usage_error "unknown option '$1'" ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || usage_error "missing command"
CONTEXT=${CONTEXT:-orbstack}
case "$CONTEXT" in
  .|..|*[!A-Za-z0-9._-]*) usage_error "invalid context name '$CONTEXT'" ;;
esac
DIR=$ROOT/$CONTEXT
PROFILE=""
PORT=""

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
# Every Docker and Compose call goes through the context: DOCKER_HOST would
# override it, and a managed key in the environment would override .env.
unset DOCKER_HOST
for k in $MANAGED_KEYS; do unset "$k"; done
export DOCKER_CONTEXT="$CONTEXT"

cmd=$1
shift
case "$cmd" in
  init) cmd_init "$@" ;;
  up) cmd_up "$@" ;;
  upgrade) cmd_upgrade "$@" ;;
  account) cmd_account "$@" ;;
  tunnel) cmd_tunnel "$@" ;;
  status) cmd_status "$@" ;;
  down) cmd_down "$@" ;;
  *) usage_error "unknown command '$cmd'" ;;
esac
