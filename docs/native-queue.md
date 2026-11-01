# Native finding queue protocol

`memory-queue-worker` is the internal storage and approval protocol for the foreground conversation. It is not a slash command, review mode, or user-operated queue. It does not schedule intake, run a model, or establish that an input came from a human. The conversation adapter owns request identity, exact chat presentation, and the later explicit reply. Pending findings are not approved memories.

The Pi consumer uses public extension interfaces and does not require a Pi fork. It keeps one native worker across proposal presentation and a later ordinary-chat reply. The adapter supplies the original and submitted texts from its captured input and durable user-message record, bound to the current proposal. Model arguments, an interactive source label alone, restored messages, and autonomous guidance cannot supply that authority. Missing public interfaces or failed association checks block publication, with no direct-write fallback. Candidate wording changes retain the original finding and evidence and use the amendment flow below. A separate dialog or manual command is not an alternate route.

## Internal worker and roots

The command accepts no arguments:

```sh
pi-core-memories memory-queue-worker
```

The first stdin frame has exactly these fields:

```json
{"version":1,"type":"start","invocationID":"fixture-review","config":"/tmp/memory-queue-fixture/config.json"}
```

`config` is an absolute configuration filename or JSON `null` for `MemoryConfiguration.defaultURL`. Configuration is loaded once. No cwd-derived queue, root flags, approval flag, or caller-supplied binding is accepted. `MemoryConfiguration.reviewSources()` resolves the saved dream roots and verifies their repository/source binding. Existing configuration fields remain authoritative. The queue directory is `reviewState + ".queue"`, outside the repository, sessions, stripping roots, dream state, review state, and journal.

First verified queue access pins the actual review/source/repository binding and queue directory identity in `<canonical Git common directory>/memory-queue/binding.json`. The stable `writer.lock` in that private directory serializes activation with native publication. Different review profiles for the same repository fail rather than create another authority. Retargeting a root or replacing its inode also fails. There is no automatic rebind or reconciliation command.

`MemoryReviewController` checks this binding at initialization and refresh. `MemoryStore.publishCheckedMemoryCommit` holds the repository authority lock through checked publication. A bound repository requires the matching native controller binding. No wire request can supply that proof. Unbound publication semantics remain unchanged.

Direct `manage` mutations and legacy manual draft Save have no review-profile proof and cannot publish after binding. List/get and checked historical recovery remain available. A supported matching-profile path is `MemoryBatchSession(repository:drafts:review:...)` with the actual verified controller, fresh per-item authorization, and `save()`. It supports requested additions, updates, deletions, and confirm-reviewed changes through the existing batch types. The private management operations below expose that matching-profile path; legacy `manage` mutation remains fenced.

## Conversation and background ownership

[The runtime](../Integration/Pi/queued-runtime.ts) connects ordinary interactive sessions to background dreaming. Each window marks its own live session; the native worker's exclusive run lock (`<dream state>.run`), held for the whole run, makes one window the dreamer at a time. The dream state's writer lock is held only for short phases and is released during the model call. There is no review-only launch flag or alternate Pi review configuration.

Native configuration and migration APIs remain available to the internal worker and isolated protocol tests. They do not create a user-facing mode or authorize model calls. The approved-memory loader uses `PI_CORE_MEMORIES_REPO` independently; verification must isolate every affected store without changing personal settings or bypassing host approval.

## Public Pi conversation adapter

Supported package versions are the [peer dependencies](../package.json). The
adapter registers no commands, review mode, or modal fallback.

`registerMessageRenderer` and `sendMessage` put the exact escaped proposal in
the normal transcript. Before a private acknowledgement, the adapter requires
one matching durable custom message: current proposal identity, exact complete
content, visible display flag, and the same branch. A context hook excludes
these proposal-control messages from model input without removing their display.

Public `input`, `before_agent_start`, and `message_start` events bind a later
reply. The adapter requires idle interactive input, no queued delivery or
attachments, an unchanged prompt, a started ordinary user turn, and the same
user-message object and text in the durable branch. Exactly one user message
can follow the captured leaf. Amendments use the same single-use check before
any private display acknowledgement or draft change.

These are association checks inside the trusted Pi process, not authentication
of a person or proof of painted pixels or reading. Other loaded extensions and
programmatic session owners remain trusted. A model cannot replace the private
captured-input record through tool arguments. A missing or transformed record,
a changed proposal, restart, branch change, or session death invalidates it.

