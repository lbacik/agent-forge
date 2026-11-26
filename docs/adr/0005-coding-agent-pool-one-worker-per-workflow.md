# A coding-agent Pool runs at most one Worker per Workflow

A coding-agent Instance may now declare both the `implement` and the `triage` Workflow, and each Worker runs exactly one of them. So that one Instance can run both, a coding-agent Pool may hold a second Worker: service `worker-2` with its own state volume `state_2`, its own Managed Instance name `<short-name>-2` and its own `--workflow`. The Pool holds at most one Worker per Workflow, so at most two Workers. coding-agent (v0.5.0) does not advertise the `pool` Operator Capability and leaves no Claim marker, so two Workers on one Workflow and one shared login would race for the same Queue with nothing to settle the Claim between them. Workers on different Workflows take from different Queues (different Selection Labels), and coding-agent's mandatory guard skips any issue that already has an assignee, so an issue one Worker holds is never taken by the other.

## Considered Options

- **Any number of Workers, several on one Workflow**: rejected because without a Claim marker or the `pool` capability two Workers on one Queue and one login can each believe they hold the same issue (the problem ADR 0001 solved for simple-coding-agent).
- **One Worker per Instance, a second Instance for the second Workflow**: rejected because the Fleet check allows one Instance per backend on a Target Repository (ADR 0003), and a second coding-agent Instance would duplicate the image, the Skill Bundle and the policy review for the same repository.

## Consequences

- This departs from operator contract rule "Without `pool`, a deployment adapter MUST refuse a second instance for the same Target Repository on the host": the two Workers are two Managed Instances on one Target Repository and Docker context. create-agent and manage-pool state the departure in their reports, and `agentfleet` readings of such a Pool stay unverified until coding-agent advertises `pool` or the contract admits per-Workflow Queues.
- manage-pool adds and removes `worker-2` by hand, asks which Workflow it runs, and refuses a Workflow that another Worker of the Pool already runs or that `workflow.yml` does not declare.
- A coding-agent Worker has no Worker id: its Managed Instance name (`<short-name>`, `<short-name>-2`) tells the Workers apart, and no Worker id or Claim marker is rendered.
- Each Worker receives only the model keys of its own pins (its Workflow's pin, plus the Advisor pin for `triage`), and only Workers using a gateway pin join the gateway network.
