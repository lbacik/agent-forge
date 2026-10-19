# Workers per host: footprint of one Worker and host sizing

Research for issue #22 (child of map #17). Read-only; collected 2026-10-19.
Sources are local and first-party: instance files in `agent-instances/`, the
remote-attempt log cache `~/.cache/simple-coding-agent-env/rpi5/*/logs/`
(62 `attempt.json` files, 2026-09-25 to 2026-10-15), the `docker` CLI
(`info`, `ps`, `stats --no-stream`, `system df`) and the upstream checkout
`/Volumes/Sources/python/ai/simple-coding-agent`.

## Summary

- A Worker is light on the host while the model thinks and bursty while the
  target's setup/check commands run. Peak memory of a Worker was **not
  measured** (see Gaps); the numbers below for memory limits are proposals.
- Disk per Worker is dominated by its clone plus toolchain deps (about 0.5 GB
  for a Node target); the image (1.0-1.4 GB) is shared by all Workers of one
  Instance.
- Model concurrency is the real ceiling: every Worker is an independent
  Claude-SDK session using about 7M tokens (mostly cache reads) per long attempt.
- Proposed defaults: `cpus: 1.5`, `mem_limit: 3g`, `pids_limit: 1024` per Worker.
  Pool size: rpi5 2 (3 with no other heavy services), local OrbStack 2, gin unknown.

## Hosts

| Host | CPUs | RAM | Reachable | Notes |
|---|---|---|---|---|
| orbstack (local) | 4 | 11.7 GiB (12,600,442,880 B) | yes | no agent container running at collection time |
| rpi5 (ssh, aarch64, Debian 13) | 4 | 15.8 GiB (17,006,837,760 B) | yes | already runs 1 Worker plus LiteLLM, Postgres, dashboard, Beszel, Portainer |
| gin (ssh) | ? | ? | **no** | `docker info` returned empty (0 CPUs / 0 bytes) within 25 s; unverified |

## Observed cost of one Worker

### CPU and processes

- rpi5, `docker stats --no-stream`: `agent-simple-rpg-engine-agent-1` showed
  12.4% CPU and 146 PIDs at the moment of sampling (one sample, mid-run or
  idle poll unknown). Neighbouring services: LiteLLM 0.11% / 17 PIDs,
  Postgres 0.01% / 11 PIDs, dashboard 0.12% / 2 PIDs.
- The same sample reports memory as `0B / 0B` for every container on rpi5:
  the host's cgroup memory accounting is not exposing usage to `docker stats`,
  so **per-container RSS on rpi5 is unavailable** this way.
- The compose templates set no `cpus`, `mem_limit` or `pids_limit`
  (`agent-instances/*/compose.yaml`); only `init: true` and `ulimits.core: 0`.
  `init: true` exists because orphaned tool processes become zombies and
  exhaust `pids.max` (`.agents/skills/debug-agent/references/log-layout.md`,
  "Diagnosing pids exhaustion"). A `pids_limit` must therefore sit well above
  the observed 146 and is not a substitute for tini.
- Bursts come from the target's commands (npm/composer/pytest, bundled MySQL and
  Redis in `agent-jsonhub-api`). An unbounded Node build froze the Mac (user
  memory note "OrbStack heavy builds"), so the limit matters most on
  OrbStack for Node targets.

### Duration and activity (62 attempts, 8 Instances, remote cache)

- Attempt duration: median 508 s, p90 1,262 s, max 2,375 s; total 10.0 h of
  wall time over about 3 weeks (15 distinct days).
- Outcomes: complete 12, handoff 9, incomplete 29, infrastructure_error 9,
  no_changes 1, unreadable 2.
- A Worker spends most of an attempt waiting on the model; the host load is
  therefore low on average and spiky during setup, baseline check, final check.

### Model/API consumption

- Example attempt (`agent-simple-coding-agent-rpi5`, issue run on 2026-10-11,
  `muse-spark-1.3-contributor`): 645 s, 189k input, 47k output and 6.66M cache-read
  tokens; `token_budget.actual_tokens` 6.9M against `max_budget_tokens` 9.0M.
  Max observed `actual_tokens`: 10.0M.
