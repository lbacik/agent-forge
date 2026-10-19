# Workers of a Pool share one GitHub account; a per-Worker label marks the Claim

GitHub's terms allow one free machine account per person, so giving every Worker its own account needs several responsible people or paid accounts, and one GitHub App per Worker depends on unconfirmed bot assignability plus a large upstream change. We therefore let all Workers of a Pool act as one Worker identity (one `GITHUB_TOKEN`) and tell them apart by a Worker id (`WORKER_ID`). Because assignment is idempotent for a shared login, the Claim is decided by a per-Worker `claimed-by:<worker-id>` label, not by who is assigned: after assigning and labelling, a Worker settles, re-reads and yields if it sees another assignee or another Worker's label. Distinct Worker identities remain supported by the same protocol.

## Considered Options

- **One machine account per Worker**: works with today's assignee-based Claim, but runs into the one-free-account-per-person limit.
- **One GitHub App per Worker**: free and within the terms, but App bots as issue assignees are unconfirmed and upstream would need App authentication, token refresh and node-id identity.
- **Claim comment instead of a label**: gives "earliest wins" ordering through `createdAt`, but every claim adds a comment and an email notification. A label is silent, needs no extra query, shows which Worker holds the issue, and its presence alone means the Claim is held.

## Consequences

- Release removes only the Worker's own label; the shared assignment is removed only when no other `claimed-by:*` label remains. An issue carrying any `claimed-by:*` label is not eligible for the Queue.
- When two Workers see each other's labels, both yield; the issue returns to the Queue (a liveness cost, never double work).
- A Worker that loses its data volume leaves its label and assignment behind for a human to clear, as an assignment is left behind today.
- Within a shared-account Pool every comment is the Worker's own, so peer logins are not needed; they remain for Instances with different logins working one Queue.
- `WORKER_ID` cannot be enforced: upstream cannot see that another process uses the same token. agent-forge renders it for every Worker that shares its login.