## Transport and ownership

All frames are newline-delimited UTF-8 JSON objects. Input frames must be shorter than 65,536 bytes including their newline. Output frames are at most 8 MiB before their newline. The parser rejects duplicate keys, unknown fields, wrong versions, invalid UTF-8, foreign invocations, and malformed frames. Each frame has numeric `version:1`, `type`, and `invocationID`. Boolean `true` is not a version number.

Opaque identifiers match `[A-Za-z0-9._:-]{1,256}`. This includes invocation, session, request, decision, and host-message references. The host can map a longer locator to a stable opaque identifier. Counters in the new queue records are canonical decimal strings. Digests are full lowercase SHA-256 hex. Git object IDs retain their native full length. Byte fields use standard padded base64 without line breaks. Optional Codable fields are omitted when absent, not encoded as null. Legacy `SavedDreamRun` inventory fields retain their existing numeric encoding.

Descriptor 3 must be an inherited, owned anonymous pipe or unnamed connected Unix socket. Named pipes, listening sockets, files, and foreign endpoints fail. The descriptor is close-on-exec before Git runs. Only descriptor 3 accepts `presented`, `reply`, `manage-presented`, and `manage-reply`. The retired `choice` and `manage-choice` frames are rejected, including frames that assert `isInteractive:true`. Ordinary stdin, model text, restored transcripts, and generated answers cannot approve.

One live controller owns the whole review store from successful `claim` through disposition or release. Other owners receive `busy`. List and inventory normally acquire ownership only for their operation, so they can also report busy during another session's review. Queue file locks are short-lived and never held while waiting for a person. No heartbeat timeout steals a live lock. EOF on either host channel, explicit finish/cancel, helper death, and settled choices release ownership. A connected hung host remains busy until it releases or closes.

## Ready and inventory-only mode

Successful start emits:

```json
{"version":1,"type":"ready","invocationID":"fixture-review","policyVersion":1,"ownership":"whole-store","successors":"source-bound-v1","isReviewAvailable":true,"reason":null}
```

If verified dream-source initialization is unavailable, `isReviewAvailable` is false and `reason` is `"verified dream sources unavailable; inventory only"`. Only stdin `inventory`, `approved-list`, `approved-get`, and `finish` are then accepted. This mode creates no controller, repository binding, or queue state. It can report retained manual drafts and ref-only proposals without inventing evidence. It is blocked migration inventory, not completed migration or review.

## Stdin operations

Every row below adds fields to `{version:1,type,invocationID}`. Fields are exact, not optional unless stated.

| Type | Additional fields | Result |
| --- | --- | --- |
| `list` | `sessionID`, `requestID`, `offset` | `queue` with `rows` and `nextOffset` |
| `claim` | `sessionID`, `requestID`, `revision` | `presentation` |
| `amend` | current presentation tuple and `amendment:{replacement,reason}` | replacement `presentation`; no decision |
| `release` | none | `released` |
| `recover` | `decisionID` | `decision` with checked `receipt` |
| `counts` | none | `counts` with `review`; refused while a presentation is open |
| `inventory` | none | `inventory` with `inventory` record |
| `finish` | none | `final` with `status:"completed"`, exit 0 |
| `cancel` | none | closes the invocation without granting consent |

`offset` is a canonical nonnegative decimal string of at most ten characters and cannot exceed the current row count. A page contains at most 64 rows. `nextOffset` is a decimal string or null. Pages are current projections, not a frozen listing transaction. Claims revalidate the exact revision regardless of a previous page.

`sessionID` and `requestID` form the suppression identity. The host must retain both for a resumed request, including retries, tools, compaction, and restart. A fresh runtime incarnation is not permission to invent a new request. Before a genuinely different request, branch change, or reload, the host must release the old claim and invalidate its live reply authority. A candidate wording amendment instead keeps the same request and review owner and invalidates the old preview.

A row has `finding`, `disposition`, and optional `blockReason`. Dispositions are the existing native pending/deferred/rejected/approved/blocked projection. Block reasons include `already-presented-for-request`, `outcome-unresolved`, the native target limitation, and `blocked-successor: rejected evidence or claim requires a versioned changed-evidence successor`.

### Finding record

`finding` contains these fields:

