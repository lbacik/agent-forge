# Detecting conflicting agent PRs through the GitHub API

Research for lbacik/agent-forge#27 (child of map #25). Sources, fetched 2026-10-19:

- The live GitHub GraphQL schema, read by introspection (`__type(name: ...)`) on api.github.com. The schema's own
  descriptions are the primary source for field and enum meanings.
- GitHub Docs pages, named where they are cited.
- Read-only `gh api graphql` / `gh api` queries against open PRs (lbacik/globaldb, lbacik/paysubscriptions,
  microsoft/vscode, home-assistant/core, kubernetes/kubernetes) where the docs are silent. These ran with an OAuth
  token (`repo` scope), not a Worker's fine-grained PAT.
- Upstream `simple-coding-agent` at `9c75f94` (v0.5.1) for how Workers query GitHub today.

"Observed" marks empirical results. "Unverified" marks what neither the docs nor the experiments settled.

## Answer in short

- **The conflict predicate is `PullRequest.mergeable == CONFLICTING`.** `mergeStateStatus == DIRTY` matched it in
  every sampled PR, but `mergeStateStatus` mixes in checks, reviews and branch protection (`BLOCKED`, `BEHIND`,
  `UNSTABLE`, ...), so use it only as diagnostic context.
- **`UNKNOWN` means "not computed yet". Reading the field through GraphQL starts the computation** (observed).
  The value settled by the next read, about 8–13 s later in every case observed. Treat `UNKNOWN` as "not
  conflicting on this poll". The next 60 s poll sees the real value, so no retry loop or extra REST call is needed.
- **Query:** one `repository.pullRequests(states: OPEN, baseRefName: <profile base>)` page of up to 100 PRs. Filter
  in the client by `headRefName` prefix `agent/issue-`, `isDraft == false` and `mergeable == CONFLICTING`. Take the
  issue number from the branch name and check that it is in the Queue's open-issue list. **Cost: 1 point per
  page**, measured. At one poll a minute that is 60 points/hour for the detector, about 1.2% of the 5,000/hour
  budget. With the existing Queue query (2 points per page) the total is about 180 points/hour.
- **No new token permission.** Workers already have `pull-requests: write` and `issues: write`, and they already
  read `repository.pullRequests` through GraphQL (`find_pull_request`).

## 1. `mergeable` vs `mergeStateStatus`

Schema descriptions (introspection of `MergeableState`, `MergeStateStatus` and `PullRequest`):

| Field / value | Schema description |
|---|---|
| `PullRequest.mergeable` | "Whether or not the pull request can be merged based on the existence of merge conflicts." |
| `MergeableState.MERGEABLE` | "The pull request can be merged." |
| `MergeableState.CONFLICTING` | "The pull request cannot be merged due to merge conflicts." |
| `MergeableState.UNKNOWN` | "The mergeability of the pull request is still being calculated." |
| `PullRequest.mergeStateStatus` | "Detailed information about the current pull request merge state status." |
| `MergeStateStatus.DIRTY` | "The merge commit cannot be cleanly created." |
| `MergeStateStatus.BEHIND` | "The head ref is out of date." |
| `MergeStateStatus.BLOCKED` | "The merge is blocked." |
| `MergeStateStatus.UNSTABLE` | "Mergeable with non-passing commit status." |
| `MergeStateStatus.HAS_HOOKS` | "Mergeable with passing commit status and pre-receive hooks." |
| `MergeStateStatus.CLEAN` | "Mergeable and passing commit status." |
| `MergeStateStatus.UNKNOWN` | "The state cannot currently be determined." |
| `MergeStateStatus.DRAFT` | Deprecated: "`isDraft` should be used instead". |

`mergeable` is defined only by merge conflicts, so it is the field for this question. `mergeStateStatus` is a
summary. For a PR that is not conflicting it reports protection and check state (`BLOCKED`, `UNSTABLE`, `CLEAN`),
so it is wrong as a conflict predicate. `BEHIND` is not a conflict. It means that a "require branches to be up to
date" rule applies and the head is behind the base.

Observed (`mergeable`, `mergeStateStatus`) pairs over about 150 open PRs in 11 repos: `(CONFLICTING, DIRTY)` 50 times,
`(MERGEABLE, BLOCKED|CLEAN|UNSTABLE)` for all the others, and `(UNKNOWN, UNKNOWN)` before the value settled.
`CONFLICTING` never appeared without `DIRTY`, and `DIRTY` never appeared without `CONFLICTING`.

