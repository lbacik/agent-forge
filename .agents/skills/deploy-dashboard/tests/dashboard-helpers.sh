#!/bin/sh
# dashboard-helpers.sh -- pin the deploy-dashboard helper against stubbed
# Docker, curl and git.
#
# Runs scripts/dashboard.sh with fakes first on PATH (tests/stub/bin: docker,
# curl, git and agentfleet), which log their argv through the debug-agent
# stub logger (debug-agent/tests/stub/lib/log-argv.sh) and reply from a scene
# directory and an upstream fixture this script writes. No Docker host, no
# network, no secrets. Covers ref validation, init per access profile, the
# existing .env guard, the lan proxy-network check, up, upgrade, down,
# account, tunnel and status.
#
# Usage (from anywhere in this repository):
#
#   .agents/skills/deploy-dashboard/tests/dashboard-helpers.sh
#
# The CI workflow (.github/workflows/dashboard-helpers.yml) only calls this
# script; to pin more behaviour, add a case here. Assertions look at exit
# status, stdout/stderr, the files under the scratch dashboards/ root and the
# stub argv log (one `CTX=<docker-context> <tool> <argv>` record per call).

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
SKILL_DIR=$(cd "$SCRIPT_DIR/.." && pwd) || exit 1
HELPER="$SKILL_DIR/scripts/dashboard.sh"
STUB_BIN="$SCRIPT_DIR/stub/bin"
STUB_LIB=$(cd "$SKILL_DIR/../debug-agent/tests/stub/lib" && pwd) || exit 1
FLEET_SH=$(cd "$SKILL_DIR/../debug-agent/scripts" && pwd)/fleet.sh

SHA_OK=0123456789abcdef0123456789abcdef01234567
SHA_UNKNOWN=89abcdef0123456789abcdef0123456789abcdef
TOKEN=tok-SECRET-0f3c9a

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
DASH="$WORK/dashboards"
UPSTREAM="$WORK/upstream"
SCENE="$WORK/scene"
INSTANCES="$WORK/agent-instances"
ARGV_LOG="$WORK/argv.log"
ERROR_LOG="$WORK/stub-errors.log"
OUT="$WORK/out.txt"
ERR="$WORK/err.txt"
CODE=0
CASES=0

info() {
  printf 'dashboard-helpers: %s\n' "$*"
}

fail() {
  printf 'dashboard-helpers: FAIL: %s\n' "$*" >&2
  printf -- '--- stdout\n' >&2; cat "$OUT" >&2 2>/dev/null || true
  printf -- '--- stderr\n' >&2; cat "$ERR" >&2 2>/dev/null || true
  printf -- '--- argv log\n' >&2; cat "$ARGV_LOG" >&2 2>/dev/null || true
  exit 1
}

# --- fixtures --------------------------------------------------------------

# upstream_ref <ref> <example-tail>: three upstream files at one ref. The
# .env.example carries upstream's example allowed hosts, which init must
# never copy.
upstream_ref() {
  mkdir -p "$UPSTREAM/$1"
  printf 'name: fleet-dashboard\nservices:\n  dashboard:\n    build: .\n' >"$UPSTREAM/$1/docker-compose.yml"
  printf 'services:\n  dashboard:\n    environment:\n      AGENT_DASHBOARD_LAN_MODE: "on"\n' >"$UPSTREAM/$1/docker-compose.lan.yml"
  {
    printf 'DASHBOARD_BIND=127.0.0.1\nDASHBOARD_PORT=8000\nDOCKER_GID=999\n'
    printf 'AGENT_DASHBOARD_ALLOWED_HOSTS=raspberrypi,192.168.1.50\n'
    printf 'AGENT_DASHBOARD_CONTROL=\nAGENT_DASHBOARD_LAN_MODE=\nAGENT_DASHBOARD_TRUSTED_PROXIES=\n'
    printf '%s\n' "$2"
    printf '#COMPOSE_FILE=docker-compose.yml:docker-compose.lan.yml\n#PROXY_NETWORK=proxy\n#VIRTUAL_HOST=dashboard.example.lan\n#LETSENCRYPT_HOST=\n'
  } >"$UPSTREAM/$1/.env.example"
}

