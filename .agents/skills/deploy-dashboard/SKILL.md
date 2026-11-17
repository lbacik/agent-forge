---
name: deploy-dashboard
description: Deploy, upgrade or check an agent-dashboard (the web fleet view) on one Docker context, in this agent-forge project (`dashboards/<context>/`), and manage its Operator accounts and sign-in access. Use this whenever the user wants a dashboard for the agents on a host, e.g. "deploy the dashboard on rpi5", "postaw dashboard na orbstacku", "upgrade the dashboard to v0.6.0", "add a controller account", "how do I open the rpi5 dashboard", "the dashboard shows permission denied".
---

# deploy-dashboard

One dashboard deployment serves exactly one Docker context: it lists the
labelled Managed Instances on that daemon through the mounted Docker socket.
It lives in `dashboards/<context>/` (git-ignored), never under
`agent-instances/`; `agent-instances/agent-dashboard/` is the coding agent
*for* the agent-dashboard repository, a different thing. Terms (Dashboard
deployment, Instance, Managed Instance) are defined in `CONTEXT.md`.

Every step runs the bundled helper; its commands, options and exit codes are
in the script's header comment:

```bash
.agents/skills/deploy-dashboard/scripts/dashboard.sh [--context <ctx>] init|up|upgrade|account|tunnel|status|down …
```

## Ground rules

- **Build and start on request.** `up` and `upgrade` build an image on the
  target daemon and (re)create the container. Run them when the user asked
  for a deployment or upgrade, or authorized it earlier; otherwise stop
  after `init` and say what `up` will do.
- **The Set-password link is a one-time credential.** `account add` and
  `account reset` print it to the operator's terminal. Hand it to the
  operator only; leave it out of reports, commits, issue comments and
  memory. In your report, say that a link was issued and how long it works.
- **The `state` volume holds the Operator accounts and the Control audit.**
  `down` and `upgrade` keep it. Deleting it (`docker compose down -v`,
  `docker volume rm`) happens only on the user's explicit authorization,
  after restating what is lost.
- **Pinned upstream.** `--ref` is a release tag or a full 40-character
  commit SHA of lbacik/agent-dashboard. Pick the latest tag unless the
  user names one (`git ls-remote --tags --sort=-v:refname
  https://github.com/lbacik/agent-dashboard.git | head -n 1`).
  The helper rejects branches and short SHAs, and `up` refuses to build
  while `.upstream-ref` and `DASHBOARD_REF` differ; fix that with
  `upgrade --ref`, never by editing one side.

## 1. Confirm the target context

Name the Docker context and show its endpoint
(`docker context inspect <ctx> --format '{{.Endpoints.docker.Host}}'`). The
helper defaults to `orbstack`; pass `--context <ctx>` on every call and use
the same context throughout. If `dashboards/<ctx>/.env` already exists, this
is an upgrade or a check, not a new deployment: go to section 4 or 5, or
re-run `init --force` only when the user wants a different profile (the
state volume survives).

## 2. Choose the access profile with the user

| Profile | Use | Sign-in, Control | Operators open |
|---|---|---|---|
| `local` (default on `orbstack`) | Workstation | LAN mode on: sign-in, Control available | `http://localhost:<port>` |
| `tunnel` (default elsewhere) | Remote host without proxy or certificates | LAN mode on: sign-in, Control available | `http://localhost:<local-port>` through the SSH tunnel `tunnel` prints |
| `lan` | Other LAN devices through a TLS reverse proxy on the same host (`--proxy-network`, `--virtual-host`, optional `--letsencrypt-host`) | LAN mode on: sign-in, Control available | `https://<virtual-host>` |
| `readonly` | Trusted, isolated network (`--bind <lan-ip>`, `--host <names>`) | No sign-in, Control off | `http://<lan-ip>:<port>` |

Passwords are accepted only from a secure context, which is why `tunnel`
signs in through `http://localhost` and `lan` through HTTPS. For `lan`, the
proxy network must already exist on the context; the helper checks it at
`init` and again at `up`, and certificates stay the operator's job. For
`readonly`, tell the user plainly: anyone who can reach the port sees the
whole fleet. Unauthenticated Control is always written off.

## 3. Deploy

1. `init --ref <tag|sha> --profile <p> [profile options]`. It validates the
   ref, reads `DOCKER_GID` on the target daemon, fetches the upstream
   compose files and writes `.env`. Done when it prints `initialised`.
2. `up` (on request, see the ground rules). It builds on the target daemon
   and waits for the upstream `/healthz` healthcheck. Done when it prints
   `dashboard up`.
3. `status`. Done when it exits 0: container running and healthy, the
   startup line shows the expected LAN mode and Host check, and the Docker
   socket is readable from inside the container.
4. First account (every profile except `readonly`):
   `account add <name> --role controller`. The helper adds `--url` for the
   profile's address. Give the link to the operator (ground rules).
5. `tunnel` profile: run `tunnel` and give the operator the printed
   `ssh -L …` command; the Set-password link opens through it.

## 4. Upgrade

`upgrade --ref <tag|sha>` keeps `.env` (only `DASHBOARD_REF` changes) and
the state volume, then rebuilds and recreates. Walk the user through the
variables it reports: `new` ones may need a value in `.env`, `removed` ones
are dead there. Then run `status`.

## 5. Check and troubleshoot

`status` is read-only. What it flags:

- `docker socket: permission denied` → `DOCKER_GID` in `.env` does not match
  the socket group on the target daemon. Re-detect it with the command
  `status` prints, set it in `.env`, then `up`.
- `legacy containers (not shown by the dashboard)` → unlabelled instances on
  that context, from debug-agent's `fleet.sh`. They are expected to be
  missing from the dashboard; name them to the user.
- Build failure in `up`, or a container that is not running or unhealthy →
  read the build output or `docker --context <ctx> compose logs dashboard`
  from `dashboards/<ctx>/`. A failure inside upstream's `Dockerfile` or
  compose file is an agent-dashboard bug: report it there (or pin a ref
  that has the fix) rather than patching the deployment, since the overlay
  changes only the build source.

`account reset|role|remove|list` manage accounts later; `down` stops the
dashboard and keeps the state volume.

## 6. Report

Tell the user, in their language:

- the context, profile, ref and the address operators open (and the tunnel
  command for `tunnel`);
- which accounts exist and that a Set-password link was handed over, never
  the link itself;
- which checks ran, which passed and which remain unverified (for example
  sign-in and Control actions through the tunnel, or HTTPS through the
  proxy, which only a browser shows);
- any legacy containers the dashboard will not show.

The helper's regression suite (stubbed Docker, curl and git; no host, no
network) runs in CI and locally:

```bash
.agents/skills/deploy-dashboard/tests/dashboard-helpers.sh
```
