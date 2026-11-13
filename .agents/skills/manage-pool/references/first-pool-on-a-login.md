# A login's first N>=2

Read this when a Worker identity goes from one Worker to two or more (a
second Worker for an Instance whose Workers have no Worker id yet, or a
Worker on a login another Instance already uses), or when Workers that share
a login need a newer upstream. Decided in agent-forge#34. This file is the
single source of the hard rule, the minimum upstream and the order;
`create-agent` applies them to new Instances. Commands follow the
conventions of `SKILL.md`, section 1.

## Hard rule

Never run Workers of different Claim protocol versions on one Worker
identity. A Worker without `WORKER_ID`, or older than `v0.7.0`, compares only
the login, so it takes another Worker's Claim for its own; a Worker that gains
`WORKER_ID` while holding a Claim without a Claim marker no longer recognises
it as its own. Hence every Worker on the login switches together, with intake
stopped and no Claim held.

## Minimum upstream

- A Worker id needs `AGENT_SRC_REF` `v0.7.0` or newer, the Pool release of
  lbacik/simple-coding-agent#302.
- N>=2 Workers on one Worker identity need `v0.9.0` or newer, the first
  release with the startup recovery fix of lbacik/simple-coding-agent#364.
  Earlier tags can leave a Worker unable to start, with its Claim marker
  behind, when its Claim is gone.

Ask the user which ref to move to: a tag `v0.9.0` or newer, or `main`
(whose current upstream is newer). Verify the result on the running Workers,
never from the ref alone: the `agent version:` line of `/usr/local/bin/agentctl status`.

## Procedure

Each step finishes on every Worker before the next one starts.

1. **Every Worker on the login.** This Instance's Workers on the shared env
   file, plus other Instances on the same repository, listed by file name
   so no token is read (count each directory once; `.env.example` matches
   too):

   ```bash
   grep -liE "^TARGET_REPO=[\"']?<owner>/<repo>[\"']?[[:space:]]*$" agent-instances/*/.env*
   ```

   For each other Instance, ask the user whether it acts as the same login
   and on which context it runs. Never compare or print tokens. The login
   itself, printing only the name:

   ```bash
   GH_TOKEN=$(grep -E '^GITHUB_TOKEN=' <env file> | cut -d= -f2- | tr -d "\"'") gh api user -q .login
   ```

2. **Drain** (`SKILL.md`, section 2) every Worker of step 1, in every
   Instance, each on its own context. Then
   `gh issue list --repo <TARGET_REPO> --assignee <login> --state open`
   must be empty. An assignment left with no active attempt behind it is
   stale: the user clears it by hand. Go on only with an empty list.
3. **Upgrade all at once.** In every Instance of step 1: set
   `AGENT_SRC_REF` in its env file, give every Worker on the login its
   Worker id block (`WORKER_ID: <short-name>-<n>`, and
   `Claude Code (<short-name>-<n>)` in `GIT_AUTHOR_NAME` and
   `GIT_COMMITTER_NAME`; the first Worker is `<short-name>-1`), run
   `docker compose config -q`, `docker compose build` and
   `docker compose up -d`. The recreated Workers keep intake stopped (it
   lives on `/data`). Check on each: `agent version:` at the chosen release
   or newer, and `git var GIT_AUTHOR_IDENT` naming its Worker id.
4. **Resume.** `/usr/local/bin/agentctl resume` on every upgraded Worker.
5. **Only then add Workers**, from step 2 of "Add a Worker" in `SKILL.md`.

An Instance of step 1 that lives on another context is changed there with
this skill too; until steps 2-3 are done for it, no new Worker starts on the
login.
