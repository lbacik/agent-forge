# A Worker with its own Worker identity

Read this when a Worker should act as its own GitHub account instead of the
shared login, or when such a Worker is removed. The layout is the one
`create-agent/references/pools.md` describes ("Worker identities"): the
first Worker `agent` always uses the shared env file; Worker `agent-<n>`
adds `.env.worker-<n>`, which holds only its `GITHUB_TOKEN` and overrides the
shared one.

## Adding

1. **Number** as in `SKILL.md`, "Add a Worker", step 3.
2. **Token file.** `.env.worker-<n>` in the instance directory, one line
   `GITHUB_TOKEN=<token>`, mode 600. The user writes it, or names a file to
   copy it from; copy with shell tools so the token never reaches the
   output.
3. **Token access.** The check of `create-agent/SKILL.md`, step 6, with the
   token read from `.env.worker-<n>`. Contents, pull requests and issues need
   read & write.
4. **Login.** Print only the name:

   ```bash
   GH_TOKEN=$(grep -E '^GITHUB_TOKEN=' .env.worker-<n> | cut -d= -f2- | tr -d "\"'") gh api user -q .login
   ```

   If another Worker already acts as this login, the Worker shares an
   identity: both need Worker ids, and `first-pool-on-a-login.md` applies
   when that login has no Worker ids yet.
5. **Stanza** as in `SKILL.md`, "Add a Worker", step 4, keeping the
   long-syntax `env_file` list with `path: .env.worker-<n>` and
   `required: false` (Docker Compose v2.24+). A Worker whose identity no
   other Worker shares needs no Worker id: delete its Worker id block.
6. **`PEER_LOGINS`.** Workers with different logins on one Queue need
   `PEER_LOGINS` (`AGENT_SRC_REF` v0.6.0+) in the shared env file, listing
   the logins of all of them, including other Instances on `TARGET_REPO`
   (each of those sets it in its own env file). If the shared env file
   already lists the new login, skip to step 7. Otherwise warn the user
   first: editing the shared env file changes every Worker's environment, so
   `docker compose up -d` recreates every Worker, and a recreated Worker
   loses its active attempt. With their go-ahead:
   1. `agentctl stop` on every running Worker; wait until each `status`
      shows `active_attempt: none`.
   2. Set `PEER_LOGINS` in the shared env file.
   3. `docker compose config -q`, then `docker compose up -d` (this also
      starts `agent-<n>`).
   4. `agentctl resume` on every Worker that was running before step 1.
7. **Start** (when step 6 was skipped): `docker compose config -q`, then
   `docker compose up -d agent-<n>`.

Done when `pool-status.sh` shows `agent-<n>` running and the Worker acts as
its own login:

```bash
DOCKER_CONTEXT=<ctx> docker compose exec -u agent agent-<n> sh -c \
  'curl -s -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user | jq -r .login'
```

If the image lacks `curl`, report this check as not run.

## Removing

Follow `SKILL.md`, "Remove a Worker"; its Claim check includes the
assignments of this Worker's login. Afterwards:

- `.env.worker-<n>` holds a token: ask the user whether to delete it, and
  remind them that revoking the token on GitHub is theirs to do.
- Leave `PEER_LOGINS` as it is: the removed Worker's result and handoff
  comments stay on issues other Workers may continue, and editing the shared
  env file would recreate every Worker.
