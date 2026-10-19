# How agent-dashboard handles several containers per repository

Research for lbacik/agent-forge#21 (child of map #17). Source read (read-only):
`/Volumes/Sources/python/ai/agent-dashboard`, `src/agent_dashboard/`. Paths below are relative to it.

## Answer in one paragraph

The dashboard has no notion of "repository" or "Pool" as a grouping. It discovers every container carrying the
role label, keys each one by its **Docker container name**, and renders one flat row per container. Several
Workers for one repository therefore already show up as several independent rows, with no dashboard change,
provided each container (a) has the role label and (b) has a distinct name on the Docker host. They are not grouped:
rows are sorted by attention rank, then name, so Workers of one Pool are not guaranteed to be adjacent.

## Discovery

- `gateway.py:22` `AGENT_ROLE_LABEL = "io.github.lbacik.simple-coding-agent.role=agent"`.
- `gateway.py:argv_list_instances` (about line 436) runs
  `docker ps -a --filter label=<role label> --format '{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Label "com.docker.compose.oneoff"}}'`.
  `-a` includes exited containers (shown as "not running", never exec'd).
- `gateway.py:parse_ps_output` (about line 547) drops rows whose `com.docker.compose.oneoff` is `True`
  (`docker compose run` containers), strips the leading `/` from the name, and skips empty names.
- The label must be on the container. agent-forge sets it as an image `LABEL` in
  `.agents/skills/create-agent/assets/Dockerfile.template:22`, so every service built from that image
  (including `worker-1..N`) inherits it. Nothing in the compose template overrides it.
- The docker host is whatever the dashboard's `docker` CLI points at (one host/context per dashboard process,
  ADR 0001/0002, README). Names only need to be unique per Docker host, which the daemon enforces.

## Keying and grouping

- Identity key = container name. `collector.py:_poll_one` returns `(instance.name, InstancePoll)`;
  `fleet.py:FleetState._entries` is `dict[name -> _InstanceEntry]`; `apply_cycle` keeps previous snapshot state only
  if the same name has the same container ID (a recreated container drops its old snapshot).
- Exec/attempt reads address containers by ID, never name (`gateway.py` `CONTAINER_ID_RE`, `argv_telemetry`).
- Row UI: `templates/_fleet_table.html:12-16` shows `row.name` plus `row.detail.repository_display`; drill-down URLs
  are `/instances/<name>` and `/?instance=<name>`; `app.py:find_row` matches `r.name == name`.
- The repository text comes from the telemetry snapshot (`snapshot.py:_stable_fields`, `identity.repository`),
  reported by the agent, not from any label or name. It is display-only, not a grouping key.
- Ordering: `fleet.py:snapshot` sorts by `(rank, name)`. `presentation.attention_rank` puts instances needing the
  operator first. No per-repository aggregation exists (overview/history are per instance).

## Several containers for one repository

- Works today: N containers with the label, N distinct names, N rows, each with its own telemetry, attempt log
  (read from that container's own `/data`) and reach. Each row displays the same repository string.
- Duplicate names cannot occur on a single Docker host (daemon-enforced). Two hosts would need two dashboards.
- Name collisions across a rename or recreate: same name + different container ID resets the row's snapshot; fine.
- Limits (cosmetic, no dashboard change needed to function): no Pool grouping or subtotal; Workers of one Pool can
  be interleaved with other instances by rank; the only visual cue tying Workers together is the name prefix and
  the repository text.

## Contract agent-forge must honour

1. Every Worker container carries `io.github.lbacik.simple-coding-agent.role=agent` (already true via the image
   `LABEL`; keep it in the Dockerfile template, do not move it to a per-service label that a service could omit).
2. Do not set `com.docker.compose.oneoff`; only `compose run` sets it, `up` services are fine.
3. Container names must be unique on the Docker host and should be readable and sortable as a Pool. Today the
   template sets no `container_name`, so Compose generates `<project>-<service>-<n>` where the project defaults
   to the instance directory name (`agent-<name>`). For services `worker-1..N` this yields
   `agent-<name>-worker-1-1`, which is unique and keeps Workers adjacent when ranks tie. Avoid fixed
   `container_name:` values copied across Instances, and avoid `deploy.replicas > 1` on a single service only if
   Worker identity per container is needed (it is, per the map), since replicas share one env/token.
4. `N=1` naming changes: today's single service is `agent`, giving `agent-<name>-agent-1`. If the service is
   renamed to `worker-1`, the container name changes for existing deployments (row resets, history under the old
   name vanishes from the dashboard until the volume's container is recreated; data in the volume is untouched).
   Keep the `N=1` service name `agent` or accept the rename knowingly.
5. The agent's snapshot `identity.repository` must be present (upstream already reports it) so rows show the
   repository; no Worker-specific field exists in the snapshot, so the name is the only Worker discriminator.

## Open points / not verified

- Whether upstream's snapshot `identity` could carry a Worker identity (GitHub login) so the dashboard could show it:
  would need an upstream and a dashboard change; the map puts dashboard changes out of scope.
- Behaviour was established by reading code, not by running a dashboard against a multi-service compose project.
- Compose naming rule (`<project>-<service>-<index>`) is Docker Compose behaviour, stated from knowledge of Compose;
  not re-verified against Compose docs in this note.