- `findingID`, `revision`, `candidateID`, and `relatedRevisions` retain lineage and original candidate provenance. The revision is the verified native candidate digest. Existing revisions never change.
- `path`, `operation`, `frozenBase`, base64 `before`, base64 `proposed`, `claimDigest`, and `reason` retain the exact unapproved change.
- `evidence` retains each primary source's `identity`, `contentDigest`, `session`, `entry`, decimal `part`, `kind`, ISO-8601 `timestamp`, optional `projectScope`, `exactText`, `relativePath`, decimal `start` and `end`, `recordDigest`, and optional separately labeled `agentContext`.
- `contradictions` contains `kind`, optional `evidence`, optional base64 `anchor`, and `explanation`. Primary conflicts contain full source evidence. A memory anchor decodes to a canonical JSON string array `[scopePath, documentDigest, start, end, before]`. An owner anchor decodes to `[key, ownerDigest, start, end, before, reference, scopePath]`.
- `limitations`, `inputDigest`, `contextDigest`, and `responseDigest` retain native frozen coverage and analysis provenance. Stored references are not independently verified evidence.

Tool/related-window evidence uses the integrated native input component's verified primary-evidence contract. Observed tool activity is not human intent or consent. Optional `successor` retains the complete versioned hint below; optional `suppressionEpoch` identifies an admitted changed-evidence epoch, and optional `successorRejections` freezes exactly which rejected revisions its proof covered.

### Presentation record

`presentation` emits `display` and `displayBytes`. `display` has `presentation` and `displayDigest`. `displayBytes` is base64 of the exact canonical JSON bytes of `display.presentation`, encoded with sorted keys and unescaped slashes. SHA-256 of the decoded bytes equals `displayDigest`. The host can verify bytes directly without reproducing Swift JSON serialization.

The presentation contains `claimID`, decimal `sequence`, `request:{sessionID,requestID}`, full `finding`, `previewDigest`, `currentBase`, base64 `before`, base64 final `after`, base64 full-document `replacement`, Boolean `isDetachRequired`, `checkoutCommit`, and `checkoutDigest`.

The host must display the complete exact proposal and annotations, old/final bytes, scope, reason, evidence, contradictions, and limitations. Base64 is a transport encoding, not a substitute for readable exact bytes. Escape terminal controls and bidirectional formatting deterministically without changing stored bytes or hashes. Do not paraphrase, trim, summarize, truncate, or reorder the proposal for consent. If the complete payload cannot be installed, release without approval.

Native reserves shown-for-request suppression before emitting the presentation. A crash around display can therefore suppress a question that was never visible. It never grants approval.

### Wording amendments

Stdin `amend` requires the complete current presentation tuple and an exact
`amendment:{replacement,reason}` object. Both values are plain text, not base64.
The native entry checks and frame limits still apply. Every original source
annotation must remain. The original finding, revision, and evidence do not
change.

Only the live owner of an acknowledged presentation can amend it. Native keeps
that owner and claim, invalidates the old preview, and returns a new sequence,
preview digest, display digest, and final bytes. The presentation also includes
`amendmentReason`; the original `finding.reason` remains unchanged. A later claim
of the retained draft includes the same amendment reason. Both reasons are visible
and covered by the native display digest. The host must display the new
exact proposal, acknowledge it with `presented`, and obtain a later explicit
reply. Amendment alone cannot save memory or reuse an earlier reply.

The existing queue ledger retains one unapproved amendment per finding revision.
A later claim uses that draft to build a fresh preview. Restart does not restore
ownership, a display acknowledgement, or approval. Original source artifacts and
prior decisions remain intact. Do not remove amendment fields to make an older
reader accept the ledger.

## Private display and original-reply operations

Both private operations include this full tuple in addition to the common header:

```text
claimID, sequence, revision, previewDigest, displayDigest, sessionID, requestID
```

Every value must exactly match the current presentation. Native accepts only one outstanding phase at a time. A queued premature choice, stale tuple, or foreign request closes the invocation.

`presented` adds `messageReference`. The host sends it only after installing the exact visible payload. Native persists the reference and emits `presented` with `displayDigest`. The host waits for that acknowledgement before accepting a later explicit user reply for the exact displayed proposal.