setup_fixtures() {
  upstream_ref v0.5.0 'AGENT_DASHBOARD_UNAUTHENTICATED_CONTROL='
  # v0.6.0 drops UNAUTHENTICATED_CONTROL and adds a new knob.
  upstream_ref v0.6.0 'AGENT_DASHBOARD_NEW_KNOB='
  upstream_ref "$SHA_OK" 'AGENT_DASHBOARD_UNAUTHENTICATED_CONTROL='
  printf '%s\trefs/heads/main\n%s\trefs/tags/v0.5.0\n%s\trefs/tags/v0.6.0\n' \
    "$SHA_OK" "$SHA_OK" "$SHA_UNKNOWN" >"$UPSTREAM/refs.txt"

  mkdir -p "$SCENE/networks" "$INSTANCES/agent-legacy" "$INSTANCES/agent-labelled"
  printf 'services:\n  agent: {}\n' >"$INSTANCES/agent-legacy/compose.yaml"
  printf 'services:\n  agent:\n    labels:\n      io.github.lbacik.agent-operator.contract: "1"\n' >"$INSTANCES/agent-labelled/compose.yaml"
  printf '991\n' >"$SCENE/gid"
  printf 'unix:///Users/op/.orbstack/run/docker.sock\n' >"$SCENE/context-orbstack"
  printf 'ssh://op@10.0.1.11\n' >"$SCENE/context-rpi5"
  printf 'ssh://op@pi.lan:2222\n' >"$SCENE/context-pi2222"
  printf 'tcp://10.0.1.20:2376\n' >"$SCENE/context-tcpbox"
  printf 'agent-legacy|agent-legacy-agent-1|Up 2 hours|\nagent-labelled|agent-labelled-agent-1|Up 1 hour|\n' >"$SCENE/ps-ALL.txt"
  printf 'fleet-dashboard-dashboard-1|running|healthy\n' >"$SCENE/compose-ps.txt"
  printf 'INFO: Started server process\nagent-dashboard: LAN mode is on: every request needs a sign-in session (bind 0.0.0.0:8000, Host check on, trusted proxies none)\n' >"$SCENE/compose-logs.txt"
  printf '28.3.0\n' >"$SCENE/docker-version.txt"
  printf 'NAME   ROLE        STATE\nalice  controller  active\n' >"$SCENE/account-list.txt"
}

# --- running and asserting -------------------------------------------------

run() {
  : >"$ARGV_LOG"
  : >"$ERROR_LOG"
  set +e
  PATH="$STUB_BIN:$PATH" \
    STUB_LIB="$STUB_LIB" STUB_ARGV_LOG="$ARGV_LOG" STUB_ERROR_LOG="$ERROR_LOG" \
    STUB_SCENE="$SCENE" STUB_UPSTREAM="$UPSTREAM" STUB_TOKEN="$TOKEN" \
    DASHBOARDS_DIR="$DASH" DASHBOARD_FLEET_SH="$FLEET_SH" AGENT_INSTANCES_DIR="$INSTANCES" \
    HOME="$WORK/home" DASHBOARD_REF=from-the-caller-env \
    "$HELPER" "$@" >"$OUT" 2>"$ERR"
  CODE=$?
  set -e
  [ ! -s "$ERROR_LOG" ] || fail "stub errors during $*: $(cat "$ERROR_LOG")"
}

case_name() {
  CASES=$((CASES + 1))
  info "case: $*"
}

want_code() {
  [ "$CODE" -eq "$1" ] || fail "exit $CODE, want $1"
}

has() {
  grep -qF -- "$2" "$1" || fail "$(basename "$1") lacks: $2"
}

lacks() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then fail "$(basename "$1") holds: $2"; fi
}

has_line() {
  grep -qxF -- "$2" "$1" || fail "$(basename "$1") lacks the line: $2"
}

argv_has() {
  has "$ARGV_LOG" "$1"
}

argv_lacks() {
  lacks "$ARGV_LOG" "$1"
}

env_of() {
  printf '%s' "$DASH/$1/.env"
}

no_deployment() {
  [ ! -e "$DASH/$1" ] || fail "init wrote $DASH/$1 although it was refused"
}

reset_dash() {
  rm -rf "$DASH"
}

