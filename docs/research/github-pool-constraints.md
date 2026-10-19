# GitHub side of a Pool: permissions, rate limits, branch protection

Research for lbacik/agent-forge#20 (child of map #17). Sources are GitHub Docs pages (docs.github.com), fetched
2026-10-19; the upstream poll default comes from the sibling `simple-coding-agent` checkout (`README.md`,
`simple_coding_agent/config.py:200`). Each claim names its page. "Unverified" marks what the pages did not state.

## Answer in short

- Each Worker account needs **write** access (collaborator on a user-owned repo, or outside collaborator / team
  member with the Write role on an org repo). Write is the lowest role that can assign, label, push and open a branch
  PR, and the only one that can enable auto-merge or merge.
- Rate limits are **per account**, so N accounts give N independent 5,000/hour primary budgets. Polling every 60 s
  uses roughly 60 requests/hour per Worker, far below any limit. Secondary limits are the real constraint, and they
  are met by serial requests and a one-second pause between writes, which one Worker already does.
- Branch protection works with N accounts, but **a Worker cannot approve its own PR**, so "required reviews" needs
  either a human reviewer or a differently-identified account with write access. Auto-merge needs the repo setting
  plus a protection rule that makes the PR not immediately mergeable.

## 1. What each machine account needs on the target repo

**Role.** Repository roles
([Repository roles for an organization](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/repository-roles-for-an-organization)):

| Capability | Read | Triage | Write |
|---|---|---|---|
| Close, reopen, assign issues and PRs | no | yes | yes |
| Apply/dismiss labels | no | yes | yes |
| Push to the repo's branches | no | no | yes |
| Enable/disable auto-merge | no | no | yes |
| Merge a pull request | no | no | yes |

Read can only send PRs from forks. Since the Worker pushes `agent/issue-<N>` to the target repo itself, **Write is
the minimum**; Triage is enough only for a claim-only account (no push).

**Assignability.** The assignee must be assignable on the repo: yourself, a commenter, anyone with write
permission, or an org member with read
([Assigning issues and pull requests](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/assigning-issues-and-pull-requests-to-other-github-users)).
Issues and PRs take up to 10 assignees. Hard cap for the Pool: **at most 10 accounts can be assigned to one issue**
(only relevant if a design ever assigns several; the claim uses one).

