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

## Public Pi integration

The extension uses public Pi extension interfaces. It does not require a Pi
fork or a custom conversation interface. Supported package versions are the
[peer dependencies in package.json](package.json).

A registered custom-message renderer shows the exact native proposal in the
normal transcript. One worker stays open for a later reply. Public input and
session events bind that reply to the unchanged prompt, the exact user message,
and the current displayed proposal. Model tool arguments cannot supply it.
The old modal approval adapter is removed, with no command or dialog fallback.

Proposal control material is excluded from model context. The user's reply
remains an ordinary chat message. These checks trust the Pi process and its
loaded extensions; they do not authenticate a person or prove that every line
was painted or read.

A wording change keeps the finding's native review owner. Native validation
preserves the original finding, evidence, and source annotations. It stores an
unapproved amendment and creates a new exact preview. That preview needs a new
display and a later explicit approval. An earlier reply cannot approve it.

The consumer still needs fresh independent review, complete installed
background-to-chat verification, and migration acceptance. Source implementation
does not authorize removal of the old application or its retained data.

The adapter must find the exact proposal in the current durable transcript and
capture a later eligible reply. A model's description of a reply, an interactive
source label alone, a restored message, or an autonomous instruction does not
supply that authority. Missing, transformed, queued, competing, or stale input
blocks the write. A separate review dialog is not an alternate completion path.

## Background dreaming

Dreaming is background work. It does not approve or write memories.

- One window at a time dreams. The native worker holds an exclusive,
  non-blocking `flock` on its dream state; other windows stay `dreaming: idle`
  and retry later. The operating system releases the lock when the process exits.
- Intake includes existing sessions and new completed work.
- Dreaming continues while you use this or another Pi window.
- Memory tool calls in a window do not stop that window's dream run.
- Live sessions are excluded from the background evidence batch. Every Pi
  process with a session file (interactive, print, or RPC) writes a marker for
  its session in `~/.pi/memory-host` (directory mode 0700, owner checked). Only
  interactive windows dream. The marker name holds the process ID; the dreamer
  skips sessions whose process is alive and deletes any regular file you own
  with a marker or orphan `.live.tmp` name whose process is dead, before
  checking its mode or content. A file that is not a regular file you own is
  skipped and not deleted. A live process's marker that fails the mode 0600,
  link, size or session ID check is skipped, not trusted and not deleted. If the
  operating system reuses a dead window's process ID, its stale marker keeps
  that session excluded until the new process exits. This fails safe: it can
  delay intake of a finished session, but never admits a live one. If a window
  cannot write its marker, it shows `liveSessionUnavailable` and retries on
  later schedules; this does not count as a worker failure. A window with no
  session file has no session to exclude; it writes no marker and still dreams.
- Findings stay pending until you approve the exact proposal in conversation.
- Decision journal: a dream run holds the memory lock for its whole run. If you
  answer a proposal while another window dreams, the window records your exact
  decision (proposal revision, display digest, the durable reply reference, and
  the action) in the queue ledger and tells you it will apply shortly. Each
  dream run applies journaled decisions before and after its run, and every
  window applies them before and after each memory tool operation when no
  proposal is open, whatever that window queued itself. Each apply repeats
  the same native checks as an immediate reply. If the proposal or its
  evidence changed, or the apply fails before it publishes, nothing is applied
  and the decision gets a `needs-decision` receipt; later journaled decisions
  still apply. A `needs-decision` receipt is written only after a fresh check
  shows that nothing was published, and a later published result replaces it.
  Only the window whose session gave the answer posts a visible message, once
  per revision: the earlier answer was not applied and does not count, nothing
  was saved, and the agent will present the current proposal. The message never
  counts as an answer; a new answer binds to the new proposal. If that session
  is gone, no window posts a message, and the revision shows under
  `N to review`. Every window's footer shows `N need decision` from the
  journal until the revision gets a new decision. A decision is applied at most
  once; a crash between publication and receipt recovers the published result.
- Footer counts come from the native journal: `N queued` counts journaled
  decisions not yet applied, and `N to review` counts pending findings without
  one. They refresh after each journal apply.
- With no interactive Pi session open, no worker should continue.
- There is no permanent service or cross-device queue.
- The selected provider, model, and thinking level stay unchanged.
- Source protection runs before source admission and model delivery.

Saved input, model requests, responses, pending findings, and recovery records
remain durable. An interruption must not discard evidence, repeat a model call
without authority, or manufacture approval. Source protection does not promise
complete detection of transformed secrets.

The runtime publishes this session's dreaming state through Pi's public
extension-status key `pi-core-memories:dream`. A footer can display it without
another command, review mode, or host change.

- `dreaming: applying` means the run is applying journaled decisions.
- `dreaming: active` means a validated archived-model request is in progress.
- `dreaming: idle` means the scheduler waits or finds no new records. It does
  not prove a successful model call.
- `dreaming: paused` means pending review, a model change, or repeated failures
  delay this session's next dispatch.
- Nonzero counts follow the state, for example
  `dreaming: active · 1 queued · 1 to review · 1 need decision`. `queued`
  counts recorded decisions that wait for the lock; `to review` counts pending
  proposals; `need decision` counts revisions whose recorded answer was not
  applied and needs a new decision.
- `dreaming: error(code: X, message: "...")` reports a blocked or failed attempt.
  The code and message use fixed safe text, not raw exceptions or source data.

This is a session-local status, not an aggregate of other workers. Errors stay
visible until an eligible reset. Shutdown clears the status. Completed request,
response and native run records remain the evidence for successful dreaming.

## Subscription-only model calls

Dreaming uses the selected provider, model, and thinking level. It must not fall
back to a paid application programming interface (API) key or switch selections.
On public Pi, the selected route must be an OAuth (Open Authorization)-only
subscription provider with no registered override. Authentication is resolved
once for the selected model, including its headers and endpoint, before calling
the captured provider.

A host with an existing stronger subscription guard can use it, but that guard
is optional. Mixed-authentication, virtual, changed, or unverified public routes
stay blocked when the adapter cannot establish subscription-only dispatch.
It does not install a fork or choose another provider to bypass that limit.

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

Acceptance includes background intake while windows are in use, normal chat
handoff, exact displayed approval, conversational changes, rejection, deferral,
ownership recovery, last-session shutdown, preserved data, and migration.
Installation follows checked user-merged revisions. Application retirement
follows replacement and migration acceptance.

## License

MIT.