# assert_common_env <ctx>: keys every profile writes the same way.
assert_common_env() {
  _e=$(env_of "$1")
  has_line "$_e" "DOCKER_GID=991"
  has_line "$_e" "AGENT_DASHBOARD_UNAUTHENTICATED_CONTROL=off"
  lacks "$_e" "raspberrypi"
  lacks "$_e" "192.168.1.50"
  grep -q '^COMPOSE_FILE=docker-compose.yml:docker-compose.forge.yml' "$_e" || fail "COMPOSE_FILE lacks the forge overlay"
  for f in docker-compose.yml docker-compose.lan.yml .env.example docker-compose.forge.yml .upstream-ref; do
    [ -f "$DASH/$1/$f" ] || fail "$f missing in $DASH/$1"
  done
  has "$DASH/$1/docker-compose.forge.yml" 'https://github.com/lbacik/agent-dashboard.git#${DASHBOARD_REF:?'
}

# --- shell sources ---------------------------------------------------------

check_shell_sources() {
  info "parsing and shellchecking the helper, this suite and the stub fakes"
  for f in "$HELPER" "$0" "$STUB_BIN"/*; do
    sh -n "$f" || fail "does not parse: $f"
  done
  command -v shellcheck >/dev/null 2>&1 || fail "shellcheck not found on PATH"
  shellcheck -x -P SCRIPTDIR -S warning "$HELPER" "$0" "$STUB_BIN"/* || fail "shellcheck rejects a script"
}

# --- cases -----------------------------------------------------------------

cases_usage() {
  case_name "usage errors exit 2"
  run; want_code 2
  run init --profile local; want_code 2; has "$ERR" "init needs --ref"
  run init --ref v0.5.0 --profile nope; want_code 2
  run --context rpi5 init --ref v0.5.0 --profile readonly --host pi; want_code 2; has "$ERR" "needs --bind"
  run --context rpi5 init --ref v0.5.0 --profile readonly --bind 192.168.1.50; want_code 2; has "$ERR" "needs --host"
  run --context rpi5 init --ref v0.5.0 --profile lan --virtual-host d.lan; want_code 2; has "$ERR" "needs --proxy-network"
  run init --ref v0.5.0 --bind 192.168.1.50; want_code 2; has "$ERR" "readonly options"
  run --context ../x init --ref v0.5.0; want_code 2
  no_deployment orbstack
  no_deployment rpi5
}

cases_ref() {
  case_name "init rejects a branch and writes nothing"
  run init --ref main; want_code 1; has "$ERR" "is a branch"; no_deployment orbstack
  argv_lacks "curl"; argv_lacks " docker "

  case_name "init rejects a short SHA and writes nothing"
  run init --ref 0123456; want_code 1; has "$ERR" "short commit SHA"; no_deployment orbstack
  argv_lacks "curl"; argv_lacks " docker "

  case_name "init rejects a tag that does not exist upstream"
  run init --ref v9.9.9; want_code 1; has "$ERR" "is not a tag"; no_deployment orbstack
  argv_lacks "curl"; argv_lacks " docker "

  case_name "init rejects a full SHA that does not exist upstream"
  run init --ref "$SHA_UNKNOWN"; want_code 1; has "$ERR" "does not exist upstream"; no_deployment orbstack
  argv_lacks "curl -fsSL"; argv_lacks " docker "
}

cases_init() {
  case_name "init local (default on orbstack) with a tag"
  run init --ref v0.5.0; want_code 0
  e=$(env_of orbstack)
  assert_common_env orbstack
  has_line "$DASH/orbstack/.upstream-ref" "v0.5.0"
  has_line "$e" "DASHBOARD_REF=v0.5.0"
  has_line "$e" "COMPOSE_FILE=docker-compose.yml:docker-compose.forge.yml"
  has_line "$e" "FORGE_PROFILE=local"
  has_line "$e" "AGENT_DASHBOARD_LAN_MODE=on"
  has_line "$e" "DASHBOARD_BIND=127.0.0.1"
  has_line "$e" "DASHBOARD_PORT=8000"
  has_line "$e" "AGENT_DASHBOARD_ALLOWED_HOSTS=localhost"
  argv_has "CTX=orbstack docker run --rm -v /var/run/docker.sock:/var/run/docker.sock alpine:3 stat -c %g /var/run/docker.sock"
  argv_has "CTX=orbstack git ls-remote https://github.com/lbacik/agent-dashboard.git refs/tags/v0.5.0 refs/heads/v0.5.0"
  argv_has "raw.githubusercontent.com/lbacik/agent-dashboard/v0.5.0/.env.example"

  case_name "init refuses an existing .env without --force"
  printf 'MARK=1\n' >>"$e"
  before=$(cat "$e")
  run init --ref v0.6.0; want_code 1; has "$ERR" "pass --force"
  [ "$(cat "$e")" = "$before" ] || fail ".env changed without --force"
  has_line "$DASH/orbstack/.upstream-ref" "v0.5.0"
  argv_lacks "curl"

  case_name "init --force overwrites"
  run init --ref v0.5.0 --port 8100 --force; want_code 0
  lacks "$e" "MARK=1"
  has_line "$e" "DASHBOARD_PORT=8100"

  case_name "init tunnel (default off orbstack) with a full SHA, through --context"
  run --context rpi5 init --ref "$SHA_OK" --local-port 18000; want_code 0
  e=$(env_of rpi5)
  assert_common_env rpi5
  has_line "$DASH/rpi5/.upstream-ref" "$SHA_OK"
  has_line "$e" "DASHBOARD_REF=$SHA_OK"
  has_line "$e" "FORGE_PROFILE=tunnel"
  has_line "$e" "AGENT_DASHBOARD_LAN_MODE=on"
  has_line "$e" "DASHBOARD_BIND=127.0.0.1"
  has_line "$e" "FORGE_TUNNEL_LOCAL_PORT=18000"
  argv_has "CTX=rpi5 docker run --rm -v /var/run/docker.sock:/var/run/docker.sock alpine:3 stat -c %g /var/run/docker.sock"
  argv_has "curl -fsSI -o /dev/null https://raw.githubusercontent.com/lbacik/agent-dashboard/$SHA_OK/docker-compose.yml"
  argv_lacks "git ls-remote"

  case_name "init lan with a missing proxy network writes nothing"
  run --context lanbox init --ref v0.5.0 --profile lan --proxy-network proxy --virtual-host dash.example.lan
  want_code 1; has "$ERR" "proxy network 'proxy' does not exist"; no_deployment lanbox
  argv_lacks "curl"; argv_lacks "stat -c"

  case_name "init lan derives the trusted proxies from the network subnet"
  printf '172.30.0.0/16,\n' >"$SCENE/networks/proxy"
  run --context lanbox init --ref v0.5.0 --profile lan --proxy-network proxy --virtual-host dash.example.lan --letsencrypt-host dash.example.lan
  want_code 0
  e=$(env_of lanbox)
  assert_common_env lanbox
  has_line "$e" "COMPOSE_FILE=docker-compose.yml:docker-compose.forge.yml:docker-compose.lan.yml"
  has_line "$e" "FORGE_PROFILE=lan"
  has_line "$e" "PROXY_NETWORK=proxy"
  has_line "$e" "VIRTUAL_HOST=dash.example.lan"
  has_line "$e" "LETSENCRYPT_HOST=dash.example.lan"
  has_line "$e" "AGENT_DASHBOARD_ALLOWED_HOSTS=dash.example.lan"
  has_line "$e" "AGENT_DASHBOARD_TRUSTED_PROXIES=172.30.0.0/16"
  has_line "$e" "AGENT_DASHBOARD_LAN_MODE=on"
  argv_has "CTX=lanbox docker network inspect proxy"

  case_name "init readonly binds the LAN address, Control off, warns"
  run --context ro init --ref v0.5.0 --profile readonly --bind 192.168.1.60 --host pi,192.168.1.60
  want_code 0
  e=$(env_of ro)
  has_line "$e" "FORGE_PROFILE=readonly"
  has_line "$e" "DASHBOARD_BIND=192.168.1.60"
  has_line "$e" "AGENT_DASHBOARD_ALLOWED_HOSTS=pi,192.168.1.60"
  has_line "$e" "AGENT_DASHBOARD_LAN_MODE=off"
  has_line "$e" "AGENT_DASHBOARD_CONTROL=off"
  has_line "$e" "AGENT_DASHBOARD_UNAUTHENTICATED_CONTROL=off"
  has_line "$e" "COMPOSE_FILE=docker-compose.yml:docker-compose.forge.yml"
  lacks "$e" "raspberrypi"
  has "$ERR" "anyone who can reach http://192.168.1.60:8000"
}

cases_up() {
  case_name "up runs config -q, then up -d --build --wait, through the context"
  run --context rpi5 up; want_code 0
  argv_has "CTX=rpi5 docker compose config -q"
  argv_has "CTX=rpi5 docker compose up -d --build --wait"
  [ "$(grep -n 'config -q' "$ARGV_LOG" | cut -d: -f1)" -lt "$(grep -n 'up -d' "$ARGV_LOG" | cut -d: -f1)" ] \
    || fail "config -q must run before up"
  has "$OUT" "dashboard.sh --context rpi5 tunnel"

  case_name "up refuses a ref mismatch"
  e=$(env_of rpi5)
  sed "s/^DASHBOARD_REF=.*/DASHBOARD_REF=v0.6.0/" "$e" >"$e.new" && mv "$e.new" "$e"
  run --context rpi5 up; want_code 1; has "$ERR" "ref mismatch"
  argv_lacks "compose"
  sed "s/^DASHBOARD_REF=.*/DASHBOARD_REF=$SHA_OK/" "$e" >"$e.new" && mv "$e.new" "$e"

  case_name "up on lan re-checks the proxy network"
  rm -f "$SCENE/networks/proxy"
  run --context lanbox up; want_code 1; has "$ERR" "proxy network 'proxy' does not exist"
  argv_lacks "compose up"
  printf '172.30.0.0/16,\n' >"$SCENE/networks/proxy"
  run --context lanbox up; want_code 0
  argv_has "CTX=lanbox docker compose up -d --build --wait"

  case_name "up without a deployment"
  run --context nowhere up; want_code 1; has "$ERR" "run init first"
}

