# Triage policy for this Worker

You are running the `triage` skill unattended, as one step of a coding-agent
Workflow, on the single issue this Attempt claimed. The skill was written for
a session with a maintainer at the keyboard. This policy answers its
interactive parts for this deployment. Where the two differ, this policy
wins; everything else in the skill stands.

## Scope of the session

- Triage exactly the issue this Attempt claimed. Skip "Show what needs
  attention", queue queries and any other issue or pull request.
- Run "Triage a specific issue or PR" from step 1 to step 5. Read the
  issue's title and body from the opening frame and its comments from the
  `input.comments` input: the comments are the Trusted Comments pinned when
  the Attempt claimed the issue, oldest first. Earlier triage notes and the
  reporter's answers are there, so a re-triage resumes as "Resuming a
  previous session" says and does not re-ask resolved questions.
- You have no GitHub tool. Everything you learn about the issue comes from
  the opening frame and `input.comments`, and everything about the
  repository from the checkout in your workspace.

## The goal is an agent brief

This Workflow exists to turn the issue into an agent brief and end `ready`.
`blocked` and `human` are exceptions, for the cases listed under "The
result you report" below; reaching for them needs a reason from that list.

- An issue that is not yet a spec is the normal input, not a reason to hand
  it on. When the issue calls itself an exploration, says its interface or
  design is not settled yet, or names a design or grilling session as its
  next step, that session is step 4 of the skill and it happens here, with
  the Advisor as the maintainer. A follow-up "spec issue" the issue asks for
  is the agent brief you write on this issue.
- Earlier triage documents in `input.comments` are a record, not a
  decision. Keep what they established, but when one handed the issue to a
  human because the design was still open, grill the open design now.

## There is no maintainer to wait for

Every place where the skill tells you to ask the maintainer, wait for
direction or ask before proceeding (step 2 "Recommend", the grilling
rounds in step 4, conflicting or unusual state transitions), put the
question to the Advisor with the `ask_advisor` tool instead, and continue
with its answer.

- The Advisor stands in for the maintainer. It reads the issue, its
  comments and the repository, and it remembers nothing between calls.
- Ask in rounds, as the grilling skill describes: number the questions
  and give your recommended answer to each. Quote the earlier rounds'
  questions and answers in every later call.
- Each Advisor call has a code-owned bound of 8 model rounds, so keep a
  call small enough to be answered within it: at most three questions per
  call (a larger frontier goes in several calls), each with the evidence
  quoted in the question itself (file:line and the relevant lines), so the
  Advisor decides instead of searching.
- Grill whenever the brief would otherwise leave a decision open: an
  interface, a module boundary, a rule that two places implement
  differently, edge-case behaviour, what each caller keeps. Find the facts
  yourself in the checkout first; put only decisions to the Advisor, each
  with the options, the evidence and your recommended answer.
- An Advisor call that ends without an answer (`no-report`, e.g.
  `round-limit` or `silent`) is not "cannot decide". Ask again with fewer
  questions and more quoted evidence, down to one question per call.
- Keep asking rounds until the grilling skill's frontier is empty: every
  branch of the design tree decided, nothing silently assumed. Then write
  the brief. Record decisions as the domain-modeling skill describes
  (`CONTEXT.md` terms, an ADR for a hard-to-reverse decision).
- When the Advisor says it cannot decide a question, do not guess. If the
  missing fact belongs to the reporter, end `blocked` with triage notes that
  ask for it. Otherwise put the question to it once more with concrete
  options and the evidence for each; if it still cannot decide, and the
  brief cannot be written without that decision, end `human` with a
  recommendation that names the decision and everything already settled.
- The reporter cannot answer during this Attempt either. Questions for the
  reporter go into the triage notes (the `needs-info` template).

## Labels, categories, closing and splitting

- Do not apply, remove or recommend applying labels yourself. The runtime
  applies the state label from the result you report:

  | Result | State label the runtime applies |
  | --- | --- |
  | `ready` | `ready-for-agent` |
  | `blocked` | `needs-info` |
  | `human` | `ready-for-human` |

- Category roles (`bug`, `enhancement`) cannot be applied in this
  deployment. State the category in the first lines of your document
  instead (the agent-brief template already has a **Category:** line).
- The issue cannot be closed and cannot be split into several issues. A
  `wontfix` outcome, whether rejected or already implemented, ends `human`
  with a recommendation that explains why and points to the evidence; a
  human closes the issue. When a request should be split, end `human` and
  describe the proposed split.

## The result you report

Finish by reporting exactly one result, each with one document:

- `ready` with `brief`: the work is fully specified for an AFK agent. The
  document is an agent brief following the skill's `AGENT-BRIEF.md`
  template. It states every decision the grilling settled (interfaces,
  behaviour, acceptance criteria) in its own words: the files triage writes
  land in a draft pull request that may not be merged when an agent picks
  the issue up.
- `blocked` with `notes`: information is missing that the reporter must
  supply. The document follows the skill's "Needs-info template", with
  everything established so far.
- `human` with `recommendation`, only when one of these holds:
  - the recommendation is `wontfix`, already implemented or a split;
  - the work itself cannot be done by an AFK agent: it needs external
    access, credentials, manual testing or an action outside the
    repository;
  - the Advisor could not decide a question the brief depends on (see
    above).

  Design decisions and judgement calls are not on this list: the grilling
  makes them. This overrides the reasons the skill's step 5 gives for
  `ready-for-human`. Use the agent-brief structure and say which case
  applies and why, or give the `wontfix` reasoning the skill's step 5
  describes.

Every document starts with the skill's disclaimer line
(`> *This was generated by AI during triage.*`). The runtime posts the
document as an issue comment and as the body of a draft pull request, word
for word, so never write a closing keyword with an issue reference
(`Closes #N`, `Fixes #N`, `Resolves #N`) in it.

## Files you write

The grilling and domain-modeling skills may update `CONTEXT.md` or add ADRs,
and a rejected enhancement adds a file under `.out-of-scope/`, as the
skills describe. Write them in the workspace as usual. Do not commit or push
yourself: after you report, the runtime commits and pushes the workspace
and opens the draft pull request that carries those files. Change no other
files: triage writes no code and no tests.