`reply` adds `originalText`, `submittedText`, `decisionID`, and `responseReference`. It accepts no action, approval flag, or input-source label. The installed adapter must obtain both texts from its live proposal-bound input record, not a model argument. The response reference must differ from the display-message reference. Private endpoints, live control handles, and acknowledgement fields must not enter model context or background-worker inputs. The user's reply remains an ordinary user message; its presence in chat does not replace the private association checks. Owning the endpoint does not prove human identity.

The Swift interpreter derives the decision from the complete original reply and the immutable native operation. It recognizes a small family of unconditional memory-specific expressions, such as saving a displayed addition, forgetting a displayed deletion, rejecting a memory suggestion, or leaving it for later. An explicit approval of the displayed memory change can approve that exact operation. Case, whitespace, and modest polite wording do not require a command or menu. This is not a general natural-language interpreter.

Bare agreement, quoted instructions, conditions, corrections, multiple actions, or disagreement between original and submitted text do not authorize a change. Native emits `reply-clarify` with `status:"no-decision"` and retains the same claim and acknowledged preview. A later bare yes remains insufficient; asking a clarification does not establish which conversational question it answers. A new operation-specific reply may continue the same unchanged proposal. A candidate wording change uses `amend` and a fresh exact preview without releasing its owner. No decision intent is written for clarification.

`detach` is a separate explicit checkout-preparation choice. It cannot approve memory. After a checked detached receipt, claim and display a fresh preview, then obtain a new explicit choice and decision key. This continuation can use the same request identity. An old yes never authorizes the fresh preview.

`decision` contains a receipt with `decisionID`, `findingID`, `revision`, `displayDigest`, `action`, `status`, and optional `commit` and `auditRef`. Status is `approved`, `rejected`, `deferred`, `detached`, `needs-decision`, or `outcome-unresolved`. `needs-decision` means the decision was not applied (the proposal changed or the apply failed before publication) and does not count; the finding returns for a new exact decision. Only `approved` with a checked commit/audit receipt permits reporting a saved memory. A detached receipt is not a memory save.

Before mutation, native persists the exact decision intent, marked as immediate. Approval delegates to the existing controller and checked publisher. Recovery verifies the original native audit, preview bytes, and publication. A duplicate key must use `recover`, not a new choice. Recovery derives and returns the original checked receipt without publishing again. The decision is applied while the reply is handled; a reply during a dream waits for the dream's short writer phase. That wait ends when the invocation is cancelled or after 300 seconds, longer than a normal writer phase (source protection checks can take about 160 seconds); the reply then gets `outcome-unresolved` if the dream still holds the lock, and the intent is settled as described below. If the apply fails before publication, the intent gets a `needs-decision` receipt and suppresses no later review; a later published result replaces it. On first queue access after upgrade, each legacy journaled intent (one with a decision clock and no receipt) is applied once with the same native validation as an immediate reply against the exact displayed preview, presentation receipt, and decision clock; if that access is busy (dream writer lock, lease, or ledger wait), it returns busy and the intent is applied on a later access; afterwards no intent is applied later. This never creates new consent, and a failed validation or apply gives `needs-decision`. An immediate intent left without a receipt by a crash between recording and applying, or by an abandoned lock wait, also gets `needs-decision` on the next queue access, after the same fresh proof that nothing was published. A restored draft never authorizes another publication. Legacy intents without a decision clock or immediate marker, and management intents, are never re-applied: if their outcome cannot be proved, it stays `outcome-unresolved` and suppresses further lineage review.

## Approved-memory management

All operations use the same worker/configuration and common header. Read operations remain useful without verified dream sources and do not create queue authority:

| Stdin type | Additional fields | Result |
| --- | --- | --- |
| `approved-list` | none | `approved` with `result` (native committed base and exact entries, including immutable limitations) |
| `approved-get` | `request` | `approved` with `result`; request must be the exact native `get` shape |
| `manage-preview` | `sessionID`, `requestID`, `mode`, `request` | `manage-presentation` with `display` and base64 `displayBytes` |
| `manage-recover` | `decisionID` | `manage-decision` with checked `receipt`; never publishes |

`mode` is `crud` or `confirm-reviewed`. CRUD request objects are the existing exact `MemoryManagementRequest.decode` shapes (no extra or omitted fields):