`mergeStateStatus` used to sit behind the `merge-info-preview` Accept header. The github.com
[schema previews page](https://docs.github.com/en/graphql/overview/schema-previews) no longer lists any preview,
and `gh api graphql` (no preview header) returns the field. Unverified: the changelog date when the preview ended.

Related fields: `canBeRebased` ("Whether or not the pull request is rebaseable.") was `false` on every sampled
`CONFLICTING` PR and `true` on every `MERGEABLE` one. It does not add a signal, so the detector can leave it out.
`isDraft` replaces the deprecated `DRAFT` state.

Caveat: GitHub computes `mergeable` with a test **merge**, but Workers **rebase**. When the test merge conflicts, the
rebase normally conflicts too. A rebase can still conflict commit by commit while the final merge is clean; the
detector misses that case, and it does no harm. Unverified: whether GitHub's merge and Git's rebase ever disagree in
the other direction on real Worker PRs. The fast path in the map's Notes, "if the local rebase is clean, run the
check and push", covers it either way.

## 2. How `UNKNOWN` behaves

**Docs (REST only).** [REST: Get a pull request](https://docs.github.com/en/rest/pulls/pulls?apiVersion=2022-11-28#get-a-pull-request)
says: "The value of the `mergeable` attribute can be `true`, `false`, or `null`. If the value is `null`, then GitHub
has started a background job to compute the mergeability. After giving the job time to complete, resubmit the
request. When the job finishes, you will see a non-null value for the `mergeable` attribute in the response."
The [Git database guide](https://docs.github.com/en/rest/guides/using-the-rest-api-to-interact-with-your-git-database)
adds that the test merge commit is created only when someone views the PR in the UI with the Merge button showing,
or when a PR is fetched, created or edited through the REST API: "A consuming API needs to explicitly request a pull
request to create a *test* merge commit." Otherwise the merge refs "fall out of date until the next time someone
views the pull request".

The REST **list** endpoint (`GET /repos/{o}/{r}/pulls`) does not return `mergeable` or `mergeable_state` (observed:
its items have only `auto_merge`, `merge_commit_sha` and `merged_at`). So REST would need one extra GET per PR.

**GraphQL (docs silent; observed).**

- In lbacik/paysubscriptions, nine open PRs last updated before the default branch moved (2026-10-17 12:32 UTC) read
  `UNKNOWN/UNKNOWN` on the first GraphQL read, about 45 hours later. The PR updated after that push read
  `MERGEABLE/CLEAN`. The value seems to be invalidated when the base moves and to stay `UNKNOWN` until something
  reads it. It does not settle in the background on a timer.
- Reading through the GraphQL `pullRequests` connection, with no REST call, was enough to start the computation:

  | Repo | First read | Second read |
  |---|---|---|
  | microsoft/vscode | 40 of 40 `UNKNOWN` | at +10 s: 0 `UNKNOWN` (10 `CONFLICTING`) |
  | kubernetes/kubernetes | 38 of 40 `UNKNOWN` | at +8 s: 0 `UNKNOWN` (13 `CONFLICTING`) |
  | lbacik/paysubscriptions | 9 of 10 `UNKNOWN` | settled when read again about 90 s later (the exact time was lost) |

  The time between the reads was mostly the latency of the reads themselves, so the computation takes at most about
  10 s for ordinary PRs. Unverified: an upper bound for very large diffs, and whether GitHub ever stops computing for
  a PR that is read repeatedly.
- Reading does not change the PR's `updatedAt` (observed).

**Implication for the detector.** Treat `UNKNOWN` as "skip this poll". The read has started the computation, so the
next poll (60 s later) gets the settled value. Worst-case detection latency after a base push is about two polls.
A Worker's own force-push also makes its PR `UNKNOWN` for a moment, and skipping `UNKNOWN` keeps the detector from
requeueing a PR that is being fixed.

## 3. Query shape

Upstream today (`simple_coding_agent/github_tracker.py`):

- `list_issues` (`:416-446`) pages `repository.issues(first: 100, states: OPEN)` with a cursor. It is the Queue, and
  it already holds every open issue on each poll.
- `find_pull_request` (`:603-622`) uses `repository.pullRequests(first: 1, states: OPEN, headRefName: $head)`.
- `headRefName` on `pullRequests` is an **exact** match (introspected argument "The head ref name to filter the
  pull requests by"; observed: `agent/issue-` and `agent/issue-*` match 0 PRs, `agent/issue-149` matches 1).
  A prefix filter has to be applied in the client.
- The loop sleeps `POLL_INTERVAL` only when the Queue is empty (`lifecycle.py:3290-3310`; default 60 s,
  `config.py:200`). A detector run once per loop iteration therefore runs at most once a minute.

Proposed query, in the same style (a `GitHubGraphQLTransport` method that pages with a cursor):

```graphql
query ConflictCandidates($owner: String!, $name: String!, $base: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(first: 100, after: $cursor, states: OPEN, baseRefName: $base,
                 orderBy: {field: CREATED_AT, direction: ASC}) {
      nodes {
        id number headRefName baseRefName headRefOid isDraft
        mergeable mergeStateStatus
        closingIssuesReferences(first: 5) { nodes { number state } }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
```

Client-side filter, per node:

1. `headRefName` matches `^agent/issue-(\d+)$`, and N is the captured number.
2. `isDraft` is false (the map: a human took over).
3. `mergeable == "CONFLICTING"`. `UNKNOWN` is skipped this poll, and `MERGEABLE` is not a candidate.
4. Issue N is open. Check it against the Queue's open-issue set, which the same poll has already fetched, so no
   extra request is needed.

Notes on the fields:

- **`baseRefName: $base`** (the profile's `base_branch`) as a server-side filter. `prepare_attempt` rebases onto
  the profile base. If a human retargeted a PR to another base, rebasing it onto the profile base would be wrong,
  so leaving such a PR out is the safe default. This is also an argument of the existing connection.
- **Issue number from the branch name, not from `closingIssuesReferences`.** Closing keywords are "interpreted
  only when the pull request targets the repository's default branch". Otherwise "these keywords are ignored, no
  links are created"
  ([Linking a pull request to an issue](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue)).
  Upstream writes `Closes #N` (`publication.py:390`) but opens the PR against the profile's `base_branch`
  (`config.py:267`, default `main`), which need not be the default branch. In that case `closingIssuesReferences`
  is empty. Keep it in the query as a cross-check only, or drop it (cost below).
- **`headRefOid`** lets the detector and the budget (#29) tell "still conflicting at the same head that was
  already tried" from a new conflict after a new push.
- **`mergeStateStatus`** is included only for logs and the escalation comment. It does not drive decisions.

**Pagination.** One page of 100 covers typical target repos (observed: at most 10 open PRs in lbacik repos, most
of them Dependabot). The cursor loop matches `list_issues`.

**Alternative: search.** `search(type: ISSUE, query: "repo:o/r is:pr is:open draft:false head:agent/issue-")`
filters by prefix on the server. The docs say `head:` "matches pull requests opened from branch names beginning
with" the given text
([Searching issues and pull requests](https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests)),
and it matched 2 of 2 in lbacik/globaldb. It depends on the search index, though, and the docs do not state the
index lag (unverified). It also differs from the existing `repository.*` style. Use it only if a target repo ever
has more than 100 open non-agent PRs.

## 4. Point cost

From [Rate limits and query limits for the GraphQL API](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api):
cost = (sum of requests for each connection, assuming every `first`/`last` is filled) / 100, rounded, with a minimum
of 1. Users get 5,000 points/hour (PATs included). The secondary limits are 2,000 points/minute and 100 concurrent
requests.

| Query | Computed | Measured (`rateLimit { cost }`) |
|---|---|---|
| Proposed detector, `first: 100` + `closingIssuesReferences(first: 5)` | 1 + 100 = 101 → 1 | 1 (nodeCount 600) |
| Same with `first: 50` | 1 + 50 = 51 → 1 | 1 (nodeCount 300) |
| Detector plus `labels(first: 10)` per PR | 1 + 100 + 100 = 201 → 2 | 2 |
| Upstream Queue (`list_issues`, one page) | 1 + 100 + 100 = 201 → 2 | 2 (nodeCount 20,100) |

At one poll a minute, the detector costs 60 points/hour and Queue plus detector cost about 180 points/hour, about
3.6% of one account's budget. While an attempt runs the loop does not poll, so the real cost is lower. In a Pool,
the budget is per account (#20), so Workers that share one account add their costs together. Do not add per-PR
connections (labels, reviews, commits) to the detector: each one adds a point per page.

## 5. Token permissions

Workers use a fine-grained PAT limited to the target repo with `contents: write`, `pull-requests: write` and
`issues: write` (upstream `README.md:35-36`, `docs/agents/operator-onboarding.md:41-49`). The fine-grained
permission table lists `GET /repos/{o}/{r}/pulls` and `GET /repos/{o}/{r}/pulls/{n}` under **Pull requests**
([Permissions required for fine-grained PATs](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)).
A write grant is shown as "Read and write" in the token settings, so it includes read. The detector reads only PR objects and, optionally, linked issues. Workers already
read `repository.pullRequests` through GraphQL with this PAT (`find_pull_request`) and enable auto-merge on PRs
(ADR 0004: "The existing PAT scopes ... are enough"). **No new permission is needed.** Unverified: the experiments
here used an OAuth `repo` token, not a fine-grained PAT. The fine-grained case rests on the docs and on upstream's
existing production use of the same connection.

## Side observations for the map

- **`closingIssuesReferences` is empty when the profile's `base_branch` is not the default branch.** Recognising
  Worker PRs "with an open linked issue (`Closes #N`)" works only when the base is the default branch. Taking N from
  `agent/issue-N` and checking it against the Queue's open issues works for every base.
- **`BEHIND` also blocks auto-merge** when strict "require up to date" protection applies, and the same rebase would
  fix it. It is not a conflict and is out of #25's scope as written. It is worth a line in "Not yet specified" if
  Instances use strict protection.