cases_upgrade() {
  case_name "upgrade rejects a branch and changes nothing"
  e=$(env_of orbstack)
  before=$(cat "$e")
  run upgrade --ref main; want_code 1; has "$ERR" "is a branch"
  [ "$(cat "$e")" = "$before" ] || fail ".env changed on a rejected upgrade"
  has_line "$DASH/orbstack/.upstream-ref" "v0.5.0"

  case_name "upgrade needs --ref"
  run upgrade; want_code 2

  case_name "upgrade re-fetches at the new ref, keeps .env, reports variables"
  printf 'AGENT_DASHBOARD_POLL_INTERVAL=7\n' >>"$e"
  grep -v '^DASHBOARD_REF=' "$e" >"$WORK/env-before"
  run upgrade --ref v0.6.0; want_code 0
  grep -v '^DASHBOARD_REF=' "$e" >"$WORK/env-after"
  diff -u "$WORK/env-before" "$WORK/env-after" || fail "upgrade changed .env beyond DASHBOARD_REF"
  has_line "$e" "DASHBOARD_REF=v0.6.0"
  has_line "$DASH/orbstack/.upstream-ref" "v0.6.0"
  has "$DASH/orbstack/.env.example" "AGENT_DASHBOARD_NEW_KNOB="
  argv_has "raw.githubusercontent.com/lbacik/agent-dashboard/v0.6.0/docker-compose.yml"
  argv_has "raw.githubusercontent.com/lbacik/agent-dashboard/v0.6.0/docker-compose.lan.yml"
  has "$OUT" "AGENT_DASHBOARD_NEW_KNOB[new upstream]"
  grep -q '^  removed .*AGENT_DASHBOARD_POLL_INTERVAL' "$OUT" || fail "upgrade did not report the removed variable"
  grep -q '^  removed .*AGENT_DASHBOARD_UNAUTHENTICATED_CONTROL' "$OUT" || fail "upgrade did not report UNAUTHENTICATED_CONTROL as removed"
  grep '^  removed' "$OUT" | grep -q 'DASHBOARD_REF\|FORGE_' && fail "upgrade reported a forge-only key"
  argv_has "CTX=orbstack docker compose config -q"
  argv_has "CTX=orbstack docker compose up -d --build --wait"
  argv_lacks " -v"
  argv_lacks "volume"
}

