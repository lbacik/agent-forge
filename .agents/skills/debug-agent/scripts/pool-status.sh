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
# Contract path: when the Instance compose file carries the contract discovery
# label, every Worker whose container carries it is read through `agentfleet`
# (the prerequisite check in lib/contract.sh stops with the install command
# when it is missing or speaks another contract major, and reads no container
# files). One block per Worker comes from its Status Snapshot: instance state,
# Intake with pending stop or stop plan, priority, current issue and native
# phase. A stopped Worker is read through Offline Read, never reported as a
# gap. A Worker whose container carries no contract label stays on the legacy
# `agentctl status` block described above, so mixed-Worker Instances are read
# per Worker. Unlabelled Instances take the legacy path exactly as before.
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
# On the contract path the comparison runs only for Workers whose backend is
# simple-coding-agent: Claim markers are its native protocol. Any other
# backend is listed with a skip note and takes no part in the comparison.
#
# Exit codes: 0 even with stopped workers; 1 on usage, missing docker/gh,
# unreadable TARGET_REPO or a failed GitHub query; 2/3/4 from lib/resolve.sh.
# On the contract path the exit code is the first `agentfleet` failure when
# any Worker block could not be rendered (3 when `agentfleet` is missing or
# speaks another contract major).

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
. "$(dirname "$0")/lib/contract.sh"

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

# Per-Worker records for the --github pass: "n|WORKER_ID|active-or--" words
# (WORKER_ID matches [a-z0-9-], so no word ever contains whitespace).
# On the contract path a second list holds the Workers skipped from the
# comparison: "n|WORKER_ID|active-or--|backend" words.
records=""
skipped=""
contract_path=0
failcode=0

