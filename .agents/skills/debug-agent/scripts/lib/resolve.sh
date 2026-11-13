# Shared resolution for locate-agent.sh and fetch-run.sh. Source it, don't run it.
#
# Input:  $fragment (agent name fragment), $context (docker context, may be empty),
#         $worker (--worker value <n|worker-id>, may be empty for the first Worker)
# Output: root dir project short service worker_num worker_id volume
#         context mode container container_state image
#         host_data (local mode) / cache_data (remote mode)
#
# Worker layout (one Compose project per Instance): for an unlabelled Instance
# the first Worker is service `agent` with volume `agent_data` and further
# Workers are `agent-<n>` with volumes `data_<n>`. For a labelled Instance the
# Compose service of each Managed Instance is resolved from the Instance's
# `instance` discovery labels instead (see lib/contract.sh): a
# simple-coding-agent Instance resolves exactly as above, while a coding-agent
# Managed Instance resolves to service `worker`. A worker-id is
# `<short-name>-<n>` where short-name is the instance directory without the
# `agent-` prefix. The first Worker is the default, so an Instance with one
# Worker resolves exactly as before.
#
# Callers source lib/contract.sh before this file so the label helpers are
# available; without them this file keeps the legacy service mapping.
# contract_compose (0/1) is the shared path predicate the helpers use: an
# Instance whose compose.yaml carries the contract label takes the contract
# path even when no container exists yet. Volume and host/cache paths below
# are legacy-only and are never printed or used on the contract path.
#
# Resolution is anchored on the agent-instances/agent-*/ directories on disk, never on
# `docker volume ls`, because stale volumes from old project names exist
# (e.g. jsonhub-api_agent_data) and would match a naive substring search.

# Find the instances root: agent-instances/ in the agent-forge project. It is
# located from this script's path (<project>/.agents|.claude/skills/debug-agent/
# scripts/), not from the working directory, so the helpers work from anywhere.
# AGENT_INSTANCES_DIR overrides it.
root=${AGENT_INSTANCES_DIR:-$(cd "$(dirname "$0")/../../../.." && pwd)/agent-instances}
if ! ls -d "$root"/agent-*/ >/dev/null 2>&1; then
  echo "error: no agent-*/ directories under $root" >&2
  exit 2
fi

# Exact directory name first (with or without the agent- prefix), then substring.
matches=""
for d in "$root"/agent-*/; do
  name=$(basename "$d")
  if [ "$name" = "$fragment" ] || [ "$name" = "agent-$fragment" ]; then
    matches=$name
    break
  fi
done
if [ -z "$matches" ]; then
  for d in "$root"/agent-*/; do
    name=$(basename "$d")
    case "$name" in *"$fragment"*) matches="$matches $name" ;; esac
  done
fi

set -- $matches
if [ $# -eq 0 ]; then
  echo "error: no agent directory matches '$fragment'. Available:" >&2
  for d in "$root"/agent-*/; do echo "  $(basename "$d")" >&2; done
  exit 3
fi
if [ $# -gt 1 ]; then
  echo "error: '$fragment' is ambiguous, matches:" >&2
  for m in "$@"; do echo "  $m" >&2; done
  exit 4
fi

dir=$1
# No compose.yaml sets `name:` and no .env sets COMPOSE_PROJECT_NAME, so the
# compose project name is the directory name. Honour an override if one appears.
project=$dir
override=$(grep -h '^COMPOSE_PROJECT_NAME=' "$root/$dir/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)
[ -n "$override" ] && project=$override

# Short name: directory without the agent- prefix (e.g. agent-foo -> foo).
# It is what worker ids are built from: <short-name>-<n>.
short=${dir#agent-}
[ -z "$short" ] && short=$dir

# Resolve --worker <n|worker-id> to a worker number. Default is the first Worker.
worker_arg=${worker:-}
worker_num=1
if [ -n "$worker_arg" ]; then
  case "$worker_arg" in
    agent) worker_num=1 ;;
    agent-[0-9]*)
      num=${worker_arg#agent-}
      case "$num" in ''|*[!0-9]*)
        echo "error: invalid --worker '$worker_arg': expected <n> or $short-<n> (e.g. 2 or $short-2)" >&2
        exit 1
        ;;
      esac
      while case "$num" in 0?*) true ;; *) false ;; esac; do num=${num#0}; done
      [ -z "$num" ] && num=0
      worker_num=$num
      ;;
    *[!0-9]*)
      num=${worker_arg##*-}
      prefix=${worker_arg%-*}
      case "$num" in ''|*[!0-9]*)
        echo "error: invalid --worker '$worker_arg': expected <n> or $short-<n> (e.g. 2 or $short-2)" >&2
        exit 1
        ;;
      esac
      if [ "$prefix" != "$short" ] && [ "$prefix" != "$dir" ]; then
        echo "error: invalid --worker '$worker_arg': expected <n> or $short-<n> (e.g. 2 or $short-2)" >&2
        exit 1
      fi
      while case "$num" in 0?*) true ;; *) false ;; esac; do num=${num#0}; done
      [ -z "$num" ] && num=0
      worker_num=$num
      ;;
    *)
      num=$worker_arg
      while case "$num" in 0?*) true ;; *) false ;; esac; do num=${num#0}; done
      [ -z "$num" ] && num=0
      worker_num=$num
      ;;
  esac
  case "$worker_num" in ''|*[!0-9]*|0)
    echo "error: invalid --worker '$worker_arg': worker number must be >= 1" >&2
    exit 1
    ;;
  esac
