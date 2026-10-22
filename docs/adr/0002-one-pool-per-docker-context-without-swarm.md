# A Pool is one Compose project on one Docker context, without Swarm

Every Worker of a Pool needs its own `/data` volume (upstream state is single-slot and has no inter-process locks) and its own Worker id, so Workers cannot be identical replicas. Docker Swarm services (and `docker compose --scale`) can only express identical replicas, so a Pool is one Instance directory and one Compose project with one service per Worker (`agent`, `agent-2..N`), running on one Docker context (plain Docker Engine, local or over SSH) with one model backend. Spreading work over several hosts is done with several Instances working one Queue, not with one Pool spanning hosts.

## Considered Options

- **Docker Swarm services**: would let one Pool span several hosts, but needs a Swarm on the remote engines, and replicas share configuration, so per-Worker volumes and ids would need per-replica templating or one Swarm service per Worker, which gains nothing over Compose services on one host.
- **`docker compose --scale`**: replicas share one volume definition and one environment, so they would share `/data` and `WORKER_ID`.

## Consequences

- One Pool has one Docker context and one model backend; `create-agent` and `manage-pool` state it.
- Workers on different hosts or backends belong to different Instances. They may take issues from one Queue (the Claim settles between them), but they are not one Pool and are not managed together.
- Adding a Worker means adding a service stanza by hand; there is no generator.
