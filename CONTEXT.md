# Agent Forge

Configuration and skills for running dedicated simple-coding-agent deployments, each targeting one GitHub repository.

## Language

**Instance**:
The deployment directory `agent-instances/agent-<name>/` for one target repository: one image, one repository profile, one or more Workers.
_Avoid_: Agent (ambiguous between the deployment and a running process)

**Worker**:
One running simple-coding-agent container of an Instance, with its own data volume and its own Worker id.
_Avoid_: Replica, agent, node

**Pool**:
The set of Workers of one Instance that take issues from the same queue. Its Workers treat each other's attempt results as their own, so any Worker may continue an issue another Worker handed off.
_Avoid_: Fleet (reserved for all Instances seen by the dashboard), cluster

**Worker identity**:
The GitHub account (and its token) that a Worker acts as. The Workers of a Pool may share one Worker identity or each have their own.
_Avoid_: Agent name, bot

**Worker id**:
The name that tells apart Workers acting as the same Worker identity; unique among all of them, across Instances.
_Avoid_: Worker name, replica index

**Claim**:
A Worker's exclusive hold on one Queue issue: the issue is assigned to its Worker identity, carries its Claim marker, and shows no other claimant (another assignee or another Worker's Claim marker). A Worker that finds another claimant yields.
_Avoid_: Lock, lease

**Claim marker**:
The mark on an issue naming the Worker that holds its Claim; present only while the Claim is held.
_Avoid_: Lock label

**Queue**:
The issues of the target repository that Workers may claim, selected by the upstream-defined labels.
_Avoid_: Backlog

**Conflict requeue**:
Returning an issue to the Queue because the pull request a Worker already published for it has merge conflicts with the base branch; the next attempt only brings that pull request up to date and does no new work.
_Avoid_: Retry, re-label, continuation (a continuation resumes unfinished work); a pull request merely behind the base branch is not a Conflict requeue

**Conflict attempt**:
The attempt a Worker makes after a Conflict requeue: it brings the already published pull request up to date with the base branch, publishes only when the result passes the repository's check, and does no new work on the issue.
_Avoid_: Conflict-only attempt, resolver run