cases_down() {
  case_name "down never removes volumes"
  run down; want_code 0
  argv_has "CTX=orbstack docker compose down"
  argv_lacks " -v"
  argv_lacks "volume"
  run down -v; want_code 2
  argv_lacks "compose"
}

cases_account() {
  case_name "account add passes the local base address and shows the link"
  run account add alice --role controller; want_code 0
  argv_has "CTX=orbstack docker compose exec -T dashboard agent-dashboard account add alice --role controller --url http://localhost:8100"
  has "$OUT" "http://localhost:8100/set-password?token=$TOKEN"
  if grep -rqF "$TOKEN" "$DASH" "$ARGV_LOG"; then fail "the Set-password link was written to a file"; fi

  case_name "account reset on tunnel uses the stored local tunnel port"
  run --context rpi5 account reset alice; want_code 0
  argv_has "CTX=rpi5 docker compose exec -T dashboard agent-dashboard account reset alice --url http://localhost:18000"

  case_name "account add on lan uses https://VIRTUAL_HOST"
  run --context lanbox account add bob; want_code 0
  argv_has "account add bob --url https://dash.example.lan"

  case_name "account list passes no --url"
  run account list; want_code 0
  argv_has "agent-dashboard account list"
  argv_lacks "--url"

  case_name "account refusals"
  run --context ro account add carol; want_code 1; has "$ERR" "no sign-in"; argv_lacks "compose"
  run account add dave --url http://evil; want_code 2; argv_lacks "compose"
  run account frobnicate; want_code 2
}

