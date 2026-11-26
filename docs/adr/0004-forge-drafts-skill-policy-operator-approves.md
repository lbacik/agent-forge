# The Forge drafts a coding-agent Instance's skill policy; the operator approves every decision

A coding-agent Instance needs a reviewed `skill-policy.json` covering every member of its Skill Bundle before its image can build. Until now create-agent copied the reference policy verbatim from coding-agent's `docker/deployment/` and never wrote a policy entry, which limited every Instance to the reference deployment's four skills. Now that an Instance can run other Workflows (for example `triage`, with `triage`, `grilling` and `domain-modeling`), coding-agent cannot ship a reference policy for every possible bundle. So create-agent builds the policy for the Instance's own bundle. It installs the declared skills and runs `agent draft-skill-policy` in a one-off container on the engine base image, before the derived image builds. It shows the operator the draft's review report and writes each placeholder decision (file disposition, reference classification, reason) only after the operator approves it. The skill still never approves a policy entry on its own. Reviews that still match the reference policy are carried forward by the command unchanged.

## Considered Options

- **Keep copying a reference policy verbatim**: rejected because only the reference bundle is covered, and asking upstream for one policy per bundle does not scale.
- **The model proposes all decisions and the operator approves them in bulk**: rejected because a bulk approval stops being a review; a per-file disposition decides what reaches a model's context.
- **An upstream mode that emits an approved policy**: rejected because it contradicts coding-agent's design, where a draft is "never an approval".

## Consequences

- create-agent's rule changes from "never writes or approves policy entries" to "writes only the decisions the operator approved; never approves on its own".
- Drafting needs the installed skill store, so create-agent runs the install and the draft before the image build, against the same `CODING_AGENT_REF` and source ref the image will use.
- A changed bundle membership or source ref means drafting and reviewing again; carried-forward reviews keep the unchanged members cheap.
