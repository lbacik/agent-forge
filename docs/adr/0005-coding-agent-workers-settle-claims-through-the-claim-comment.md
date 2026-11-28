# coding-agent Workers settle Claims through the Claim Comment, so several may share one Workflow

A coding-agent Instance may declare several Workflows (`implement`, `triage`), and each Worker runs exactly one of them. A coding-agent Pool holds `worker` and further Workers `worker-<n>` (n ≥ 2), each with its own state volume `state_<n>`, its own Managed Instance name `<short-name>-<n>` and its own `--workflow`. Several Workers may run the same Workflow on one shared login: coding-agent's Claim is the Agent Identity's assignment **plus a Claim Comment** carrying an Attempt Marker with the Workflow id and the Attempt id, and among Claim Comments in force the lowest comment id wins; a Worker whose read-back loses deletes its own Claim Comment and records the Claim `released` (coding-agent step-workflow runtime contract §6.1–§6.2, ADR 0015 there). Exclusivity is global per input, whatever the Workflow, and an Attempt's number `n` is derived from the Run Ledger and from the Attempt Markers and branches on GitHub, so Workers with separate state volumes never mint the same Attempt id. Round Handoff Continuations and Relays are picked up from GitHub state, by whichever Worker of the receiving Workflow claims first.

## Status

Amended 2026-11-28. This ADR first read "A coding-agent Pool runs at most one Worker per Workflow" (at most two Workers), on the premise that coding-agent "leaves no Claim marker, so two Workers on one Workflow and one shared login would race". That premise was wrong: the Claim Comment has been part of every coding-agent release since v0.4.0. It was found while running a second `implement` Worker (`worker-3`) on `agent-simple-coding-agent-rex` at coding-agent v0.5.3, where the two Workers took different issues from the same Queue.

## Considered Options

- **At most one Worker per Workflow** (the original decision): rejected now that the Claim Comment is known to settle a race between Workers on one login; it only limited throughput.
- **Wait for coding-agent to advertise `pool`**: rejected as a precondition. `pool` is an Operator Capability for the operator contract's Fleet rules, not the mechanism that keeps Claims exclusive; coding-agent's exclusivity does not depend on it.
- **One Worker per Instance, another Instance for more Workers**: rejected because the Fleet check allows one Instance per backend on a Target Repository (ADR 0003), and a second coding-agent Instance would duplicate the image, the Skill Bundle and the policy review for the same repository.

## Consequences

- coding-agent still does not advertise the `pool` Operator Capability. Every Worker beyond the first is another Managed Instance on the same Target Repository and Docker context, which departs from the operator contract rule "Without `pool`, a deployment adapter MUST refuse a second instance for the same Target Repository on the host". create-agent and manage-pool state the departure in their reports, and `agentfleet` readings of such a Pool stay unverified until coding-agent advertises `pool` or the contract admits it.
- create-agent still renders at most `worker` and `worker-2` (one per Workflow selected at creation). manage-pool adds further Workers, on any Workflow `workflow.yml` declares, as `worker-<n>` with `state_<n>`; `--scale` is never used, because each Worker needs its own state volume and Managed Instance name.
- A coding-agent Worker has no Worker id and no `claimed-by:*` label: its Managed Instance name tells the Workers apart, and the Claim Comment is the ownership record.
- Each Worker receives only the model keys of its own pins (its Workflow's pin, plus the Advisor pin for `triage`), and only Workers using a gateway pin join the gateway network.
- More Workers on one Workflow multiply what the Instance spends at once: model cost (one Attempt Ceiling per Worker), host CPU and memory during bootstrap and validation (on a host without a memory cgroup, such as rpi5, `mem_limit` is discarded), and the owner's GitHub rate limit, because every Worker polls on its own. Sizing the Pool against these is the operator's decision.
- A Claim orphaned by a lost state volume is released by a human (coding-agent's ledger-loss runbook), as for a single Worker.
