#!/bin/sh
# Pool status: which Worker of one Instance works on what. Read-only.
#
# Usage: pool-status.sh [--context <docker-context>] [--github] <name-fragment>
#   --context  docker context the instance runs on (default: orbstack, local)
#   --github   compare live attempts with claimed-by:<worker-id> labels and
#              assignees in TARGET_REPO (needs gh; without it no GitHub call
#              is made)
#
# One block per Worker: container state, intake state, active issue and
# pending_next_issue. The source of truth is `agentctl status` via one
# `docker exec` per running Worker (one SSH round trip each on a remote
# context); container states come from a single shared `docker ps`. Instance
# identity (dir, project, worker ids) comes from lib/resolve.sh, and the
# Worker list from the compose services on disk, so enumeration itself costs
# no docker call. A stopped container is reported, never an error that aborts
# the rest. Works for a single-Worker Instance too.
#
# With --github, TARGET_REPO is read from the Instance .env (that one line
# only; tokens are never read or printed) and open issues are compared with
# the live attempts:
#   - "orphaned claim": a claimed-by:<id> label whose Worker has no active
#     attempt on that issue, or names no Worker of this Instance (stale
#     labels are removed by hand; there is no automatic cleanup);
#   - "claim without label": a Worker with an active attempt whose issue
#     lacks its claimed-by:<worker-id> label. While WORKER_ID is unset the
#     agent writes no labels, so that is reported as expected, not flagged.
#
# Exit codes: 0 even with stopped workers; 1 on usage, missing docker/gh,
# unreadable TARGET_REPO or a failed GitHub query; 2/3/4 from lib/resolve.sh.

set -eu

usage="usage: pool-status.sh [--context <ctx>] [--github] <name-fragment>"

context=""
worker=""
github=""
fragment=""
while [ $# -gt 0 ]; do
  case "$1" in
    --context)
      context=${2:?$usage}
      shift 2
      ;;
    --github)
      github=1
      shift
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
      if [ -n "$fragment" ]; then
        echo "$usage" >&2
        exit 1
      fi
      fragment=$1
      shift
      ;;
  esac
done
[ -n "$fragment" ] || { echo "$usage" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || { echo "error: docker not found on PATH" >&2; exit 1; }

. "$(dirname "$0")/lib/resolve.sh"
# From resolve.sh: root dir project short context mode (DOCKER_CONTEXT is
# exported there). $container/$volume describe the default (first) Worker
# only; every Worker is enumerated below.

# Worker list from the compose services on disk (same parsing as
# locate-agent.sh), so enumeration costs no docker call and no SSH round trip.
compose_file="$root/$dir/compose.yaml"
worker_list=""
if [ -f "$compose_file" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "  agent:"*)
        worker_list="$worker_list 1"
        ;;
      "  agent-"*)
        rest=${line#"  agent-"}
        n=${rest%%[!0-9]*}
        case "$n" in ''|*[!0-9]*) continue ;; esac
        case "$rest" in "$n:"*) worker_list="$worker_list $n" ;; *) continue ;; esac
        ;;
    esac
  done < "$compose_file"
fi
[ -n "$worker_list" ] || worker_list=" 1"
# shellcheck disable=SC2086
worker_list=$(echo $worker_list | tr ' ' '\n' | sort -n -u | tr '\n' ' ')

# One shared `docker ps` for every Worker's container state.
ps_out=$(docker ps -a --filter "label=com.docker.compose.project=$project" \
  --format '{{.Label "com.docker.compose.service"}}|{{.Names}}|{{.State}}|{{.Status}}' 2>/dev/null || true)

echo "instance:        $dir (project $project) on context $context ($mode)"

# Per-Worker records for the --github pass: "n|WORKER_ID|active-or--" words
# (WORKER_ID matches [a-z0-9-], so no word ever contains whitespace).
records=""

