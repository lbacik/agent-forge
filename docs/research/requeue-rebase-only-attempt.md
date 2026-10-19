# What a requeued attempt does today when the only change is the rebase

Research for [#26](https://github.com/lbacik/agent-forge/issues/26), part of map
[#25](https://github.com/lbacik/agent-forge/issues/25) (Conflict requeue).

Source: `simple-coding-agent` at `9c75f94417929689aecb51cf72f0e4abfdc6a68a`
(v0.5.1, merge of PR #267, 2026-10-17). Paths below are relative to
`simple_coding_agent/`. One GitHub behaviour is quoted from GitHub's docs and
marked as such.

## Starting state

Previous attempt ended `complete`: PR open on `agent/issue-N`, auto-merge
enabled. Release removed `ready-for-agent` and the assignee
(`lifecycle.py:4294-4297` → `github_tracker.py:321-339`). "Requeue" today means a
human re-adds `ready-for-agent`; nothing else puts a `complete` issue back in the
Queue (eligibility: open, `ready-for-agent`, unassigned, non-empty body, no
blockers, `github_tracker.py:88-97`). Such a claim is recorded as
`requeue_source=human` (`recovery.py:96-105`), and the auto-merge opt-in is read
from the issue's labels at claim time (`lifecycle.py:3703`, `lifecycle.py:5066-5077`).

## The pipeline, step by step

1. **Prepare.** `prepare_attempt` fetches origin, repairs the local base,
   fetches `origin/agent/issue-N`, points the local branch at it, and rebases
   onto the base branch (`git_workspace.py:217-258`). If the remote branch is
   missing, it falls back to a local `agent/issue-N` (`git_workspace.py:246-248`).
   Cleanup never deletes branches, so a local branch from an earlier attempt is
   usually still there (`git_workspace.py:483`). If neither exists, it creates a
   new branch from base (`git_workspace.py:250-251`).
   - A clean rebase returns `(None, ())` (`git_workspace.py:678-687`).
   - A conflicting rebase is **left in progress**. The branch ref still points
     at the pre-rebase tip, and the conflicted files and pre-rebase sha are
     returned. A rebase failure without conflicts raises
     (`git_workspace.py:679-686`).
2. **Continuation flag.** `continuation = bool(commits_added(prepared))`
   (`lifecycle.py:344-345`), where `commits_added` is
   `base_revision..branch` (`git_workspace.py:296-312`). The PR's existing
   commits count, so a requeued published PR is **always a continuation**
   (unless the rebase empties the branch, see "PR merged" below).
3. **Setup and baseline.**
   - Clean rebase: setup and baseline run **before** the model
     (`lifecycle.py:370-380`). On a continuation a red baseline is tolerated
     (`completion.py:228`, `lifecycle.py:1091-1094`), and its failure is quoted
     in the prompt (`lifecycle.py:389-399`, `completion.py:129-182`).
   - Conflicting rebase: `setup_deferred = conflict_state().in_progress`
     (`lifecycle.py:350-351`). Setup and baseline are **skipped** before the
     model (`lifecycle.py:352-368`) and run after it as a "deferred"
     baseline (`lifecycle.py:538-548`).
4. **Model, always.** There is no model-free path. Every requeued attempt
   dispatches the model with the **full issue body plus trusted comments**
   (`lifecycle.py:401-410`, `lifecycle.py:5403`). Because it is a
   continuation, the prompt also gets the handoff-note pointer and the
   "invoke `code-review` ... or the attempt is classified incomplete" sentence
   (`lifecycle.py:5403-5411`). A conflicting rebase adds "Resolve them first
   ... run git rebase --continue ..., **then continue the implementation**"
   (`lifecycle.py:5412-5418`). The completion-gate section repeats the
   `code-review` requirement (`lifecycle.py:5345-5352`). Nothing tells the model
   that this is a conflict-only round or that it should do no new work.
5. **Conflict verification (conflicting rebase only).** After the model,
   `conflict_state().resolution_problems` runs:
   - rebase/merge still in progress or unmerged paths;
   - conflict markers in any tracked or untracked file;
   - `git diff --check`

   (`lifecycle.py:475`, `git_workspace.py:314-350`, `git_workspace.py:698-770`).
   Any problem triggers `abort_unresolved_rebase` (rebase abort plus a hard
   reset to the pre-rebase sha, `git_workspace.py:772-803`) and raises
   `RebaseConflictError` (`lifecycle.py:476-505`).
6. **Seal.** Leftover dirty work is committed (`lifecycle.py:520-536`).
7. **Commit count used for completion** is again `base..branch`
   (`lifecycle.py:549`), so the rebased PR commits count as commits even if the
   model added none.
8. **Deferred-baseline gate.** On the conflicting path, a red deferred baseline
   with status `SUCCEEDED` and commits gives `incomplete`. The reason is the
   `deferred_baseline_failed` text, and the final check is skipped
   (`lifecycle.py:605-631`, `completion.py:368-381`).
9. **Final check** runs when status is `SUCCEEDED`, commits > 0 and no deferred
   baseline failure (`lifecycle.py:640-655`). It does **not** depend on
   whether `code-review` ran: `mark_review_complete` checks only baseline,
   status, commits and repair cycles (`completion.py:231-248`).
10. **Evaluation.** `acceptance_criteria_satisfied = review_count > 0 and ...`
    (`lifecycle.py:724-731`). In production the second term is the default
    `lambda claim: True`, because `__main__.py:83-105` does not pass it. With
    commits > 0 and no `code-review` in this run, the attempt is `incomplete`
    ("Acceptance criteria are not satisfied.", `completion.py:382-387`).
    `no_changes` needs `commit_count == 0` (`completion.py:358-363`), which a
    rebased PR branch normally never has.
11. **The review nudge does not cover rebase-only runs.** The stop hook blocks
    the first finish without a review only when commits *added by this run*
    exist (`model_execution.py:2620-2646`). "Added by this run" is measured
    against the pre-dispatch commit count (`lifecycle.py:853-870`, `lifecycle.py:418`).
    A rebase keeps the count unchanged, so a model that only rebases (or only
    runs `git rebase --continue`) and skips `code-review` is **not nudged**. It
    ends `incomplete`.
12. **Publication** (`publication.py:142-224`):
    - `complete` (publication-eligible): push, then `_ensure_pull_request`
      returns the existing **OPEN** PR for the head branch
      (`publication.py:240-243`, `github_tracker.py:603-623`). Then
      `_maybe_auto_merge` runs when `PR_AUTO_MERGE=true`, or `label` with the
      claim-time opt-in (`publication.py:204-215`). It calls
      `enablePullRequestAutoMerge` again. An "already enabled" error counts as
      enabled, "already merged" as merged, and "clean/unstable status / not
      mergeable / no protection rules" falls back to a direct merge
      (`publication.py:268-343`, `publication.py:442-473`).
    - `incomplete` with commits gives `PublicationPath.PARTIAL`
      (`completion.py:436-447`). The branch **is still pushed**, but no PR call
      and no merge call is made (`publication.py:160-192`, `publication.py:194`).
    - `infrastructure_error` from a rebase conflict uses `PublicationPath.NONE`,
      so there is **no push**. The result comment says "no branch created"
      (`lifecycle.py:4929-4970`, `lifecycle.py:4891-4927`, `publication.py:411`).
    - Every push is `git push --force-with-lease=<branch>:<observed remote sha>`
      after a fresh fetch of the remote ref (`git_workspace.py:575-616`), so a
      rebased branch is force-pushed whenever a push happens.
13. **Release.** Every non-handoff outcome removes `ready-for-agent` and the
    assignee (`lifecycle.py:4284-4297`).

GitHub side, quoted from GitHub's docs ("Automatically merging a pull request"),
not upstream code: *"Auto-merge is disabled if someone without write permissions
pushes new changes to the head branch or switches the base branch."* The Worker
token pushes with write access, so a force-push by the Worker (including the
`incomplete` partial push) should leave an existing auto-merge request in
place. This was not verified against a live PR.

## Case table

Starting point: published PR, auto-merge on, a human re-adds `ready-for-agent`.

| Case | Outcome | Force-push of rebased branch | Auto-merge call | Mandatory `code-review` | Setup / baseline / check |
|---|---|---|---|---|---|
| Clean rebase, model adds no commits, invokes `code-review`, check green | `complete` | yes | yes, re-enabled (`already enabled` = ok, or direct merge if mergeable) | required by prompt; satisfied | setup + baseline **before** model; final check after |
| Clean rebase, model adds no commits, **skips** `code-review` | `incomplete` ("Acceptance criteria are not satisfied.") | yes (partial push) | no | required; no stop-hook nudge (no new commits) | setup + baseline before model; final check **still runs** |
| Clean rebase, model adds commits (+ `code-review`, green) | `complete` | yes | yes | required; nudged once if skipped | setup + baseline before; final check after |
| Clean rebase, final check red | `incomplete` | yes (partial) | no | as above | as above |
| Clean rebase, baseline red (tolerated continuation) | depends on model fixing it; same as rows above | as above | as above | as above | baseline failure quoted in the prompt |
| Conflicting rebase, model resolves, adds no commits, `code-review`, deferred baseline green, check green | `complete` | yes | yes | required; satisfied | setup + baseline **deferred** until after model; final check after |
| Conflicting rebase, resolved, deferred baseline red | `incomplete` / `deferred_baseline_failed` | yes (partial; resolved branch) | no | irrelevant (gate precedes acceptance check) | deferred setup + baseline; **no** final check |
| Conflicting rebase, resolved, no `code-review` | `incomplete` (acceptance) | yes (partial) | no | no nudge (rebased commits are not "new") | deferred setup + baseline; final check runs |
| Conflicting rebase, model leaves conflicts / markers / whitespace errors | `infrastructure_error` / `rebase_conflict` | **no** (branch reset to pre-rebase sha, nothing pushed) | no | n/a | **no** setup, baseline or check |
| Model hits limit / handoff | `handoff` or `incomplete` (normal rules) | partial push | no | n/a | as per branch |

`no_changes` is not reachable on a published PR branch in practice, because
`commit_count` counts every `base..branch` commit (`completion.py:358-363`,
`lifecycle.py:549`). The exception is a branch whose commits are already in the
base (see below).

## PR merged or closed before the claim

Today there is no detection step, and nothing reads PR state before the model
runs. The only PR lookup is at publication: `find_pull_request` with
`states: OPEN` (`publication.py:241`, `github_tracker.py:611`). The other
reference, `lifecycle.py:2704`, is a recovery/telemetry read.

- **PR merged.** With `Closes #N` on a merge into the default branch, GitHub
  closes the issue, so the issue is not eligible. The Queue lists only `OPEN`
  issues (`github_tracker.py:422`), and the claim re-reads and re-checks
  eligibility (`github_tracker.py:298-305`). No attempt runs. If the issue
  stays open (merge into a non-default base, or a human reopened it):
  - The branch (remote or local fallback) is rebased onto a base that already
    contains its work. For `merge`, the commits are ancestors of the base, so
    the branch becomes equal to the base. For `squash`/`rebase`, git skips
    commits it detects as already applied, but this can also conflict.
  - If `base..branch` becomes empty, `continuation=False` (`lifecycle.py:345`).
    The baseline must then be green, and the model gets a **fresh** prompt
    without the continuation pointer. It may re-implement the issue. New
    commits create a **new PR**, because no OPEN PR is found; no commits give
    `no_changes`.
- **PR closed unmerged.** The issue stays open. A requeue runs the normal
  attempt above on the still-existing branch. On `complete`,
  `find_pull_request` finds no OPEN PR, so a **new PR** is created
  (`publication.py:244-262`) and auto-merge is applied to it per mode. On
  `incomplete`, only the branch is pushed, with no PR.
  - If the branch was deleted on GitHub, the local branch is used
    (`git_workspace.py:246-248`).
  - In a fresh clone with no branch anywhere, the attempt starts from base. If
    an earlier `incomplete`/`handoff` comment that published a branch exists,
    `_continuation_expected` short-circuits to `incomplete`
    `continuation_branch_missing` (`lifecycle.py:323-335`, `lifecycle.py:5440-5469`).
- **Merged or closed while the attempt runs** (same mechanism):
  - The push uses `--force-with-lease` against the freshly observed remote
    sha, so a deleted branch is simply re-created.
  - `find_pull_request` then returns none, and a `complete` attempt opens a
    new PR.

## What the conflict-only attempt must change (baseline for #28)

- The model is always called, with the full issue prompt that says "then
  continue the implementation" and requires `code-review`. There is no clean-rebase
  fast path (`lifecycle.py:370-420`, `lifecycle.py:5403-5418`).
- `code-review` is mandatory for `complete` whenever `base..branch` is non-empty
  (`lifecycle.py:729`, `completion.py:382-387`). A rebase-only run that skips it
  ends `incomplete` without the stop-hook nudge (`model_execution.py:2638`).
- A clean rebase runs setup and baseline before the model and the final check
  after it. That is two runs of the check gate for a change that had no new
  work (`completion.py:207-229`, `lifecycle.py:640-655`).
- After resolved conflicts, setup and baseline are deferred. A red deferred
  baseline ends the attempt `incomplete` before the final check.
- Even `incomplete` force-pushes the rebased branch. An existing auto-merge
  request is not touched by the agent and, per GitHub docs, survives a
  write-access push. A resolved-but-unreviewed branch could therefore still be
  auto-merged once required checks pass.
- An unresolved conflict pushes nothing and reports `infrastructure_error` /
  `rebase_conflict`, and releases `ready-for-agent`. Nothing re-queues it, and
  the PR stays conflicted.
- PR state (open/merged/closed/draft) is never checked before the attempt.
  Only the issue state gates the claim.