cases_tunnel() {
  case_name "tunnel derives the host from an ssh:// endpoint"
  run --context rpi5 tunnel; want_code 0
  has_line "$OUT" "ssh -L 18000:127.0.0.1:8000 op@10.0.1.11"
  argv_has "CTX=rpi5 docker context inspect rpi5"

  case_name "tunnel keeps an ssh port and warns about another local port"
  mkdir -p "$DASH/pi2222" && cp "$DASH/rpi5/.env" "$DASH/rpi5/.upstream-ref" "$DASH/pi2222/"
  run --context pi2222 tunnel --local-port 19000; want_code 0
  has_line "$OUT" "ssh -p 2222 -L 19000:127.0.0.1:8000 op@pi.lan"
  has "$ERR" "local port 18000"

  case_name "tunnel reports a non-SSH endpoint and asks for the host"
  mkdir -p "$DASH/tcpbox" && cp "$DASH/rpi5/.env" "$DASH/rpi5/.upstream-ref" "$DASH/tcpbox/"
  run --context tcpbox tunnel; want_code 1
  has "$ERR" "non-SSH endpoint (tcp://10.0.1.20:2376)"
  has "$ERR" "--ssh-host"
  run --context tcpbox tunnel --ssh-host op@box.lan; want_code 0
  has_line "$OUT" "ssh -L 18000:127.0.0.1:8000 op@box.lan"

  case_name "tunnel on the local profile needs no tunnel"
  run tunnel; want_code 0
  has "$OUT" "needs no tunnel: open http://localhost:8100"
}

cases_status() {
  case_name "status: healthy dashboard, legacy containers listed"
  run status; want_code 0
  has "$OUT" "container: fleet-dashboard-dashboard-1 running (health healthy)"
  has "$OUT" "LAN mode is on"
  has "$OUT" "docker socket: ok (server 28.3.0)"
  has "$OUT" "alice  controller  active"
  has "$OUT" "legacy containers (not shown by the dashboard):"
  has "$OUT" "agent-legacy: agent-legacy-agent-1 [Up 2 hours]"
  lacks "$OUT" "agent-labelled-agent-1"
  argv_has "CTX=orbstack docker compose exec -T dashboard docker version"
  argv_has "CTX=orbstack docker compose exec -T dashboard agent-dashboard account list"

  case_name "status flags a socket permission error as a likely wrong DOCKER_GID"
  printf 'permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock\n' >"$SCENE/docker-version.txt"
  printf '1\n' >"$SCENE/docker-version.code"
  run --context rpi5 status; want_code 1
  has "$OUT" "docker socket: permission denied: DOCKER_GID=991 in .env is likely wrong for context rpi5"
  has "$OUT" "agent-legacy: agent-legacy-agent-1"
  printf '28.3.0\n' >"$SCENE/docker-version.txt"
  rm -f "$SCENE/docker-version.code"

  case_name "status on a stopped container skips the in-container checks"
  printf 'fleet-dashboard-dashboard-1|exited|\n' >"$SCENE/compose-ps.txt"
  run status; want_code 1
  has "$OUT" "exited (health none)"
  has "$OUT" "skipped (container not running)"
  argv_lacks "compose exec"
}

check_shell_sources
setup_fixtures
cases_usage
cases_ref
cases_init
cases_up
cases_upgrade
cases_down
cases_account
cases_tunnel
cases_status
info "all $CASES cases passed"
