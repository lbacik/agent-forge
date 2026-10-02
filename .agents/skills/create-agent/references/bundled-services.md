# Bundled services (database, cache, …)

Use this when the target's tests need a live service (CI `services:` block,
docker-compose test stack). The agent container has no Docker socket, so
sidecar containers are not an option: the service runs **inside the agent
image**. Full working example: `../simple-coding-agent-env/agent-jsonhub-api/` (MySQL + Redis).

## Shape

- Dockerfile installs the service binaries and `gosu`, stays `USER root`, and
  uses `agent-entrypoint.sh` as ENTRYPOINT.
- `agent-entrypoint.sh` (runs as root, `set -e`): before it execs the agent
  it must run `. /etc/agent-runtime.env` (the image's expected claude-code
  version, which the agent's startup provenance check reads):
  1. initialize the data dir on first start (ephemeral — not the `/data`
     volume; the profile resets state per attempt anyway),
  2. start the daemon bound to `127.0.0.1` in the background,
  3. wait until it answers,
  4. on first init, create the users/passwords CI uses,
  5. `exec gosu agent python -m simple_coding_agent`.
- Profile `setup:` waits for the daemon again (cheap, and guards against a
  restart race) and resets it to a clean state (drop/create database) — the
  role CI's ephemeral service containers play. It cannot start daemons: it
  runs as `agent`.
- Profile `env:` sets the connection vars CI sets (e.g. `DATABASE_URL`),
  pointing at `127.0.0.1`.

## Lessons from agent-jsonhub-api

- **Match the engine CI uses**, not a lookalike. MariaDB is not MySQL (its
  `JSON` is `LONGTEXT` + CHECK); a subtly different engine produces agent PRs
  that are green locally and red in CI.
- **arm64 hosts (Apple Silicon)**: vendor APT repos are often amd64-only
  (Oracle's MySQL APT repo has no arm64 for any Debian codename). Official
  Docker images are usually multi-arch — lift binaries with a
  `FROM <image> AS <name>-bin` stage and `COPY --from=`, including plugins,
  share/ data and any shared libs the base image doesn't have (check with
  `ldd`). Ask the user which architecture they deploy on if unclear.
- Taking a newer major for arm64 availability can change behaviour (MySQL 9
  dropped `mysql_native_password`) — document the drift from CI's version in
  the Dockerfile.
- MySQL `root@localhost` matches the Unix socket, not `-h127.0.0.1`; add a
  `root@%` grant for TCP. Services generally: be explicit about socket vs TCP.
- PHP-style stacks: install every extension the app needs to *boot*, not just
  to test (`composer install` scripts run `cache:clear`), plus zip/unzip so
  Composer uses dist archives.
