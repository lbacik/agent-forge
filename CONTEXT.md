# Agent Forge

Configuration and skills for running dedicated simple-coding-agent deployments, each targeting one GitHub repository.

## Language

**Instance**:
The deployment directory `agent-instances/agent-<name>/` for one target repository: one image, one engine backend, one or more Workers. A target repository holds at most one Instance per backend, apart from a contract Pool.
_Avoid_: Agent (ambiguous between the deployment and a running process), Managed Instance (that is one Worker)

**Worker**:
One running engine container of an Instance (simple-coding-agent or coding-agent), with its own data volume and, when it shares its Worker identity with other Workers or belongs to a contract Pool, its own Worker id.
_Avoid_: Replica, agent, node

**Pool**:
All the Workers of one Instance. Its Workers treat each other's attempt results as their own, so any Worker that runs the same Workflow may continue an issue another Worker handed off. Workers of one Pool that run different Workflows take from different Queues.
_Avoid_: Fleet (the contract's term for all Managed Instances on one Docker host), cluster

**Worker identity**:
The GitHub account (and its token) that a Worker acts as. The Workers of a Pool may share one Worker identity or each have their own.
_Avoid_: Agent name, bot

**Worker id**:
The name that tells apart Workers: every simple-coding-agent Worker that shares its Worker identity with another Worker has one, and so does every Worker of a contract Pool, whatever its Worker identity. Unique among all Workers, across Instances. A coding-agent Worker has none: its Managed Instance name tells it apart (`docs/adr/0005-coding-agent-pool-one-worker-per-workflow.md`).
_Avoid_: Worker name, replica index

**Claim**:
A Worker's exclusive hold on one Queue issue: the issue is assigned to its Worker identity, carries its Claim marker when the Worker has a Worker id, and shows no other claimant (another assignee or another Worker's Claim marker). A Worker that finds another claimant yields.
_Avoid_: Lock, lease

**Claim marker**:
The mark on an issue naming the Worker that holds its Claim; present only while the Claim is held.
_Avoid_: Lock label

**Workflow**:
A named scenario in a coding-agent Instance's Workflow Configuration, such as `implement` (issue in, pull request out) or `triage` (`needs-triage` in, a triaged issue out). The configuration may declare several; each Worker runs exactly one, chosen in that Worker's own configuration. A simple-coding-agent Worker has no Workflow choice: its backend fixes the scenario.
_Avoid_: Mode, pipeline, job

**Queue**:
The issues (and, for some backends, pull requests) of the target repository that a Worker may claim, selected by the labels of its Workflow (coding-agent) or by labels its backend defines (simple-coding-agent). Workers of several Instances of one backend may take from one Queue; the Claim settles between them as it does within a Pool. Instances of different backends may share a target repository; keeping their Queues apart, or deliberately not, is the operator's concern.
_Avoid_: Backlog

**Conflict requeue**:
Returning an issue to the Queue because the pull request a Worker already published for it has merge conflicts with the base branch; the next attempt only brings that pull request up to date and does no new work.
_Avoid_: Retry, re-label, continuation (a continuation resumes unfinished work); a pull request merely behind the base branch is not a Conflict requeue

**Conflict attempt**:
The attempt a Worker makes after a Conflict requeue: it brings the already published pull request up to date with the base branch, publishes only when the result passes the repository's check, and does no new work on the issue.
_Avoid_: Conflict-only attempt, resolver run

**Conflict escalation**:
A Worker ending the Conflict requeue of an issue after its Conflict attempts have failed a configured number of times in a row, and handing the pull request to a human; the issue is not requeued again until a human hands it back.
_Avoid_: Exhausted budget, conflict handoff (a handoff is an ordinary attempt outcome)

**Dashboard deployment**:
The directory `dashboards/<docker-context>/` that runs one agent-dashboard for one Docker context: upstream compose files pinned to one ref, a Forge overlay and an access profile. It shows the Managed Instances on that context and is itself neither an Instance nor a Managed Instance.
_Avoid_: Dashboard instance, dashboard agent (`agent-instances/agent-dashboard/` is the Instance whose Target Repository is agent-dashboard)

### Operator contract

These terms are used as defined in the glossary of operator contract major 1, at the tag pinned in the README's [Operator contract](README.md#operator-contract) section, and are not redefined here: Managed Instance, Fleet, Pool, Backend, Target Repository, Operator Capability, Intake, Operator Command, Acknowledgement, Status Snapshot, Figure, Figure Basis, Attempt, Attempt Archive, Sealed, Offline Read, Halt. Where both glossaries use a word, this file's meaning applies unless the contract's is named, as in "contract Pool".

- **Worker ↔ Managed Instance**: each Worker managed through the contract is exactly one Managed Instance, so an Instance holds one or more Managed Instances, one per Worker.
- **Pool ↔ contract Pool**: the contract Pool on a Target Repository is every Managed Instance working it on one Docker context. It holds the Workers of one Pool, or of several Instances' Pools when they share that repository and context, and each of its Managed Instances needs the `pool` Operator Capability. The one exception is a coding-agent Pool of two Workers that run different Workflows, which this backend runs without `pool` (`docs/adr/0005-coding-agent-pool-one-worker-per-workflow.md`). A single Worker with no other Managed Instance on its Target Repository on that context is in no contract Pool.
