# One Instance per backend on a target repository; the Forge does not check labels across backends

The create-agent Fleet check used to refuse any second Instance on a target repository outside a contract Pool, so two single-instance engines could never compete. We now let Instances of different backends share a target repository (at most one Instance per backend, apart from a contract Pool, whose rules are unchanged), so that, for example, a coding-agent `triage` Instance can feed `ready-for-agent` issues to a simple-coding-agent Instance. The Forge deliberately does not compare the two Instances' selection labels: whether their Queues stay apart is the operator's decision, and an overlap the operator allows is assumed to be intended. Once one engine holds an issue, the other leaves it alone, because both skip an issue that has any assignee (simple-coding-agent's Queue requires an unassigned issue; coding-agent's mandatory guards exclude one). Two Instances on different GitHub logins therefore settle even a simultaneous race through the Claim; on one shared login they do not (see Consequences).

## Considered Options

- **Refuse unless the selections are disjoint** (proposed in #121): the Fleet check would read simple-coding-agent's code-owned queue signals and every coding-agent Workflow's Selection and Pickup Labels and refuse an overlap. Rejected: the Forge would have to track each engine's label semantics across releases, and it would forbid overlaps an operator wants on purpose.
- **Keep refusing every same-repository pair**: rejected because it blocks pairing engines that serve different scenarios on one repository.

## Consequences

- The Fleet check refuses a new Instance only for an Instance of the same backend on that target repository; one of another backend never refuses, on any Docker context, including an unlabelled legacy simple-coding-agent Instance.
- The create-agent report names the other-backend Instance and states that keeping the selection labels apart is the operator's responsibility; the operator confirms the pairing once.
- On one shared GitHub login, overlapping labels can cause double work: assigning the same login is idempotent, and coding-agent leaves no `claimed-by:*` Claim marker for simple-coding-agent to see, so two Workers racing for one issue can each believe they hold the Claim (the problem ADR 0001 solved within one backend). The report states this too; the Forge reads no tokens and does not refuse the pair.
- Under a shared identity, coding-agent's Selection Label actor test also accepts labels the other engine applies, so label separation is the only gate between the two; this is coding-agent's documented operator responsibility, not something the Forge enforces.