- add: `{operation:"add",base,path,replacement,reason}`
- update: `{operation:"update",base,path,locator:{start,end},expected,replacement,reason}`
- delete: `{operation:"delete",base,path,locator:{start,end},expected,reason}`
- get / confirm-reviewed: `{operation:"get",base,path,locator:{start,end},expected}`

Offsets are native numeric UTF-8 byte offsets. Expected/replacement values are exact UTF-8 strings. A CRUD preview permits only add/update/delete; confirm-reviewed uses the exact get target and stages native fresh confirm-reviewed authority. Base, locator, scope and source-annotation preservation are checked by the existing facade. Changes use the actual configured controller and journal; no arbitrary roots or replacement memory store are accepted.

The management `display` is a flat object containing `claimID`, decimal `sequence`, `request:{sessionID,requestID}`, `operation`, `reason`, scope `path`, `currentBase`, base64 effect `before`/`after`, base64 full-document `documentBefore`/final `replacement`, `previewDigest`, `isDetachRequired`, `checkoutCommit`, `checkoutDigest`, and `displayDigest`. `displayBytes` is the canonical sorted-key, unescaped-slash JSON object with **only `displayDigest` removed**. SHA-256(decoded displayBytes) equals displayDigest. Verify these native bytes rather than recreating JSON. Display all exact decoded before/final/annotation/scope bytes and reason before enabling the choice. Base64 alone, truncation, paraphrase, partial text, or hidden attachments do not constitute publication.

Descriptor 3 accepts `manage-presented` with the common header, the full queue tuple (`revision` is **currentBase**, not a candidate digest), and `messageReference`. After exact chat presentation and native acknowledgement, `manage-reply` carries that tuple plus `originalText`, `submittedText`, `decisionID`, and `responseReference`. It uses the same original-reply interpreter as inferred findings. Clear intent can approve the exact operation or separately prepare checkout detachment. An unclear reply retains the preview and emits `reply-clarify`. Rejection or deferral releases the manual proposal and emits `manage-cancelled` with `status:"not-saved"`, without inventing a saved or queue-disposition receipt.

An attached checkout cannot approve. Detach cannot save memory: after its checked receipt, obtain a new preview and a new explicit decision. `release`, finish, either EOF, and helper death invalidate active preview authority. There is only one active inferred or management presentation.

`manage-decision.receipt` has `decisionID`, `displayDigest`, `status`, and optional `commit`/`auditRef`. Only `approved` with a checked native batch receipt proves saved memory. `detached` is checkout preparation only; `outcome-unresolved` does not prove mutation. Intent files (`management-<decisionID>.json`) preserve the exact display, native draft, action and opaque live response reference before mutation. Recovery verifies the native journal/publication or detach outcome and never reconstructs approval. On stale base, changed configuration/checkout/bytes, or failed publication, release and obtain a fresh exact preview and explicit decision. Recovered drafts or model/stdin frames cannot approve.

## Versioned changed-evidence successor

Add/update decisions may omit `successor` for legacy responses; generated strict schemas require `successor:null` or this exact object:

```json
{"version":1,"predecessorRevision":"<rejected native revision SHA256>","priorClaim":"<exact prior proposed UTF-8 including source annotations and newline>","newEvidence":[{"source":{"session":"one","entry":"new-entry","part":0},"contentDigest":"<SHA256 exact primaryEvidence.text>"}],"explanation":"The changed claim/condition and how the new evidence changes it."}
```

The native model request supplies `primaryEvidence[].contentDigest`, so callers copy the digest rather than calculating it with the model. Fresh worker capture considers the last seven completed, verified admitted windows from the native generation chain, never an archive scan. Whole windows must connect by session or nonempty project scope, fit the existing 1,000-record / 262,144-byte connected-evidence and 4 MiB batch-binding limits, and have source paths verified by the current admitted intake. Scope resolutions, eligible memory snapshots, and owner locators cover the selected evidence union. Prior windows are marked `isCurrentWindow:0`; only the current batch advances progress. A source outside current verified intake, including legacy unprojected history, is omitted with a limitation rather than promoted to primary evidence.

`rejectedPredecessorsNotPrimaryEvidence`, when present, contains at most 64 entries and 262,144 encoded bytes. Each entry carries the exact native `revision`, memory `path`, UTF-8 `priorClaim` (including annotations and newline), and `sourceSessions`. Entries come from the bound native queue and its rejected review selections, corroborated against completed source-chain candidates; they are never primary evidence or approval. Their evidence must share the captured session/scope, belong to the eligible memory snapshot, and have a currently verified admitted source view. Existing rejected rows and pending suggestions are retained unchanged when their source context cannot be supplied. The optional catalogue and related batches are frozen into the context hash; empty catalogues omit the new fields to preserve existing frozen bytes.