fi

if [ "$worker_num" -eq 1 ]; then
  service=agent
  volume="${project}_agent_data"
  worker_id=""
else
  service="agent-$worker_num"
  volume="${project}_data_$worker_num"
  worker_id="$short-$worker_num"
fi

# Labelled Instances resolve the Compose service from the `instance`
# discovery labels: the service name is the one carrying this Worker's
# Managed Instance name (coding-agent resolves to `worker`),
# simple-coding-agent to `agent` / `agent-<n>` exactly as above.
contract_compose=0
if command -v compose_has_contract_label >/dev/null 2>&1 \
  && compose_has_contract_label "$root/$dir/compose.yaml"; then
  contract_compose=1
  if _svc=$(contract_service_for_worker "$root/$dir/compose.yaml" \
    "$short" "$worker_num" "${worker_id:-}" 2>/dev/null); then
    [ -n "$_svc" ] && service=$_svc
  fi
fi

# Local mode = OrbStack, whose volumes are readable on the host. Any other
# context is remote: /data is reachable only through the Docker API.
context=${context:-orbstack}
export DOCKER_CONTEXT=$context
if [ "$context" = orbstack ]; then
  mode=local
  host_data="$HOME/OrbStack/docker/volumes/$volume"
else
  mode=remote
  base_cache=${AGENT_LOG_CACHE:-$HOME/.cache/simple-coding-agent-env}
  if [ "$worker_num" -eq 1 ]; then
    cache_data="$base_cache/$context/$project"
  else
    cache_data="$base_cache/$context/$project/$worker_id"
  fi
fi

container=$(docker ps -a --filter "label=com.docker.compose.project=$project" \
  --filter "label=com.docker.compose.service=$service" --format '{{.Names}}' 2>/dev/null | head -1 || true)
container_state=unknown
image=""
if [ -n "$container" ]; then
  info=$(docker inspect -f '{{.State.Status}}|{{.State.ExitCode}}|{{.State.StartedAt}}|{{.Config.Image}}' "$container" 2>/dev/null || true)
  status=$(echo "$info" | cut -d'|' -f1)
  container_state="$status (exit $(echo "$info" | cut -d'|' -f2), started $(echo "$info" | cut -d'|' -f3))"
  image=$(echo "$info" | cut -d'|' -f4)
fi

# Run a POSIX sh script against /data in ONE docker call, never one per file:
# every call is an SSH round trip on a remote context. A running container is
# used via exec; otherwise a throwaway container from the agent's own image
# (already on the host, has jq) mounts the volume read-only.
data_sh() {
  if [ "${status:-}" = running ]; then
    docker exec -u agent -w /data "$container" sh -c "$1"
  elif [ -n "$image" ]; then
    docker run --rm --entrypoint sh -u agent -w /data -v "$volume:/data:ro" "$image" -c "$1"
  else
    echo "error: no container for project $project service $service on context $context, cannot read $volume" >&2
    return 5
  fi
}
