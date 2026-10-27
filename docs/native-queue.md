# Native finding queue protocol

`memory-queue-worker` is the native review facade for a trusted foreground host. It does not schedule intake, run a model, or establish that an input came from a human. The host owns request identity, exact visible rendering, and the live interactive callback. Pending findings are not approved memories.

## Command and roots

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

## Isolated foreground review

Start Pi with `--memory-queue-review-config /absolute/path/config.json` to select a separate configuration for foreground memory review. This host-owned flag is not a model-facing tool parameter. [The runtime](../Integration/Pi/queued-runtime.ts) captures it at the first session start and keeps that selection across session changes.

An explicit profile keeps interactive review available but does not join background membership or schedule intake. Invalid explicit values fail closed; a rejected profile never falls back to the default configuration. Without the flag, the existing foreground and background paths stay unchanged.

The approved-memory loader has a separate `PI_CORE_MEMORIES_REPO` selection. For an isolated review process, point that variable at the same fixture repository. The review flag alone does not redirect that loader or change saved settings.

## Transport and ownership

All frames are newline-delimited UTF-8 JSON objects. Input frames must be shorter than 65,536 bytes including their newline. Output frames are at most 8 MiB before their newline. The parser rejects duplicate keys, unknown fields, wrong versions, invalid UTF-8, foreign invocations, and malformed frames. Each frame has numeric `version:1`, `type`, and `invocationID`. Boolean `true` is not a version number.

Opaque identifiers match `[A-Za-z0-9._:-]{1,256}`. This includes invocation, session, request, decision, and host-message references. The host can map a longer locator to a stable opaque identifier. Counters in the new queue records are canonical decimal strings. Digests are full lowercase SHA-256 hex. Git object IDs retain their native full length. Byte fields use standard padded base64 without line breaks. Optional Codable fields are omitted when absent, not encoded as null. Legacy `SavedDreamRun` inventory fields retain their existing numeric encoding.

Descriptor 3 must be an inherited, owned anonymous pipe or unnamed connected Unix socket. Named pipes, listening sockets, files, and foreign endpoints fail. The descriptor is close-on-exec before Git runs. Only descriptor 3 accepts `presented`, `choice`, `manage-presented`, and `manage-choice`. Ordinary stdin, model text, restored transcripts, and generated answers cannot approve.

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
| `release` | none | `released` |
| `recover` | `decisionID` | `decision` with checked `receipt` |
| `inventory` | none | `inventory` with `inventory` record |
| `finish` | none | `final` with `status:"completed"`, exit 0 |
| `cancel` | none | closes the invocation without granting consent |

`offset` is a canonical nonnegative decimal string of at most ten characters and cannot exceed the current row count. A page contains at most 64 rows. `nextOffset` is a decimal string or null. Pages are current projections, not a frozen listing transaction. Claims revalidate the exact revision regardless of a previous page.

`sessionID` and `requestID` form the suppression identity. The host must retain both for a resumed request, including retries, tools, compaction, and restart. A fresh runtime incarnation is not permission to invent a new request. Before a genuinely different request, branch change, reload, or amendment, the host must release the old claim and invalidate its callback.

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

## Private display and choice operations

Both private operations include this full tuple in addition to the common header:

```text
claimID, sequence, revision, previewDigest, displayDigest, sessionID, requestID
```

Every value must exactly match the current presentation. Native accepts only one outstanding phase at a time. A queued premature choice, stale tuple, or foreign request closes the invocation.

`presented` adds `messageReference`. The host sends it only after installing the exact visible payload. Native persists the reference and emits `presented` with `displayDigest`. The host waits for that acknowledgement before enabling the live choice.

`choice` adds `action`, `decisionID`, `responseReference`, and Boolean `isInteractive:true`. Actions are `approve`, `reject`, `defer`, or `detach`. The response reference must differ from the display-message reference. `isInteractive` is a trusted host attestation, not native proof of human origin. The private endpoint and claim must never enter model context or background-worker inputs.

`detach` is a separate explicit checkout-preparation choice. It cannot approve memory. After a checked detached receipt, claim and display a fresh preview, then obtain a new explicit choice and decision key. This continuation can use the same request identity. An old yes never authorizes the fresh preview.

`decision` contains a receipt with `decisionID`, `findingID`, `revision`, `displayDigest`, `action`, `status`, and optional `commit` and `auditRef`. Status is `approved`, `rejected`, `deferred`, `detached`, or `outcome-unresolved`. Only `approved` with a checked commit/audit receipt permits reporting a saved memory. A detached receipt is not a memory save.