`priorDreamNotesNotPrimaryEvidence` and `priorFindingsNotPrimaryEvidence` give each new request a short memory of earlier dreams, so the model does not propose a duplicate and can see recurring themes. Notes come from completed runs in the verified generation chain, newest first: at most 40 notes and 12,288 encoded bytes. Findings are the bound native queue rows that are pending, deferred, or rejected (approved rows are left out), newest first: at most 24 findings and 16,384 encoded bytes. Each text field is cut to 1,024 UTF-8 bytes. Capture first removes items from live sessions, then keeps the newest items within the caps, then checks each kept item: every source file must still exist and its latest admitted prefix (`originalCompleteBytes`, `originalPrefixHash`) must still match. The check streams a SHA-256 hash once for each path; it does not load whole files. An item that fails is left out. Each section reports `omitted` counts by reason: `overBudget`, `liveSession`, `unverifiedSource`. New requests use request rendering version 6 (`renderingVersion: 6`). Version 6 retains version 5's prior-dream sections and prompt. It supplies each source's allowed no-change reasons and eligible proposal scopes, plus reason meanings in the decision schema. Version 5 is version 4 (the stuck-agent prompt) plus both sections (empty when there is no history) and one extra prompt paragraph after the stuck-agent paragraph. Saved version 3, 4, and 5 requests still verify unchanged; version 3 and 4 renderings refuse a context that has prior history. The selected history is frozen into the context hash, and a retry replays it without a new check.

Current live-session exclusions apply to prior windows and catalogue entries before source protection or model delivery, including frozen retries. Exact retained source pieces and catalogue bytes must pass unchanged source protection: newly registered secrets block the run, never cause a redacted substitute for exact `priorClaim`. Legacy unprojected current input retains its existing exact-byte protected retry path; it is not eligible as historical evidence in new requests. Frozen input, request, and pending suggestions are never rewritten to substitute a newly protected view. Every selected new source must be unique, present in the native pinned catalogue, and a supporting source of this proposal; its digest must equal SHA-256 of its exact primary text. Existing native saved-source verification still applies before claim/publication. The hint is metadata, never approval.

Queue admission additionally requires a currently rejected, same-scope predecessor, byte-exact priorClaim, changed unannotated claim digest, a nonempty bounded explanation, and at least one supporting identity **and exact content digest** absent from the predecessor's connected historical evidence (including primary contradictions). A copied identical text under a new identity fails. Every connected rejected revision must be covered by that predecessor lineage/its previously frozen rejection exclusions; an unrelated rejected lineage bridged by the new proposal stays blocked. One epoch is admitted per predecessor. Repeated hints cannot reset rejection; only the same changed claim with the admitted new source proofs inherits that epoch, while old-only evidence remains suppressed. Rejecting the admitted epoch blocks repeated runs and future requests until a genuinely new successor proof covers that newer rejection.

The explanation must identify an actual changed claim or condition and the relevance of new evidence; unrelated evidence, rereads, rewording and overlapping analysis alone are prohibited by model policy. **Native verifies structural source/byte novelty, not semantic truth, causal relevance, or natural-language equivalence.** Rephrased/copied evidence with different bytes is not semantically detected. The foreground must publish the exact prior claim, explanation, new evidence and limitations, and obtain fresh explicit approval through the unchanged private channel. Native supplies the bounded predecessor context, but does not autonomously choose or approve the model's successor hint.

## Errors and lifetime

Recoverable operation failures emit `blocked` with `code:"busy"` or `code:"blocked"`. A choice whose receipt cannot be established emits `blocked` with `code:"outcome-unresolved"` and `decisionID`. Some recoveries return a `decision` receipt whose status is `outcome-unresolved`. Neither form means saved. Read the current row or inventory for retained limitations rather than interpreting a generic blocked result as success.

