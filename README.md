# Pi Core Memories

Persistent, approved memory for Pi. Background dreaming finds possible memories.
The user reviews and changes memory through ordinary conversation.

## No extension commands

The Pi extension registers no slash commands. It has no command aliases,
manual dreaming command, review command, or separate memory-review mode.

Ask in chat to inspect memories, explain a finding, change a proposal, or remove
a memory. These are normal messages. The user must not need to open a menu,
run a command, or start a second application to do memory work.

The native executable and worker protocol are internal integration and
diagnostic interfaces. They are not the user interface.

## Implementation status

The native queue, checked publisher, background scheduler, and approved-memory
loader exist. The ordinary-chat approval transport is not complete yet.
Removing commands does not complete that transport. The old modal approval
adapter is also removed. Queue inspection and checked receipt recovery remain
available, but the queue tool does not expose review or write operations.

The conversation must have a trusted record of the exact proposal that was
displayed and the user's later explicit reply. A model's description of a reply,
an input marked interactive, a restored message, or an autonomous instruction
does not supply that authority. If the host cannot establish it, the write stays
blocked. A separate review dialog is not an alternate completion path.

## Background dreaming

Dreaming is background work. It does not approve or write memories.

- One temporary worker serves the local interactive Pi sessions.
- Intake includes existing sessions and new completed work.
- Foreground work has priority over intake and model calls.
- Live sessions are excluded from the background evidence batch.
- With no interactive Pi session open, no worker should continue.
- There is no permanent service or cross-device queue.
- The selected provider, model, and thinking level stay unchanged.
- Source protection runs before source admission and model delivery.

Saved input, model requests, responses, pending findings, and recovery records
remain durable. An interruption must not discard evidence, repeat a model call
without authority, or manufacture approval. Source protection does not promise
complete detection of transformed secrets.

## Review in conversation

A relevant pending finding belongs in the ongoing conversation, including
during a task. Listing or claiming the finding is internal work. It must not
turn the user into an operator of the queue.

Before a change, show the exact proposal, its reason, and its evidence. The user
can discuss it, request a revision, reject it, defer it, or approve the exact
displayed change.

Approval applies only to that proposal. A changed proposal needs a new display
and new explicit approval. Silence, background work, tool output, an earlier
yes, and autonomous guidance never grant consent.

Deferral or cancellation must not repeat the same finding during the same
request. Rejection permits reconsideration only after verified new evidence
changes the finding. Rewording the same claim is not new evidence.

Only one live owner can review a finding at a time. Session death and
cancellation release ownership without granting approval. Restart restores
pending work, not consent.

## Inspect and change approved memories

Approved memories remain available for inspection in chat. Requested additions,
updates, deletions, and review-date changes use exact entries and the same
checked storage authority. Internal tools must not bypass a queue-bound store
or prescribe a removed command when a write is blocked.

A blocked preparation or publication step must be explained in conversation.
Keep the entry, pending proposal, and source evidence intact. A detached
checkout receipt is not a saved-memory receipt. Report a save only after the
native checked commit and audit receipt establish it.

Each session uses its saved approved-memory snapshot. A later memory change
does not silently rewrite an existing session's snapshot.

## Stored data

Approved memory lives in a private Git repository. Scope paths include
`MEMORY.md`, project entries, and device entries. Native catalogues supply exact
scope keys, entry identities, byte locators, and approved bases. Do not invent
keys, search for duplicate prose as an entry identity, or read pending material
as approved memory.

The additive finding queue retains original evidence and prior dispositions.
Manual drafts, unsupported historical findings, incomplete runs, and missing
evidence stay visible with their limitations. They are not discarded or
silently promoted to approved memory.

Do not rewrite source archives, reset review state, delete unknown locks, or
change the approved reference to make a failed check pass. A capacity or
verification failure preserves prior state and blocks the affected operation.

The existing installed Core Memories application and its data remain in place
until the conversational replacement and migration pass acceptance. Removing
extension commands does not authorize application removal or data deletion.

## Integration

The package entrypoint is [Integration/Pi/index.ts](Integration/Pi/index.ts).
It loads an approved snapshot, registers the internal memory tools and history
renderer, and connects the existing background runtime. It does not register
commands.

- [Native queue protocol](docs/native-queue.md) defines ownership, exact
  presentation, private consent traffic, checked receipts, and migration limits.
- [Dream input protocol](docs/dream-input-protocol.md) defines source admission,
  frozen model requests, response validation, and recovery.
- [Native application notes](docs/native-app.md) describe the retained legacy
  application and packaging boundary. It is not the replacement review route.

Isolated protocol tests use native configuration files. They must isolate every
affected store. They do not add an extension mode or establish that the normal
background-to-chat flow works.

## Build and verification

Build the native engine with warnings as errors:

```sh
swift build --product pi-core-memories -Xswiftc -warnings-as-errors
```

Use affected-test selection for a change. Required broad checks and independent
review must run against the current source state. A native protocol pass, a
source-only inspection, or a video of a removed menu does not establish the
installed conversational flow.

Acceptance includes background intake, foreground priority, normal chat
handoff, exact displayed approval, conversational changes, rejection, deferral,
ownership recovery, last-session shutdown, preserved data, and migration.
Installation follows checked user-merged revisions. Application retirement
follows replacement and migration acceptance.

## License

MIT.
