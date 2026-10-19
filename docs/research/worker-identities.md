# Obtaining N Worker identities within GitHub's terms

Research for lbacik/agent-forge#31 (child of map #17). It builds on #20 ("GitHub side of a Pool",
`docs/research/github-pool-constraints.md` on branch `research/github-pool-constraints`) and does not repeat it.
Sources are GitHub's Terms of Service, docs.github.com, github.com/pricing and GitHub's published GraphQL schema
(`https://docs.github.com/public/fpt/schema.docs.graphql`), all fetched 2026-10-19. Upstream code was read at
simple-coding-agent `9c75f94`. Nothing was created or changed on GitHub; the "observed" items come from read-only
API queries.

Labels used below:

- **Verified**: quoted from a GitHub primary source, or observed in a read-only API response.
- **Inference**: my reading of verified facts; not stated by GitHub.
- **Unverified**: not settled by any source fetched; needs a test or a question to GitHub Support.

## Answer in short

| Option | ToS standing | Claim (assign) | Labels, comments, push, PR | Auto-merge | Credential | Upstream change |
|---|---|---|---|---|---|---|
| A. One free machine account per **different human** | Allowed (each human: 1 free machine account) | Works (user with write) | Works | Works (write) | Classic PAT `repo` (collaborator) | None beyond #18/#19 |
| B. Machine accounts on a **paid plan** (GitHub Pro), all owned by one human | Wording caps only *free* accounts; paid ones are not capped (inference, confirm with Support) | Works | Works | Works | Classic PAT `repo` | None beyond #18/#19 |
| C. Machine accounts as **paid org seats** | Unclear: the accounts themselves stay free personal accounts (inference) | Works | Works | Works | Fine-grained PAT (org member) | None, but repo must move to an org |
| D. **Enterprise Managed Users** | Sanctioned: the enterprise creates the accounts | Works | Works | Works | PAT of a managed user | None, but repo must live in the enterprise |
| E. **One GitHub App per Worker** (installation tokens) | Allowed; Apps are not accounts and use no seat | **Unverified for a generic App bot** | Documented for installation tokens | Unverified | App ID + private key + installation ID, 1 h tokens | Token minting/refresh, login/ID handling, maybe a new Claim |

In one line: the ToS-clean routes that need no upstream change are **A** (one free machine account per distinct
accountable human) and **B** (paid personal machine accounts, pending a Support confirmation of the reading); **E**
(GitHub Apps) is clearly within the terms and costs nothing, but whether a generic App's bot can hold the Claim (be
the issue's assignee) is not documented and must be tested before it can be chosen, and it needs real upstream work.
**C** does not by itself fix the free-account cap, and **D** is sanctioned but expensive and moves the repository.

## 1. What the Terms of Service actually say

[GitHub Terms of Service](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service), section B.3
"Account Requirements" (**verified**, verbatim):

