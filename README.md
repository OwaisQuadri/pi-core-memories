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
  non-blocking run lock (`<dream state>.run`) for the whole run; other windows
  stay `dreaming: idle` and retry later. It holds the dream state's writer lock
  only for short phases, never during the model call. The operating system
  releases both locks when the process exits.
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
- A reply to a proposal during a dream waits for the dream's short writer phase
  and is applied or refused at once, after the same exact native checks. The
  wait stops when the reply is cancelled, or after 300 seconds, longer than a
  normal writer phase (source protection checks can take about 160 seconds);
  the answer is then not applied. If the proposal changed or the apply fails
  before it publishes, nothing is saved and the proposal returns for a new
  answer. A dream batch whose approved memory or rejected findings changed
  before all of its proposals were published is dropped whole, and its
  evidence is dreamt again.
- Footer counts come from the native queue: `N to review` counts pending
  findings.
- With no interactive Pi session open, no worker should continue.
- There is no permanent service or cross-device queue.
- The selected provider, model, and thinking level stay unchanged.
- Source protection runs before source admission and model delivery.

Saved input, model requests, responses, pending findings, and recovery records
remain durable. An interruption must not discard evidence, repeat a model call
without authority, or manufacture approval. Source protection does not promise
complete detection of transformed secrets.

If a model call stops before its reply is saved (for example, Pi restarts), the
next run in that window sends the same saved request again. It does this only
when the window's provider, model and thinking level are the same as the ones
recorded for that call. If they are different, nothing is sent and the footer
shows `dreaming: error(code: interruptedCall, message: "Interrupted dream needs
the model it started with: P/M, thinking L")`. Select that model and thinking
level again and the retry starts.

The runtime publishes this session's dreaming state through Pi's public
extension-status key `pi-core-memories:dream`. A footer can display it without
another command, review mode, or host change.

- `dreaming: active` means a validated archived-model request is in progress.
- `dreaming: idle` means the scheduler waits or finds no new records. It does
  not prove a successful model call.
- `dreaming: paused` means a memory operation in this window (a memory tool
  call or an open proposal) holds the queue, so no new run starts. The footer
  shows it at no other time. When the operation ends, the state goes back to
  `idle`.
- A nonzero count follows the state, for example
  `dreaming: active · 1 to review`. `to review` counts pending proposals.
- `dreaming: error(code: X, message: "...")` reports a blocked or failed attempt.
  The code and message use fixed safe text, not raw exceptions or source data.
  The exception is `backendFailure`: its message is the cause that the model
  call reported, escaped, with provider error text cut to 800 bytes. It never
  contains the model's response.
- `dreaming: error(code: blocked, reason: R, message: "...")` adds the native
  worker's reason code, for example `workerFailure`, `protocolFailure`,
  `cancelled`, `sourceProtection:invalidReply` or
  `sourceProtection:requestLimit` (the run reached its 16 source checks).
  A reason outside letters,
  digits and `:._-`, or longer than 80 characters, shows as `unknown`. Each
  blocked run also replaces `~/.pi/memory-host/last-dream-blocked.json`
  (owner-only) with its time, invocation ID, status, reason and detail. The
  detail is either empty or fixed text from the worker or the extension, never
  source text.
- `dreaming: error(code: pending, reason: R, message: "...")` reports a run that
  the native worker kept pending, for example `invalidDecision` or `staleUnpublishedPlans` (saved proposals waiting for
  saved-suggestion recovery). Like a blocked run, it stops dispatch until your
  next input or a model or thinking level change. A `cancelled` run, and a
  `droppedBatch` run whose batch was dropped because approved memory or
  rejected findings changed before it was published, go back to `idle` and run
  again later.

This is a session-local status, not an aggregate of other workers. Errors stay
visible until an eligible reset. Shutdown clears the status. Completed request,
response and native run records remain the evidence for successful dreaming.

An `invalidDecision` run stays pending until you approve a separate model call.
The `memory_dream_recover` tool first displays the saved run ID, baseline request
hash, and selected model in this conversation. It requires your later original
interactive reply of `yes` to that display before it calls the model once. A tool
argument, queued message, or earlier reply cannot approve the call. For a saved
version 5 request, it appends a version 6 model call with the missing scope fields.
It retains the original request and rejected reply. The worker checks the target
again before it can call the model. The replacement still must pass native
validation. It does not approve a memory.

## Subscription-only model calls

Dreaming uses the selected provider, model, and thinking level. It must not fall
back to a paid application programming interface (API) key or switch selections.
The selected model must be signed in through OAuth (Open Authorization) to a
subscription provider; virtual models are refused. The call then goes through
Pi's model registry, the same authentication path as a normal session, which resolves
authentication, headers, and endpoint for the selected model.

## Review in conversation

A relevant pending finding belongs in the ongoing conversation, including
during a task. Listing or claiming the finding is internal work. It must not
turn the user into an operator of the queue.

Before each prompt in an interactive window, the extension lists the pending
queue and gives the model a short reminder: one line per pending finding, with
its revision and the first line of its proposed entry (up to 120 characters).
When a finding could be relevant to the current request, the model presents
that exact proposal. The reminder is never approval, carries no proposal
control material, and is not saved in the session. Listing is not a pure read:
it takes the queue lock without waiting and may rewrite `queue.json`. When the
lock is busy (an open proposal in any window, a dream's short writer phase,
or another window's queue request), that prompt gets no freshly listed
reminder; if the
user answered a listed finding since the last reminder, a copy of that
reminder without the answered findings is added instead. A new reminder
is also left out when nothing is pending, while a proposal awaits a reply, or
when the queue cannot be listed in time. The request is abandoned after two
seconds and stopping the native worker can take about one more second, so a
prompt waits about three seconds at most.

After the user answers a proposal (approve, reject, defer, or amend), that
finding leaves the reminder for the rest of the session. A new session lists
deferred findings again. Resuming a session starts a new runtime, so deferred
findings are listed again after a resume too. An unanswered finding stays
listed, so it can be asked about again. The reminder shows the original
proposed wording; presenting an amended finding shows its amended draft.

Each reminder stays in place right after the prompt it was made for, with the
same bytes on every later request. It is added after Pi has placed its system
messages, so system messages in mid-conversation stay where they are and the
conversation prefix stays cached. A new reminder is added only when the listed
findings change, and it states that only the latest reminder is current. When
no listed finding is left while an earlier reminder is still in context, a
short reminder says that no pending memory proposals need asking about now and
earlier reminders are out of date. Reminders cost tokens that accumulate only
when the list changes. A reminder is dropped once its prompt is compacted away
or left on another branch; if that was the latest one, the current reminder is
added again after the next prompt that lists the queue. Reminders live in
memory for the current runtime only. Each one is capped at 16 KB (about 85
findings), keeping findings in the queue's stable order and stating how many
were left out.

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