Protocol, control-channel, startup, or binding failures can end with `final`, `status:"failed"`, and `code:"protocol-or-binding-failure"`, exit 1. A binding failure during an operation is a recoverable generic `blocked`. EOF/cancel also ends the invocation as failed, without consent. No raw private path or payload is included in error diagnostics. Release is idempotent. A failed ordinary operation does not necessarily release an existing claim; explicit release or channel close does. A consumed choice releases even when its outcome needs recovery.

## Recurrence and migration

Within a target path, overlapping supporting/contradictory source identities, exact source-content digests, lineage IDs, and equal unannotated claim digests connect revisions transitively. Rejection suppresses that connected lineage. New response hashes, base commits, rewording, and adding evidence without the source-bound successor proof below do not reopen it. This is structural byte/content novelty, not semantic equivalence detection for disjoint rephrased evidence.

Deferral and cancelled display suppress the connected lineage for the same request across restart. A later genuinely relevant request can reconsider a deferred finding. No timer, fixed question quota, or minimum occurrence count is used.

Inventory has `schemaVersion`, `mode`, `approvedBase`, `refs`, `artifacts`, `runs`, `candidateRevisions`, and optional `limitation`. Refs are `[refName, objectID, symbolicTarget]`. Artifact locators are `(source,name)`, relative to configured `reviewState`, `journal`, or dream `state`; proposal locators are full native refs. File artifacts carry SHA-256 `digest` and decimal `byteCount`. Proposal artifacts carry the Git object ID and byteCount `"0"`, not an invented byte length. Every artifact includes a limitation.

Verified mode imports completed candidates into an additive queue projection and reads prior native dispositions. It records immutable hash-named inventory manifests. Original review decisions, attempts/outcomes, journal revisions, batch drafts, dream admissions, replies, receipts, generations, and incomplete calls stay in their existing authorities. Approved history and evidence bytes are not rewritten. Missing, unsafe, corrupt, oversized, or busy source state fails closed. Inventory does not reset progress or resume a model call.

Ref-only/manual/unsupported lineage stays retained with missing-evidence limitations. Inventory-only mode does not create finding revisions for it. The parent adapter must keep these visible as blocked migration items until original native recovery establishes lineage and a fresh review occurs. No artifact is silently promoted to approved memory. There is no destructive activation switch, export, cleanup, or safe automatic rollback after new queue writes.

Queue files use existing private durable file primitives and kernel locks. The ledger has the existing 8 MiB per-file and 64 MiB retained-state caps and at most 10,000 revisions. Inventory traversal is bounded. Capacity failures retain prior state and block; this version does not compact or evict pending evidence or decisions.

## Synthetic exchange

This exchange uses values copied from native output. Angle-bracket values are placeholders, not literal valid digests or capabilities.

```json
{"version":1,"type":"list","invocationID":"fixture-review","sessionID":"fixture-session","requestID":"fixture-request","offset":"0"}
{"version":1,"type":"claim","invocationID":"fixture-review","sessionID":"fixture-session","requestID":"fixture-request","revision":"<row.finding.revision>"}
```

After the `presentation` is fully installed, send on descriptor 3:

```json
{"version":1,"type":"presented","invocationID":"fixture-review","claimID":"<claimID>","sequence":"<sequence>","revision":"<revision>","previewDigest":"<previewDigest>","displayDigest":"<displayDigest>","sessionID":"fixture-session","requestID":"fixture-request","messageReference":"fixture-display"}
```

After its acknowledgement, the synthetic fixture can supply the following original reply on descriptor 3. A production adapter must obtain the text from its eligible captured input and matching durable user message, not copy this example as approval:

```json
{"version":1,"type":"reply","invocationID":"fixture-review","claimID":"<claimID>","sequence":"<sequence>","revision":"<revision>","previewDigest":"<previewDigest>","displayDigest":"<displayDigest>","sessionID":"fixture-session","requestID":"fixture-request","originalText":"Save that memory","submittedText":"Save that memory","decisionID":"fixture-save-1","responseReference":"fixture-original-response"}
```

If the host loses the result, reconnect with the same configuration and use stdin:

```json
{"version":1,"type":"recover","invocationID":"fixture-recovery","decisionID":"fixture-save-1"}
```

`MemoryQueueTests.swift`, `MemoryQueueAuthorityTests.swift`, and `MemoryQueueWorkerTests.swift` exercise this protocol with isolated synthetic stores and anonymous control pipes. Native protocol tests do not establish installed host visibility, request provenance, background scheduling, or application-retirement acceptance.