# shellcheck disable=SC2086
for n in $worker_list; do
  if [ "$n" -eq 1 ]; then
    svc=agent
  else
    svc="agent-$n"
  fi
  line=$(printf '%s\n' "$ps_out" | grep "^$svc|" | head -n 1 || true)
  if [ -z "$line" ]; then
    cont="${project}-${svc}-1 (not created)"
    cstate="not created"
    running=0
  else
    cont=$(echo "$line" | cut -d'|' -f2)
    cstate=$(echo "$line" | cut -d'|' -f4-)
    [ -n "$cstate" ] || cstate=$(echo "$line" | cut -d'|' -f3)
    if [ "$(echo "$line" | cut -d'|' -f3)" = running ]; then
      running=1
    else
      running=0
    fi
  fi

  wid=""
  intake=""
  active="unavailable (container not running)"
  pending="unavailable (container not running)"
  status_err=""
  if [ "$running" -eq 1 ]; then
    # One docker call per running Worker: the live status plus the WORKER_ID
    # the claim labels are built from. A failure is reported inline and the
    # rest of the pool is still listed.
    status_out=$(docker exec -u agent "$cont" sh -c 'echo "WORKER_ID=$WORKER_ID"; agentctl status' 2>&1 || true)
    if echo "$status_out" | grep -q '^intake: '; then
      wid=$(echo "$status_out" | sed -n 's/^WORKER_ID=//p' | head -n 1 | tr -d '\r' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      intake=$(echo "$status_out" | sed -n 's/^intake: //p' | head -n 1 | tr -d '\r')
      active=$(echo "$status_out" | sed -n 's/^active_attempt: //p' | head -n 1 | tr -d '\r')
      pending=$(echo "$status_out" | sed -n 's/^pending_next_issue: //p' | head -n 1 | tr -d '\r')
    else
      status_err=$(echo "$status_out" | head -n 3 || true)
    fi
  fi
  active_issue=$(echo "$active" | sed -n 's/^issue #\([0-9][0-9]*\).*/\1/p' || true)

  if [ -n "$wid" ]; then
    disp="worker $n ($wid)"
  elif [ "$n" -eq 1 ]; then
    disp="worker 1 (first Worker)"
  else
    disp="worker $n ($short-$n)"
  fi
  echo "$disp service=$svc:"
  echo "  container:           $cont [$cstate]"
  if [ -n "$status_err" ]; then
    echo "  error:               agentctl status failed:"
    echo "$status_err" | sed 's/^/    /'
  elif [ "$running" -eq 1 ]; then
    echo "  intake:              $intake"
    echo "  active_attempt:      $active"
    echo "  pending_next_issue:  $pending"
  else
    echo "  status:              $active"
  fi

  if [ -z "$active_issue" ]; then
    active_issue="-"
  fi
  records="$records $n|$wid|$active_issue"
done

if [ -z "$github" ]; then
  exit 0
fi

# --- GitHub comparison (read-only: one issue list, no state changes) ---
command -v gh >/dev/null 2>&1 || { echo "error: --github needs gh (not found on PATH)" >&2; exit 1; }
env_file="$root/$dir/.env"
# Only the TARGET_REPO line is ever read; tokens stay out of scope and output.
repo=$(grep -h '^TARGET_REPO=' "$env_file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)
repo=$(printf '%s' "$repo" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//')
case "$repo" in
  */*) ;;
  *) echo "error: cannot read TARGET_REPO=owner/repo from $env_file" >&2; exit 1 ;;
esac

# shellcheck disable=SC2016 # $n is a jq variable for gh's --jq, not shell
gh_out=$(gh issue list --repo "$repo" --state open --limit 200 \
  --json number,labels,assignees \
  --jq '.[] | .number as $n | "\($n) issue", ((.labels // [])[].name | select(startswith("claimed-by:")) | "\($n) label \(.)"), ((.assignees // [])[].login | "\($n) assignee \(.)")' 2>&1) \
  || { printf '%s\n' "$gh_out" >&2; exit 1; }
open_count=$(printf '%s\n' "$gh_out" | grep -c ' issue$' || true)

echo "github: $repo ($open_count open issues read)"
problems=0

# Orphaned claims: every claimed-by label whose Worker has no active attempt
# on that issue, or names no Worker of this Instance. A label is owned only
# when some Worker carrying that id (its WORKER_ID, or the conventional
# <short>-<n> when WORKER_ID is unset) has its active attempt on that issue.
claim_lines=$(printf '%s\n' "$gh_out" | grep ' label ' || true)
orphan_report=""
if [ -n "$claim_lines" ]; then
  orphan_report=$(echo "$claim_lines" | while IFS= read -r l || [ -n "$l" ]; do
    [ -n "$l" ] || continue
    num=${l%% *}
    id=${l#*label claimed-by:}
    owner=""
    owner_active="-"
    # shellcheck disable=SC2086
    for r in $records; do
      rn=${r%%|*}; rest=${r#*|}
      rwid=${rest%%|*}; ractive=${rest#*|}
      rid=$rwid
      if [ -z "$rid" ] && [ "$rn" != 1 ]; then
        rid="$short-$rn"
      fi
      if [ -n "$rid" ] && [ "$rid" = "$id" ]; then
        owner=$rn
        owner_active=$ractive
        if [ "$ractive" = "$num" ]; then
          owner="ok-$rn"
          break
        fi
      fi
    done
    case "$owner" in
      ok-*) ;;
      "")
        echo "  orphaned claim: #$num labeled claimed-by:$id, but no such Worker in this Instance (remove the label by hand)"
        ;;
      *)
        if [ "$owner_active" = "-" ]; then
          where="idle (no active attempt)"
        else
          where="active on #$owner_active"
        fi
        echo "  orphaned claim: #$num labeled claimed-by:$id, but worker $owner ($id) has no active attempt on #$num [$where] (stale label; remove it by hand)"
        ;;
    esac
  done)
fi
[ -n "$orphan_report" ] && printf '%s\n' "$orphan_report"

# Claims without labels, and the GitHub context of every live attempt.
# shellcheck disable=SC2086
for r in $records; do
  rn=${r%%|*}; rest=${r#*|}
  rwid=${rest%%|*}; ractive=${rest#*|}
  [ "$ractive" != "-" ] || continue
  if [ -n "$rwid" ]; then
    wname="$rwid"
    want="$rwid"
    wset=1
  elif [ "$rn" -eq 1 ]; then
    wname="worker 1"
    want=""
    wset=0
  else
    wname="$short-$rn"
    want="$short-$rn"
    wset=0
  fi
  issue_labels=$(printf '%s\n' "$gh_out" | sed -n "s/^$ractive label //p" | tr '\n' ' ' || true)
  issue_assignees=$(printf '%s\n' "$gh_out" | sed -n "s/^$ractive assignee //p" | tr '\n' ' ' || true)
  [ -n "$issue_labels" ] || issue_labels="(none)"
  [ -n "$issue_assignees" ] || issue_assignees="(none)"
  echo "  #$ractive: labels [$issue_labels] assignees [$issue_assignees] -- active attempt of $wname (worker $rn)"
  if [ "$wset" -eq 1 ]; then
    if printf '%s\n' "$gh_out" | grep -q "^$ractive label claimed-by:$rwid\$"; then
      :
    else
      echo "  claim without label: $wname (worker $rn) is active on #$ractive but #$ractive lacks the claimed-by:$rwid label"
      problems=$((problems + 1))
    fi
  elif [ -n "$want" ] && printf '%s\n' "$gh_out" | grep -q "^$ractive label claimed-by:$want\$"; then
    echo "  note: #$ractive carries claimed-by:$want although WORKER_ID is unset (the agent did not write it; likely applied by hand)"
  else
    echo "  note: $wname is active on #$ractive with no claimed-by label (expected: WORKER_ID is unset, the agent writes no labels)"
  fi
done

if [ -z "$orphan_report" ] && [ "$problems" -eq 0 ]; then
  echo "  claims consistent: no orphaned claims, every labeled claim matches its Worker"
fi