> You must be a human to create an Account. Accounts registered by "bots" or other automated methods are not
> permitted. We do permit machine accounts:
>
> A machine account is an Account set up by an individual human who accepts the Terms on behalf of the Account,
> provides a valid email address, and is responsible for its actions. A machine account is used exclusively for
> performing automated tasks. Multiple users may direct the actions of a machine account, but the owner of the
> Account is ultimately responsible for the machine's actions. You may maintain no more than one free machine
> account in addition to your free Personal Account.
>
> One person or legal entity may maintain no more than one free Account (if you choose to control a machine account
> as well, that's fine, but it can only be used for running a machine).
>
> Your login may only be used by one person — i.e., a single login may not be shared by multiple people. A paid
> Organization may only provide access to as many Personal Accounts as your subscription allows.

The B "short version" says "you may not have more than one free Account". Section H (API Terms) adds "You may not
share API tokens to exceed GitHub's rate limitations" (**verified**).

The ToS does not define "free" beyond the plan, and section A defines "Account" broadly (personal accounts and
organizations). GitHub's own docs call such accounts "machine users": "User accounts are intended for humans, but
you can create accounts to automate activity on GitHub. This type of account is called a machine user"
([Types of GitHub accounts](https://docs.github.com/en/get-started/learning-about-github/types-of-github-accounts),
**verified**).

**Inference.** The cap is on *free* accounts per *person or legal entity*: one free personal account plus one free
machine account. Nothing in B.3 caps *paid* machine accounts or machine accounts owned by different accountable
humans. Each machine account still needs a human who accepts the Terms, gives a valid email and is responsible.

## 2. Option A/B: machine (user) accounts

**ToS.** A: each of N humans may hold one free machine account, so N Workers need N accountable people (for this
project, realistically 1-2 Workers per person). B: a single owner with N-1 extra machine accounts would need those
extra accounts on a paid personal plan. GitHub Pro is the paid personal plan
([GitHub's plans](https://docs.github.com/en/get-started/learning-about-github/githubs-plans), **verified**); its
price is not on the pages fetched (**unverified**). That paid machine accounts are outside the cap is an
**inference** from the "free" wording; confirm with GitHub Support before relying on it.

**Access on a personal-account repository** (the targets here are owned by `lbacik`). Collaborators "can pull (read)
the contents of the repository and push (write) changes", and can "Create, assign, close, and re-open issues",
"Manage labels", "Create, merge, and close pull requests", "Enable and disable auto-merge for a pull request"
([Permission levels for a personal account repository](https://docs.github.com/en/account-and-profile/reference/permission-levels-for-a-personal-account-repository),
**verified**). Collaborators on private personal repos always get write ("Collaborators can't have read-only
access"). The owner must invite each account and the account must accept (from #20). Free personal accounts allow
"unlimited collaborators" on public and private repos (GitHub's plans, **verified**), so there is no seat cost on
the repository side.

**Token shape, settling #20's open point.** Fine-grained PATs are "limited to access resources owned by a single user
or organization", and their listed gaps include "Using fine-grained personal access token to contribute to
repositories where the user is an outside or repository collaborator"; "Outside collaborators can only use personal
access tokens (classic) to access organization repositories that they are a collaborator on"
([Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens),
**verified**). So a Worker account that is a **collaborator** (not the owner) needs a **classic PAT with `repo`**
scope. The `create-agent` template (`.env.example`) currently asks for a fine-grained PAT, which only fits the case
where the token's account owns the repository. Classic `repo` reaches every repository the machine account can
access, which is acceptable only because a dedicated machine account is invited to nothing else (**inference**).
Unused tokens are removed after a year; set an expiry (same page, **verified**).

**Claim, labels, push, PR, auto-merge.** All work as today: the Worker identity is a `User` with write, which is
assignable ("anyone with write permissions to the repository",
[Assigning issues and pull requests](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/assigning-issues-and-pull-requests-to-other-github-users),
**verified**). Rate limits are per account (from #20).

**Upstream.** No identity-related change: `GitHubGraphQLTransport` reads `viewer { id login }` and assigns
`viewer.id` with `addAssigneesToAssignable` (`simple_coding_agent/github_tracker.py:473-490`). Only the Pool
changes already decided in #18 (claim settle-and-yield) and #19 (`PEER_LOGINS`) apply.

**agent-forge.** One `GITHUB_TOKEN` per Worker in a per-Worker env file (as the map already plans); the
`.env.example` comment must say "classic PAT, `repo` scope" for collaborator accounts. Commit author stays
"Claude Code" (Dockerfile template); the pushing account identifies the Worker.

## 3. Option C/D: organization seats and Enterprise Managed Users

**Org seats (C).** GitHub Team bills "Organization members, including owners" and "Outside collaborators on private
repositories owned by your organization"
([People who consume a license](https://docs.github.com/en/billing/concepts/product-billing/github-licenses),
**verified**). Team is "$4 USD per user/month", Enterprise "Starting at $21 USD per user/month"
([github.com/pricing](https://github.com/pricing), **verified**). GitHub Free for organizations also allows
"unlimited collaborators" ([GitHub's plans](https://docs.github.com/en/get-started/learning-about-github/githubs-plans),
**verified**).

**Inference.** A paid seat is paid by the organization; the member's own personal account is still on the free
plan. B.3's cap is about how many *free Accounts* a person maintains, so buying seats does not obviously make N
machine accounts owned by one person compliant. No page fetched says that org seats are the sanctioned route for
machine users (**unverified**; ask Support). What org membership does change is the token shape: members can use
**fine-grained PATs** with the org as resource owner (org approval may be required; a pending token can "only be able
to read public resources", same PAT page, **verified**). The repository would have to be transferred to an org.

**Enterprise Managed Users (D).** "If your account was created for you by an enterprise on GitHub Enterprise Cloud,
you are using a managed user account"; managed users "cannot create public content or contribute to repositories
outside the enterprise" ([Types of GitHub accounts](https://docs.github.com/en/get-started/learning-about-github/types-of-github-accounts),
**verified**). **Inference:** accounts provisioned by the enterprise are not "free Accounts" maintained by a person,
so this is the cleanest licensed route to many user identities, at Enterprise pricing per seat and only for
repositories inside that enterprise. Out of proportion for this project.

**Upstream / agent-forge.** Same as A/B (user identities, PAT per Worker).

## 4. Option E: one GitHub App per Worker

**ToS and cost.** A GitHub App is not an Account, and "unlike a user, a GitHub App does not consume a GitHub seat";
"GitHub Apps can act independently of a user"
([Deciding when to build a GitHub App](https://docs.github.com/en/apps/creating-github-apps/about-creating-github-apps/deciding-when-to-build-a-github-app),
**verified**). "A user or organization can register up to 100 GitHub Apps, but there is no limit to how many GitHub
Apps can be installed on an account"
([Registering a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app),
**verified**). A private App can be installed "Only on this account"
([Installing your own GitHub App](https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app),
**verified**), i.e. on `lbacik`, scoped to the target repository.

**Identity.** Each App acts through one `Bot`: "A special type of user which takes actions on behalf of GitHub Apps"
(GraphQL schema, **verified**). One App therefore yields exactly one identity; N Workers need N Apps (**inference**,
since every installation of the same App acts as the same bot). Observed (read-only): REST `GET
/users/github-actions%5Bbot%5D` returns `login: "github-actions[bot]"`, `type: "Bot"`, node id `MDM6Qm90NDE4OTgyODI=`;
in GraphQL the same bot appears as comment author with `__typename: "Bot"`, `login: "github-actions"` (no `[bot]`
suffix), and `user(login: "github-actions[bot]")` does not resolve. **The login string of a bot differs between REST
and GraphQL fields (verified by observation).**

**What `viewer` returns for an installation token.** GitHub's own example runs `viewer { login }` with an
installation token
([Authenticating as a GitHub App installation](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation),
**verified** that the query is valid), but no page states the value. The schema types `viewer` as `User!` ("The
currently authenticated user") and notes that `viewerPermission` "Will return null if authenticated as an GitHub
App" (**verified**). Community sources expect `viewer.login` to end in `[bot]`
([gist](https://gist.github.com/jitran/df20608b044c3eed5696ea13e9bae604)); **unverified**, and so is whether
`viewer.id` is the `Bot` node id that `addAssigneesToAssignable` accepts.

**Claim (assignment): the deciding unknown.**

- The schema now accepts bots: `AddAssigneesToAssignableInput.assigneeIds` is "The ids of actors (users or bots) to
  add as assignees" with possible types `Bot, EnterpriseUserAccount, Mannequin, Organization, User`;
  `replaceActorsForAssignable` takes `actorLogins` and says "For bots, use the login format with [bot] suffix (e.g.,
  'my-app[bot]')" (GraphQL schema, **verified**).
- `Assignable` has `assignees: UserConnection!` ("A list of Users assigned") and a newer `assignedActors:
  AssigneeConnection!` (union `Bot | Mannequin | Organization | User`) (**verified**).
- The documented assignability rule names only people: "yourself, anyone who has commented on the issue or pull
  request, anyone with write permissions to the repository, and organization members with read permissions"
  ([Assigning issues](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/assigning-issues-and-pull-requests-to-other-github-users),
  **verified**). The only documented assignable bots are Copilot and "agent apps": partner Apps from the Marketplace
  with "agent features" enabled, powered by Copilot cloud agent and billed to Copilot, in public preview
  ([Agent apps](https://docs.github.com/en/copilot/concepts/agent-capabilities/about-agents/agent-apps),
  [changelog 2026-06-02](https://github.blog/changelog/2026-06-02-extend-github-with-agent-apps/), **verified**).
  Agent apps run on GitHub's infrastructure, so they are not a way to give self-hosted Workers an identity.
- Observed (read-only) on a public issue assigned to Copilot
  (`frkim/oss-ai-platform#10`): `assignees` lists `login: "Copilot"`, `assignedActors` lists `Bot` with `login:
  "copilot-swe-agent"`. The REST check `GET /repos/{o}/{r}/assignees/Copilot` returns 404 on that same repo, and
  404 for `github-actions[bot]` on `lbacik/agent-forge`, so that check cannot be used to judge bot assignability.

**Inference.** The API surface is ready for bot assignees, but no page says that a self-registered App's bot is an
eligible assignee. **Whether `addAssigneesToAssignable` with the App's own bot id succeeds (rather than erroring or
being silently ignored, as REST does for ineligible assignees) is unverified and is the gating test for option E.**
If it fails, the Claim as defined in `CONTEXT.md` ("held while its Worker identity is the issue's only assignee")
cannot be held by an App, and the Pool would need a different Claim marker (for example a per-Worker label or a
claim comment), which is a larger upstream redesign.

**Labels, comments, push, PR (verified for installation tokens).** The permission tables mark "IAT" (installation
access token) for `POST/DELETE .../issues/{n}/assignees`, `POST .../issues/{n}/comments`, `POST/PUT/DELETE
.../issues/{n}/labels` (Issues or Pull requests: write), `POST /repos/{o}/{r}/pulls` (Pull requests: write),
`git/refs` and `pulls/{n}/merge` (Contents: write)
([Permissions required for GitHub Apps](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps)).
Git over HTTPS: "use the installation access token as the HTTP password ... `https://x-access-token:TOKEN@...`"; the
App needs Contents (same installation page, **verified**). Upstream's askpass already answers `x-access-token` as
the username (`git_workspace.py:905-915`), so git push works unchanged with an installation token. Pushing changes to
`.github/workflows` needs the Workflows permission (**inference** from #20). PRs and pushes made with an
installation token do trigger workflows (only the Actions `GITHUB_TOKEN` suppresses them;
[Triggering a workflow](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow),
**verified**).

**Auto-merge.** "People with write permissions" can enable it (#20). Apps have permissions, not roles; whether
`enablePullRequestAutoMerge` accepts an installation token with Contents + Pull requests write is **unverified**.

**Token lifetime.** "The installation access token will expire after 1 hour"; it is minted by `POST
/app/installations/{id}/access_tokens` with a JWT signed by the App's private key, can be narrowed to repositories
and permissions, and since 2026-04-27 may use the longer `ghs_APPID_JWT` format
([Generating an installation access token](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app),
**verified**). A Worker's attempt can exceed one hour (`MODEL_TIMEOUT` defaults to 3600 s), so the Worker must
re-mint tokens itself (**inference**).

**Rate limits.** Per installation: 5,000 requests (REST) / 5,000 points (GraphQL) per hour, scaling above 20
repositories or org users up to 12,500; 15,000 / 10,000 on Enterprise Cloud
([REST rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api),
[GraphQL limits](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api),
**verified**). One App per Worker with one installation each gives each Worker its own budget, same as user
accounts. Secondary limits from #20 apply.

**What simple-coding-agent would need (inference from reading `9c75f94`).**

1. **Credential and refresh.** Today `GITHUB_TOKEN` is required (`config.py:162`) and passed as a fixed string to
   `GitHubGraphQLTransport` (`__main__.py:75`), which sends it on every request. `GitWorkspace` already takes a
   `token_provider` callable (`__main__.py:79`, `git_workspace.py:840`), but it returns the constant. Needed: an
   App mode (`GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, private key from a mounted file) with a provider that
   signs the JWT, mints and caches an installation token, renews it before expiry, and is used by both the GraphQL
   transport and git.
2. **Redaction.** `credential_redactions` is a static tuple of config values (`config.py:135-142`); rotating tokens
   (and the private key) must be redacted as they are minted.
3. **Identity comparisons.** Every self-check compares `viewer.login` with a login read elsewhere: `is_self_assigned`
   and the release paths against `assignees { login }`, `trusted_comments` and `automatic_continuation_count`
   against `author { login }` (`github_tracker.py:263-404`). For a bot, `author.login` is the bare slug
   (observed), `viewer.login` probably has `[bot]` (unverified), and a bot assignee may appear under `assignees`
   with a display login (observed for Copilot) or only under `assignedActors`. Comparisons should move to node
   ids, or normalise the `[bot]` suffix, and the issue query should read `assignedActors` (with `... on Bot` /
   `... on User`) instead of `assignees`. `PEER_LOGINS` from #19 would hold bot logins and needs the same
   normalisation.
4. **Claim.** If bot assignment is refused, a non-assignment Claim (see above), which changes the #18 design.
5. **Commit author.** Optional: set the App's bot noreply address so commits show the bot (format
   `<id>+<slug>[bot]@users.noreply.github.com` per community sources, **unverified** in GitHub docs).

**agent-forge.** Per-Worker env with `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID` and a private-key file mounted
read-only (Compose `secrets` or a bind mount) instead of `GITHUB_TOKEN`; N Apps registered under `lbacik`, each
installed only on the target repository with Contents, Issues, Pull requests (and Workflows if needed) write;
`create-agent` validation would check App installation instead of PAT scopes.

## 5. Other documented mechanisms, and why they do not give N identities

- **GitHub App user access tokens** (App acting "on behalf of a user", rate-limited as that user,
  [About creating GitHub Apps](https://docs.github.com/en/apps/creating-github-apps/about-creating-github-apps/about-creating-github-apps)):
  the identity is the user, so this needs N users again.
- **Actions `GITHUB_TOKEN`**: one installation-scoped identity (`github-actions[bot]`) per repository; not N, and
  only inside workflow runs.
- **Copilot / agent apps**: assignable bots, but they run GitHub's own agent, not self-hosted Workers (section 4).
- **Deploy keys**: per-repository SSH keys for git only; no API identity, cannot assign, label or open PRs
  (**inference**, not re-checked here).
- **One shared machine account for all Workers**: ToS-clean ("Multiple users may direct the actions of a machine
  account", **verified**), but the map lists shared-token identity as out of scope, and #20 shows it shares one
  rate-limit budget. Noted only for completeness.

## 6. Unverified, and how to settle it

1. **Bot as assignee (gates option E).** With a throwaway private App installed on a test repository: mint an
   installation token, run `viewer { id login }`, then `addAssigneesToAssignable` with that id on a test issue, and
   read back `assignees` and `assignedActors`. Expect one of: success, GraphQL error, or silent no-op.
2. `viewer.login` / `viewer.id` for an installation token (same test).
3. `enablePullRequestAutoMerge` with an installation token, and with a classic PAT of a collaborator (#20 left the
   fine-grained case open too).
4. ToS reading of paid machine accounts (option B) and whether paid org seats lift the free-account cap (option C):
   ask GitHub Support; the ToS text alone does not settle either.
5. GitHub Pro price (not on the pages fetched).
6. Bot commit-author email format (community-sourced only).
