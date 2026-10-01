# Shared resolution for locate-agent.sh and fetch-run.sh. Source it, don't run it.
#
# Input:  $fragment (agent name fragment), $context (docker context, may be empty)
# Output: root dir project volume context mode container container_state image
#         host_data (local mode) / cache_data (remote mode)
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
volume="${project}_agent_data"

# Local mode = OrbStack, whose volumes are readable on the host. Any other
# context is remote: /data is reachable only through the Docker API.
context=${context:-orbstack}
export DOCKER_CONTEXT=$context
if [ "$context" = orbstack ]; then
  mode=local
  host_data="$HOME/OrbStack/docker/volumes/$volume"
else
  mode=remote
  cache_data="${AGENT_LOG_CACHE:-$HOME/.cache/simple-coding-agent-env}/$context/$project"
fi

container=$(docker ps -a --filter "label=com.docker.compose.project=$project" \
  --filter "label=com.docker.compose.service=agent" --format '{{.Names}}' 2>/dev/null | head -1 || true)
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
    echo "error: no container for project $project on context $context, cannot read $volume" >&2
    return 5
  fi
}