Before mutation, native persists the exact decision intent. Approval delegates to the existing controller and checked publisher. Recovery verifies the original native audit, preview bytes, and publication. A stored intent or restored draft never authorizes another publication. A duplicate key must use `recover`, not a new choice. Recovery derives and returns the original checked receipt without publishing again. If the outcome cannot be proved, it stays unresolved and suppresses further lineage review. No automatic retry consumes old consent.

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

Descriptor 3 accepts `manage-presented` with the common header, the full queue tuple (`revision` is **currentBase**, not a candidate digest), and `messageReference`. After exact installation and native `manage-presented` acknowledgement, a new live callback may send `manage-choice` with the same tuple plus `action`, `decisionID`, `responseReference`, and Boolean `isInteractive:true`. Action is `approve` or separately `detach`. An attached checkout cannot approve. Detach cannot save memory: after its checked receipt, obtain a new preview/publication and explicit decision. `release`, finish, either EOF, and helper death invalidate active preview authority. There is only one active inferred or management presentation.

`manage-decision.receipt` has `decisionID`, `displayDigest`, `status`, and optional `commit`/`auditRef`. Only `approved` with a checked native batch receipt proves saved memory. `detached` is checkout preparation only; `outcome-unresolved` does not prove mutation. Intent files (`management-<decisionID>.json`) preserve the exact display, native draft, action and opaque live response reference before mutation. Recovery verifies the native journal/publication or detach outcome and never reconstructs approval. On stale base, changed configuration/checkout/bytes, or failed publication, release and obtain a fresh exact preview and explicit decision. Recovered drafts or model/stdin frames cannot approve.

## Versioned changed-evidence successor

Add/update decisions may omit `successor` for legacy responses; generated strict schemas require `successor:null` or this exact object:

```json
{"version":1,"predecessorRevision":"<rejected native revision SHA256>","priorClaim":"<exact prior proposed UTF-8 including source annotations and newline>","newEvidence":[{"source":{"session":"one","entry":"new-entry","part":0},"contentDigest":"<SHA256 exact primaryEvidence.text>"}],"explanation":"The changed claim/condition and how the new evidence changes it."}
```

The native model request supplies `primaryEvidence[].contentDigest`, so callers copy the digest rather than calculating it with the model. Fresh worker capture considers the last seven completed, verified admitted windows from the native generation chain, never an archive scan. Whole windows must connect by session or nonempty project scope, fit the existing 1,000-record / 262,144-byte connected-evidence and 4 MiB batch-binding limits, and have source paths verified by the current admitted intake. Scope resolutions, eligible memory snapshots, and owner locators cover the selected evidence union. Prior windows are marked `isCurrentWindow:0`; only the current batch advances progress. A source outside current verified intake, including legacy unprojected history, is omitted with a limitation rather than promoted to primary evidence.

`rejectedPredecessorsNotPrimaryEvidence`, when present, contains at most 64 entries and 262,144 encoded bytes. Each entry carries the exact native `revision`, memory `path`, UTF-8 `priorClaim` (including annotations and newline), and `sourceSessions`. Entries come from the bound native queue and its rejected review selections, corroborated against completed source-chain candidates; they are never primary evidence or approval. Their evidence must share the captured session/scope, belong to the eligible memory snapshot, and have a currently verified admitted source view. Existing rejected rows and pending suggestions are retained unchanged when their source context cannot be supplied. The optional catalogue and related batches are frozen into the context hash; empty catalogues omit the new fields to preserve existing frozen bytes.

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

After its acknowledgement and a new live explicit human choice, send on descriptor 3:

```json
{"version":1,"type":"choice","invocationID":"fixture-review","claimID":"<claimID>","sequence":"<sequence>","revision":"<revision>","previewDigest":"<previewDigest>","displayDigest":"<displayDigest>","sessionID":"fixture-session","requestID":"fixture-request","action":"approve","decisionID":"fixture-save-1","responseReference":"fixture-human-response","isInteractive":true}
```

If the host loses the result, reconnect with the same configuration and use stdin:

```json
{"version":1,"type":"recover","invocationID":"fixture-recovery","decisionID":"fixture-save-1"}
```

`MemoryQueueTests.swift`, `MemoryQueueAuthorityTests.swift`, and `MemoryQueueWorkerTests.swift` exercise this protocol with isolated synthetic stores and anonymous control pipes. Native protocol tests do not establish installed host visibility, request provenance, background scheduling, or application-retirement acceptance.
