# Agent Forge

Configuration and skills for running dedicated simple-coding-agent deployments, each targeting one GitHub repository.

## Language

**Instance**:
The deployment directory `agent-instances/agent-<name>/` for one target repository: one image, one repository profile, one or more Workers.
_Avoid_: Agent (ambiguous between the deployment and a running process), Managed Instance (that is one Worker)

**Worker**:
One running simple-coding-agent container of an Instance, with its own data volume and, when it shares its Worker identity with other Workers, its own Worker id.
_Avoid_: Replica, agent, node

**Pool**:
The set of Workers of one Instance that take issues from the same queue. Its Workers treat each other's attempt results as their own, so any Worker may continue an issue another Worker handed off.
_Avoid_: Fleet (the contract's term for all Managed Instances on one Docker host), cluster

**Worker identity**:
The GitHub account (and its token) that a Worker acts as. The Workers of a Pool may share one Worker identity or each have their own.
_Avoid_: Agent name, bot

**Worker id**:
The name that tells apart Workers acting as the same Worker identity; unique among all of them, across Instances.
_Avoid_: Worker name, replica index

**Claim**:
A Worker's exclusive hold on one Queue issue: the issue is assigned to its Worker identity, carries its Claim marker when the Worker has a Worker id, and shows no other claimant (another assignee or another Worker's Claim marker). A Worker that finds another claimant yields.
_Avoid_: Lock, lease

**Claim marker**:
The mark on an issue naming the Worker that holds its Claim; present only while the Claim is held.
_Avoid_: Lock label

**Queue**:
The issues of the target repository that Workers may claim, selected by the upstream-defined labels. Workers of several Instances may take from one Queue; the Claim settles between them as it does within a Pool.
_Avoid_: Backlog

**Conflict requeue**:
Returning an issue to the Queue because the pull request a Worker already published for it has merge conflicts with the base branch; the next attempt only brings that pull request up to date and does no new work.
_Avoid_: Retry, re-label, continuation (a continuation resumes unfinished work); a pull request merely behind the base branch is not a Conflict requeue

**Conflict attempt**:
The attempt a Worker makes after a Conflict requeue: it brings the already published pull request up to date with the base branch, publishes only when the result passes the repository's check, and does no new work on the issue.
_Avoid_: Conflict-only attempt, resolver run

### Operator contract

These terms are used as defined in the glossary of operator contract major 1, at the tag pinned in the README's [Operator contract](README.md#operator-contract) section, and are not redefined here: Managed Instance, Fleet, Pool, Backend, Target Repository, Operator Capability, Intake, Operator Command, Acknowledgement, Status Snapshot, Figure, Figure Basis, Attempt, Attempt Archive, Sealed, Offline Read, Halt. Where both glossaries use a word, this file's meaning applies unless the contract's is named, as in "contract Pool".

- **Worker ↔ Managed Instance**: each Worker managed through the contract is exactly one Managed Instance, so an Instance holds one or more Managed Instances, one per Worker.
- **Pool ↔ contract Pool**: a Pool managed through the contract is a contract Pool, and its Managed Instances need the `pool` Operator Capability.