- Reported cost: median about 0.99 USD per attempt, p90 16.4 USD, sum 224 USD
  over 62 attempts (199 USD of it in `agent-simple-coding-agent`). Costs mix
  models (`muse-spark-1.3-contributor`, `claude-sonnet-5-5`) and cost bases, so
  treat them as indicative only.
- One attempt of about 10 minutes sends roughly 6-7M tokens, most of them cache
  reads: about 10-12k tokens/s sustained effective context traffic, tiny
  output. N Workers multiply this linearly. Any provider rate limit
  (requests/tokens per minute) and, for the LiteLLM route, the gateway's own
  limits are shared by the Pool. No concurrency/rate setting exists in the
  instance templates or in the upstream `simple_coding_agent` package
  (grep for concurrency/semaphore/rate: nothing), so the Pool relies on the
  provider's and gateway's limits.

### Disk

- Images (shared per Instance, not per Worker): 756 MB-1.42 GB
  (`simple-coding-agent:simple-coding-agent-rpi5` 1.02 GB,
  `simple-coding-agent:simple-rpg-engine` 1.42 GB, `jsonhub-api` 808 MB).
- Data volume per Worker (`/data`): `agent-simple-rpg-engine_agent_data` is
  528.8 MB, of which `repo/` 552 MB (446 MB `node_modules`; `.git` only 584 KB,
  so the clone is shallow/small), `logs/` 160 KB, `state/` 72 KB. The rpi5
  Python instance volume is 28.7 kB (empty clone at sampling time).
- Attempt logs are small per attempt but add up in the cache: 288 KB to 42 MB
  per Instance after 3 weeks; at most about 14 MB/week/Instance, so N Workers
  grow this about N times.
- Host totals: OrbStack Docker 18 GB images + 9 GB volumes + 8 GB build cache;
  rpi5 49 GB images (23 GB reclaimable), 5.8 GB volumes, 4.3 GB build cache.
- Disk per Worker is roughly `volume (0.1-1 GB depending on stack) + logs`;
  extra Workers of one Instance cost no extra image.

## Proposed defaults (to be validated)

Per-service limits in the compose template, overridable from `.env`:

| Setting | Proposal | Basis |
|---|---|---|
| `cpus` | 1.5 | 4-core hosts; leaves headroom for 2 Workers plus other services; observed average is low |
| `mem_limit` | 3g | estimate: Node/PHP toolchain plus bundled MySQL/Redis; **not measured** |
| `pids_limit` | 1024 | observed 146; tini already reaps zombies |
| `mem_reservation` | 1g | estimate |

Pool size (maximum Workers per host), sized so that `N x cpus <= 75% of cores`
and `N x mem_limit <= about 60% of RAM`:

| Host | Max Workers | Reasoning |
|---|---|---|
| rpi5 | 2 (3 if idle host) | 4 cores / 15.8 GiB, but LiteLLM, Postgres, dashboard, Beszel and Portainer already run there |
| orbstack | 2 | 4 cores / 11.7 GiB shared with the user's desktop and other dev containers; heavy Node builds froze the Mac before |
| gin | unknown | unreachable |

Beyond the host, cap the Pool by the model route: e.g. 2-3 concurrent sessions
unless the provider's per-minute limits are confirmed.

## Gaps and unverified

- Peak and average memory per Worker: not measured. rpi5 `docker stats`
  reports `0B / 0B`; no Worker was running on OrbStack. Next step: sample
  `docker stats` on OrbStack during a real attempt, or read
  `/sys/fs/cgroup/memory.peak` inside a Worker (needs `docker exec`, not done
  here to stay strictly read-only).
- gin: unreachable, so its CPU/RAM/disk are unknown.
- Provider rate limits for the Meta/Anthropic/LiteLLM routes: not checked in a
  primary source here.
- CPU figure is a single sample; no time series.
- Costs in the logs mix models; the per-attempt cost is not a stable unit.