**REST behaviour that matters for claiming.** `POST .../issues/{n}/assignees` ("Add assignees to an issue",
[REST: Assignees](https://docs.github.com/en/rest/issues/assignees)): users already assigned are **not replaced**
(additive), and when the caller lacks push access "Assignees are silently ignored" with no error. `GET
/repos/{o}/{r}/assignees/{user}` returns 204 or 404 and can verify a Worker identity up front (cheap startup
check). Note for the claim race (map #17): additive assign means two Workers can both end up on one issue, so
post-assign verification is on the Worker, as the map already observes. The GraphQL `addAssigneesToAssignable`
mutation is not described on the pages fetched (unverified: its replace/additive semantics; check the GraphQL
reference before relying on it).

**Account invitation.** An invited collaborator must accept the invitation
([Inviting collaborators to a personal repository](https://docs.github.com/en/account-and-profile/setting-up-and-managing-your-personal-account-on-github/managing-access-to-your-personal-repositories/inviting-collaborators-to-a-personal-repository)).
Orgs may also require 2FA before acceptance
([Adding outside collaborators](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-outside-collaborators/adding-outside-collaborators-to-repositories-in-your-organization)).
That page also says an outside collaborator on a private repo uses a paid licence on a paid plan, not on free plans
(as summarised by the fetch; confirm against the billing docs for your plan).

**Token type and scopes.** GitHub recommends fine-grained PATs, limited to one resource owner and chosen
repositories; classic PATs with `repo` reach everything the account can
([Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)).
Fine-grained permissions per endpoint
([Permissions required for fine-grained PATs](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)):

| Operation | Fine-grained permission |
|---|---|
| List issues, list/check assignees | Issues: read (and/or Pull requests: read) |
| Add assignees, comment, add/remove labels | Issues: write (or Pull requests: write) |
| Create pull request | Pull requests: write |
| Create/delete branch ref (`git/refs`), git push | Contents: write (creating a ref also lists Workflows: write) |
| Merge pull request (REST) | Contents: write |
| Enable auto-merge (GraphQL) | not listed on that page; unverified |

So the practical set is **Contents: write, Issues: write, Pull requests: write** (Metadata: read is implicit).
Add **Workflows: write** if the Worker may push changes under `.github/workflows` (the page lists it for ref
creation; unverified whether it is enforced when no workflow file changes).

Caveats from the same token page: fine-grained tokens are per-resource-owner and organisations may require approval
(a pending token "will only be able to read public resources"); they cannot be used on public repos where the
user is not a member, and a lifetime policy may cap expiry. The page states classic tokens are the ones that can
write to repos the user is a collaborator on outside their own org context (outside collaborators use them "to
access organization repositories"). Whether a fine-grained token works for an **outside collaborator** on an org
repo is not stated on the fetched pages (unverified); if the Worker accounts are not org members, plan to test this
before choosing the token type.

**Terms of service.** Machine accounts are allowed but a human must create them and remains responsible; you may
keep "no more than one free machine account in addition to your free Personal Account"
([GitHub Terms of Service, B.3](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service)).
N Worker accounts therefore each need an accountable human owner/free-account allowance (or be paid accounts or org
members); a Pool of N identical free machine accounts owned by one person conflicts with the quoted limit. Treat as
a risk to confirm for the chosen account model.

## 2. Rate limits with N polling Workers

Primary limits
([REST rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api),
[GraphQL limits](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api)):

- REST: 5,000 requests/hour **per user**, shared across all that user's PATs and OAuth/App tokens on its behalf
  (15,000 for some Enterprise Cloud app cases). Different accounts have independent budgets, so N Workers do not
  compete for one budget. If one Worker had several tokens for the same account they would share it.
- GraphQL: 5,000 points/hour per user; cost is derived from connections (nodes requested / 100, min 1). `rateLimit
  { cost remaining resetAt }` shows the cost of a query.
- Exceeded: 403/429 with `x-ratelimit-remaining: 0`; wait until `x-ratelimit-reset`.

Secondary limits (same REST page):

- No more than 100 concurrent requests (REST and GraphQL together).
- No more than 900 points/minute for REST endpoints and 2,000/minute for GraphQL. Points: GET/HEAD/OPTIONS 1,
  POST/PATCH/PUT/DELETE 5; GraphQL query 1, GraphQL with mutation 5.
- No more than 90 s CPU per 60 s (max 60 s of it GraphQL).
- Content creation: about 80 requests/minute and 500/hour (some endpoints lower).
- Rules for handling: obey `retry-after`; else if `x-ratelimit-remaining` is 0 wait for reset; else wait at least a
  minute and back off exponentially; continuing while limited "may result in the banning of your integration".
- GitHub states these limits can change without notice.

Best practices
([Best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)):
make requests serially, not concurrently; leave at least one second between mutating requests; prefer webhooks
over polling and, when polling, honour `x-poll-interval`; use `If-None-Match`/`If-Modified-Since`: a 304 for an
authorised request does not count against the primary limit.

Applying it. Upstream's default is `POLL_INTERVAL=60` (simple-coding-agent `README.md`; `config.py:200`).
Whether secondary/primary accounting is per account or per IP for secondary limits is **not stated on these pages**
(the page says secondary limits apply to "the endpoint", and points to the authenticated user's budget only for the
primary limit; unverified). Even assuming a shared bucket, N Workers at one empty-queue poll per minute is
N points/minute against 900 (REST) or 2,000 (GraphQL), so polling load is negligible for any plausible N.
The load that matters is the claim/push/PR burst: a claim is an assign mutation (5 points) plus label changes,
comments, ref, PR, each 5 points, and content creation caps at 80/minute. N Workers finishing simultaneously stay
well inside these. Recommended hardening for the spec: jitter the poll interval per Worker so N containers started
together do not poll in lockstep; send conditional requests for the queue listing; honour `retry-after` and
`x-ratelimit-reset` on all failures. Whether upstream already does the last one is out of scope here.

## 3. Branch protection, required reviews and auto-merge with PRs from different accounts

Branch protection
([About protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)):

- Required approving reviews must come from people with **write** permissions (or a code owner, if enabled).
  Approvals can be dismissed as stale on new commits. An option requires the most recent reviewable push to be
  approved by someone other than the pusher.
- Required status checks must pass (successful, skipped or neutral); strict mode requires the branch to be up to
  date with the base.
- Restrictions do not apply to admins or bypass-role holders unless "Do not allow bypassing" is set.
- Restrict who can push: only listed users/teams/apps. If this is used on the base branch it does not affect
  `agent/issue-<N>` branches, which are not protected, but any rule matching `agent/*` would.
- Linear history forces squash or rebase merges; signed commits would require the Workers to sign; a merge queue
  is available.

Reviews
([Approving a pull request with required reviews](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/approving-a-pull-request-with-required-reviews)):
"Pull request authors cannot approve their own pull requests." Approvals from write/admin users count toward merge
requirements. Consequences for the Pool:

- A PR opened by `worker-1` can be approved by `worker-2` (a different account with write), but that is an agent
  reviewing an agent; a policy decision, not a technical block. Same-account approval is impossible.
- If "required reviews" is on and no second account or human reviews, the PR stays blocked; only owners/admins can
  merge without it ("Repository owners and administrators can merge a pull request even if it hasn't received an
  approving review"), and a Worker should not hold admin.
- Pushes by a Worker to its own branch can invalidate earlier approvals if stale-dismissal is on.

Auto-merge
([Automatically merging a pull request](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request),
[Managing auto-merge](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-auto-merge-for-pull-requests-in-your-repository)):

- The repository setting "Allow auto-merge" must be on. People with write permission can enable it per PR.
- The option appears only on PRs that cannot merge immediately, typically because a protection rule requires
  reviews or status checks. With no such rule the PR can simply be merged directly.
- It merges once all required reviews and checks pass.
- If a user **without** write access pushes to the head branch, auto-merge is disabled; pushes from write users do
  not. Worker accounts have write, so one Worker pushing to another's `agent/issue-<N>` branch would not disable it
  (relevant only if two Workers ever touch the same branch, which the claim is meant to prevent).
- The pages discuss branch protection rules only, not rulesets (unverified for rulesets).

Branch name collision. Branch `agent/issue-<N>` is hard-coded upstream (map #17). Because the name derives from the
issue number only, two Workers that both claimed the same issue would push to the same ref (fast-forward conflict
for the second). The branch name does not identify the Worker; identity shows in commit author and PR author.

## Open points for the spec

1. Confirm the Worker account model against ToS B.3 (one free machine account per person) and the plan's seat cost.
2. Test fine-grained PAT for non-member (outside collaborator) accounts on an org repo; fall back to classic `repo`.
3. Decide the review policy: human reviewer, cross-Worker approval, or no required reviews with auto-merge on checks.
4. Verify GraphQL `addAssigneesToAssignable` semantics and the auto-merge GraphQL permission (not on the fetched pages).
5. Add per-Worker poll jitter and conditional requests; honour `retry-after`.