# compose_value SERVICE KEY -- one indented KEY value for a compose SERVICE
# (a WORKER_ID or a discovery label). Reads the Instance compose file only.
compose_value() {
  _cv_svc=$1
  _cv_key=$2
  awk -v svc="$_cv_svc" -v key="$_cv_key" '
    /^  [A-Za-z0-9_-]+:/ {
      cur = $1
      gsub(/:$/, "", cur)
      gsub(/^  /, "", cur)
    }
    cur == svc {
      i = index($0, key ":")
      if (i > 0) {
        v = substr($0, i + length(key) + 1)
        gsub(/^[ \t'\''"]+/, "", v)
        gsub(/[ \t'\''"]+$/, "", v)
        print v
        exit
      }
    }
  ' "$compose_file"
}

# legacy_worker_block N -- the legacy per-Worker block: container state plus
# `agentctl status` via one `docker exec` for a running Worker. Reads the
# shared $ps_out; appends to $records. Used for every Worker on the legacy
# path and for unlabelled containers on the contract path.
legacy_worker_block() {
  lw_n=$1
  if [ "$lw_n" -eq 1 ]; then
    lw_svc=agent
  else
    lw_svc="agent-$lw_n"
  fi
  lw_line=$(printf '%s\n' "$ps_out" | grep "^$lw_svc|" | head -n 1 || true)
  if [ -z "$lw_line" ]; then
    lw_cont="${project}-${lw_svc}-1 (not created)"
    lw_cstate="not created"
    lw_running=0
  else
    lw_cont=$(echo "$lw_line" | cut -d'|' -f2)
    lw_cstate=$(echo "$lw_line" | cut -d'|' -f4)
    [ -n "$lw_cstate" ] || lw_cstate=$(echo "$lw_line" | cut -d'|' -f3)
    if [ "$(echo "$lw_line" | cut -d'|' -f3)" = running ]; then
      lw_running=1
    else
      lw_running=0
    fi
  fi

  lw_wid=""
  lw_intake=""
  lw_active="unavailable (container not running)"
  lw_pending="unavailable (container not running)"
  lw_status_err=""
  if [ "$lw_running" -eq 1 ]; then
    # One docker call per running Worker: the live status plus the WORKER_ID
    # the claim labels are built from. A failure is reported inline and the
    # rest of the pool is still listed.
    lw_status_out=$(docker exec -u agent "$lw_cont" sh -c 'echo "WORKER_ID=$WORKER_ID"; agentctl status' 2>&1 || true)
    if echo "$lw_status_out" | grep -q '^intake: '; then
      lw_wid=$(echo "$lw_status_out" | sed -n 's/^WORKER_ID=//p' | head -n 1 | tr -d '\r' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      lw_intake=$(echo "$lw_status_out" | sed -n 's/^intake: //p' | head -n 1 | tr -d '\r')
      lw_active=$(echo "$lw_status_out" | sed -n 's/^active_attempt: //p' | head -n 1 | tr -d '\r')
      lw_pending=$(echo "$lw_status_out" | sed -n 's/^pending_next_issue: //p' | head -n 1 | tr -d '\r')
    else
      lw_status_err=$(echo "$lw_status_out" | head -n 3 || true)
    fi
  fi
  lw_active_issue=$(echo "$lw_active" | sed -n 's/^issue #\([0-9][0-9]*\).*/\1/p' || true)

  if [ -n "$lw_wid" ]; then
    lw_disp="worker $lw_n ($lw_wid)"
  elif [ "$lw_n" -eq 1 ]; then
    lw_disp="worker 1 (first Worker)"
  else
    lw_disp="worker $lw_n ($short-$lw_n)"
  fi
  echo "$lw_disp service=$lw_svc:"
  echo "  container:           $lw_cont [$lw_cstate]"
  if [ -n "$lw_status_err" ]; then
    echo "  error:               agentctl status failed:"
    echo "$lw_status_err" | sed 's/^/    /'
  elif [ "$lw_running" -eq 1 ]; then
    echo "  intake:              $lw_intake"
    echo "  active_attempt:      $lw_active"
    echo "  pending_next_issue:  $lw_pending"
  else
    echo "  status:              $lw_active"
  fi

  if [ -z "$lw_active_issue" ]; then
    lw_active_issue="-"
  fi
  records="$records $lw_n|$lw_wid|$lw_active_issue"
}

# contract_worker_block N PS_LINE -- one Status Snapshot block for a labelled
# Worker via `agentfleet status` (Offline Read when its container is stopped).
# Appends to $records (simple-coding-agent backend) or $skipped (any other
# backend); records the first `agentfleet` failure in $failcode and keeps
# listing the rest of the pool.
contract_worker_block() {
  cw_n=$1
  cw_line=$2
  if [ "$cw_n" -eq 1 ]; then
    cw_svc=agent
  else
    cw_svc="agent-$cw_n"
  fi
  cw_managed=$(managed_instance_name "$short" "$cw_n")
  cw_wid=$(compose_value "$cw_svc" "WORKER_ID" || true)
  cw_backend_label=$(compose_value "$cw_svc" "$BACKEND_LABEL" || true)
  if [ -n "$cw_wid" ]; then
    cw_disp="worker $cw_n (managed $cw_managed, $cw_wid)"
  else
    cw_disp="worker $cw_n (managed $cw_managed)"
  fi

  cw_cont=$(echo "$cw_line" | cut -d'|' -f2)
  cw_cstate=$(echo "$cw_line" | cut -d'|' -f4)
  [ -n "$cw_cstate" ] || cw_cstate=$(echo "$cw_line" | cut -d'|' -f3)
  if [ "$(echo "$cw_line" | cut -d'|' -f3)" = running ]; then
    cw_running=1
    cw_offline=0
  else
    cw_running=0
    cw_offline=1
  fi

  cw_tmp=$(mktemp) || exit 1
  cw_err=$(mktemp) || { rm -f "$cw_tmp"; exit 1; }
  if agentfleet status "$cw_managed" --json >"$cw_tmp" 2>"$cw_err"; then
    if cw_meta=$(python3 "$(dirname "$0")/lib/render_pool.py" --meta <"$cw_tmp" 2>"$cw_err"); then
      cw_backend=$(echo "$cw_meta" | cut -d'|' -f1)
      cw_active=$(echo "$cw_meta" | cut -d'|' -f2)
      [ -n "$cw_backend" ] || cw_backend="$cw_backend_label"
      [ -n "$cw_backend" ] || cw_backend="unknown"
      if ! python3 "$(dirname "$0")/lib/render_pool.py" --block \
        --worker-label "$cw_disp" --service "$cw_svc" \
        --container "$cw_cont" --cstate "$cw_cstate" --offline "$cw_offline" <"$cw_tmp"; then
        echo "$cw_disp service=$cw_svc backend=$cw_backend:"
        echo "  container:           $cw_cont [$cw_cstate]"
        echo "  error:               cannot render Status Snapshot for managed instance '$cw_managed'"
        [ "$failcode" -eq 0 ] && failcode=1
        cw_active="-"
      fi
    else
      [ -n "$cw_backend_label" ] || cw_backend_label="unknown"
      echo "$cw_disp service=$cw_svc backend=$cw_backend_label:"
      echo "  container:           $cw_cont [$cw_cstate]"
      echo "  error:               cannot render Status Snapshot for managed instance '$cw_managed':"
      head -n 3 "$cw_err" | sed 's/^/    /'
      [ "$failcode" -eq 0 ] && failcode=1
      cw_backend="$cw_backend_label"
      cw_active="-"
    fi
  else
    cw_code=$?
    [ -n "$cw_backend_label" ] || cw_backend_label="unknown"
    echo "$cw_disp service=$cw_svc backend=$cw_backend_label:"
    echo "  container:           $cw_cont [$cw_cstate]"
    echo "  error:               agentfleet status failed for managed instance '$cw_managed' (exit $cw_code, no legacy fallback):"
    head -n 3 "$cw_err" | sed 's/^/    /'
    cat "$cw_tmp" 2>/dev/null | head -n 3 | sed 's/^/    /' || true
    [ "$failcode" -eq 0 ] && failcode=$cw_code
    cw_backend="$cw_backend_label"
    cw_active="-"
  fi
  rm -f "$cw_tmp" "$cw_err"
  if [ -z "$cw_active" ]; then
    cw_active="-"
  fi
  case "$cw_backend" in
    simple-coding-agent|"")
      records="$records $cw_n|$cw_wid|$cw_active"
      ;;
    *)
      skipped="$skipped $cw_n|$cw_wid|$cw_active|$cw_backend"
      ;;
  esac
}

# Path selection: a compose file carrying the contract discovery label takes
# the contract path below. Unlabelled Instances run the legacy loop exactly
# as before.
if [ -f "$compose_file" ] && grep -q "$CONTRACT_LABEL" "$compose_file" 2>/dev/null; then
  contract_path=1
fi

if [ "$contract_path" -eq 1 ]; then
  if ! require_agentfleet; then
    exit 3
  fi
  # One shared `docker ps` for every Worker's container state, with the
  # contract label as the per-Worker path selector (a fifth column).
  ps_out=$(docker ps -a --filter "label=com.docker.compose.project=$project" \
    --format '{{.Label "com.docker.compose.service"}}|{{.Names}}|{{.State}}|{{.Status}}|{{.Label "'"$CONTRACT_LABEL"'"}}' 2>/dev/null || true)

  echo "instance:        $dir (project $project) on context $context ($mode) (contract path)"

  # shellcheck disable=SC2086
  for n in $worker_list; do
    if [ "$n" -eq 1 ]; then
      svc=agent
    else
      svc="agent-$n"
    fi
    line=$(printf '%s\n' "$ps_out" | grep "^$svc|" | head -n 1 || true)
    if [ -z "$line" ]; then
      # Never created: no container for agentfleet to address. Reported as
      # such, like on the legacy path; the Instance compose file still names
      # the Worker id and backend for the records below.
      if [ "$n" -eq 1 ]; then
        svc=agent
      else
        svc="agent-$n"
      fi
      wid=$(compose_value "$svc" "WORKER_ID" || true)
      backend_label=$(compose_value "$svc" "$BACKEND_LABEL" || true)
      managed=$(managed_instance_name "$short" "$n")
      if [ -n "$wid" ]; then
        disp="worker $n (managed $managed, $wid)"
      else
        disp="worker $n (managed $managed)"
      fi
      [ -n "$backend_label" ] || backend_label="unknown"
      echo "$disp service=$svc backend=$backend_label:"
      echo "  container:           ${project}-${svc}-1 (not created)"
      echo "  status:              unavailable (not created)"
      case "$backend_label" in
        simple-coding-agent|""|unknown)
          records="$records $n|$wid|-"
          ;;
        *)
          skipped="$skipped $n|$wid|-|$backend_label"
          ;;
      esac
      continue
    fi
    clabel=$(echo "$line" | cut -d'|' -f5)
    case "$clabel" in
      ""|"<no value>")
        legacy_worker_block "$n"
        ;;
      *)
        contract_worker_block "$n" "$line"
        ;;
    esac
  done
else
  # One shared `docker ps` for every Worker's container state.
  ps_out=$(docker ps -a --filter "label=com.docker.compose.project=$project" \
    --format '{{.Label "com.docker.compose.service"}}|{{.Names}}|{{.State}}|{{.Status}}' 2>/dev/null || true)

  echo "instance:        $dir (project $project) on context $context ($mode)"

  # shellcheck disable=SC2086
  for n in $worker_list; do
    legacy_worker_block "$n"
  done
fi

if [ -z "$github" ]; then
  if [ "$contract_path" -eq 1 ]; then
    exit "$failcode"
  fi
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
# Labels owned by a Worker skipped from the comparison (another backend) are
# reported as unverified, never as orphaned.
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
    if [ -z "$owner" ]; then
      # shellcheck disable=SC2086
      for s in $skipped; do
        sn=${s%%|*}; srest=${s#*|}
        swid=${srest%%|*}; srest2=${srest#*|}
        sactive=${srest2%%|*}; sbackend=${srest2#*|}
        sid=$swid
        if [ -z "$sid" ] && [ "$sn" != 1 ]; then
          sid="$short-$sn"
        fi
        if [ -n "$sid" ] && [ "$sid" = "$id" ]; then
          owner="skip-$sn"
          owner_backend=$sbackend
          break
        fi
      done
    fi
    case "$owner" in
      (ok-*) ;;
      ("")
        echo "  orphaned claim: #$num labeled claimed-by:$id, but no such Worker in this Instance (remove the label by hand)"
        ;;
      (skip-*)
        echo "  note: #$num labeled claimed-by:$id for a $owner_backend Worker; Claim-marker comparison skipped (not verified)"
        ;;
      (*)
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

# Workers skipped from the comparison: named with their backend and, when
# they hold a live attempt, with the issue the comparison cannot verify.
# shellcheck disable=SC2086
for s in $skipped; do
  sn=${s%%|*}; srest=${s#*|}
  swid=${srest%%|*}; srest2=${srest#*|}
  sactive=${srest2%%|*}; sbackend=${srest2#*|}
  if [ -n "$swid" ]; then
    swname="$swid"
  elif [ "$sn" -eq 1 ]; then
    swname="worker 1"
  else
    swname="$short-$sn"
  fi
  if [ "$sactive" != "-" ]; then
    echo "  note: $swname (worker $sn, backend $sbackend) is active on #$sactive; Claim-marker comparison skipped (Claim markers are the simple-coding-agent native protocol)"
  else
    echo "  note: $swname (worker $sn, backend $sbackend); Claim-marker comparison skipped (Claim markers are the simple-coding-agent native protocol)"
  fi
done

orphans=0
if printf '%s\n' "$orphan_report" | grep -q 'orphaned claim:'; then
  orphans=1
fi
if [ "$orphans" -eq 0 ] && [ "$problems" -eq 0 ]; then
  if [ -n "$skipped" ]; then
    echo "  claims consistent for compared Workers; some Workers skipped (no Claim-marker comparison for their backend)"
  else
    echo "  claims consistent: no orphaned claims, every labeled claim matches its Worker"
  fi
fi

if [ "$contract_path" -eq 1 ]; then
  exit "$failcode"
fi
