# pi-core-memories

A native Mac app and Swift store for approved Markdown memory in a separate private Git repository.
The Pi integration loads approved memory and runs inspectable dreams.
The Swift core uses Foundation, CryptoKit, and system Git without external Swift dependencies.

See [build and setup](docs/native-app.md) for the app, command runtime, and Pi package.
The [native finding queue protocol](docs/native-queue.md) defines durable conversational review, private choices, and blocked migration inventory.

## Store and documents

`MEMORY.md` holds global memory. `projects/<key>.md` holds one project's memory.
`devices/<device-key>/MEMORY.md` holds device-wide memory.
`devices/<device-key>/projects/<key>.md` holds project memory for that device.

The default project key is the full lowercase SHA-256(Secure Hash Algorithm, 256-bit) of Git's canonical common-directory path.
Linked worktrees and path aliases of the same repository share a key.
An explicit local project binding can reuse a shared key across devices or moves.
Without a binding, a new canonical path changes the key.
Outside Git, rendering includes global memory and the configured device-wide layer.

Use ordinary Markdown headings, paragraphs, lists, and references:

```markdown
# Memory

The code-style document is the owner for code conventions.
[source: docs/code-style.md; added: 2026-08-01]
```

Each paragraph or list item needs `[source: <reference>; added: YYYY-MM-DD]`.
Facts can span lines. Headings and reference definitions need no annotation;
a header-only `MEMORY.md` is valid. The checker validates nonempty source syntax,
real calendar dates, regular files, and allowed memory paths. Keep only these
memory files in the committed data tree.

It does not check citation truth or claim that a saved `role=user` message came
from a human. It never opens sources.
Point to an existing instruction owner instead of copying its rule.

## Commands

Set `memory_repo` to the separate data repository path and `project` to the
project directory. Do not place the data repository inside another Git repository.

```zsh
pi-core-memories init --repo "$memory_repo"
pi-core-memories project-key --cwd "$project"
pi-core-memories render --repo "$memory_repo" --cwd "$project"
pi-core-memories check --repo "$memory_repo"

base=$(git -C "$memory_repo" rev-parse refs/heads/main)
pi-core-memories propose --repo "$memory_repo" --base "$base" \
  --file MEMORY.md --reason 'Point to the instruction owner' \
  --contradictions 'An older entry copies the rule' < candidate.md
pi-core-memories review --repo "$memory_repo" "$proposal_commit"
```

`init` is explicit. It refuses occupied directories, symlink destinations, and
paths inside another repository without changing their bytes or permissions.
It removes lexical dots and trailing separators before checking the final destination,
so `alias/.` cannot hide a symlink. Ancestor aliases remain supported.

After these checks, it sets new or accepted empty directories to `0700` and
creates `MEMORY.md` with `0600` before writing memory. It creates main and an
empty `MEMORY.md` commit.
`project-key` prints a key, or reports no key with a nonzero exit outside Git.

`render` resolves `refs/heads/main` once, then appends global, matching project,
current-device, and matching device-project documents from that commit. Dirty files and proposal checkouts cannot
supply memory. A missing repository, main, or global document is an error.

`check` validates all committed approved files, not the working tree. Success is
silent. Failures print `FAIL <path>: <reason>` to standard error and exit nonzero.
Check diagnostics and command errors escape terminal controls with the same
`\u{HEX}` display as human review. Stored bytes stay exact.
No read command initializes a store.

`propose` accepts exact replacement Markdown on standard input. Its base must be
the full current main commit identifier. It accepts only the memory paths listed above,
with full lowercase hexadecimal keys. It refuses invalid paths, bytes, metadata,
stale bases, and replacements with no change.

The approved base must contain a regular `MEMORY.md` and only allowed regular memory files. An ordinary code
repository is not a proposal target. Each proposal changes one file.
Separate calls can propose separate candidates.

An existing memory document can have invalid annotations. A proposal can repair
those annotations for human review, without changing the approved base.

Proposals build Git trees with `mktree -z`, not an index.
They preserve main, the human HEAD and its reflog, the index and its shared-index
files, repository configuration, and working files. Only the target entry gets the new blob and mode `100644`;
other entries keep their modes and blob identifiers. Git sorts the tree entries.
Git calls remove inherited `GIT_*` routing variables.

Both Git execution paths disable hooks, commit signing, and filesystem monitors,
including repository-local `core.fsmonitor` commands. Ref transactions use a private
detached HEAD with the authoritative common ref and object directory.
They set `GIT_NO_LAZY_FETCH=1`
regardless of inherited values. Missing objects fail without fetching from a
promisor remote; complete local stores still work.
Publication checks main and creates the new proposal ref in one Git transaction.

Creation and duplicate verification use `--no-deref` and reject symbolic main or
proposal refs while Git holds the prepared transaction's locks. They do not update
an alias target or replace a symbolic ref. Transactions wait up to five seconds
for each ref lock.
The command prints `ref:`, `commit:`, and `base:`.
Set `proposal_commit` to the printed commit identifier before review.

The commit holds the exact reason
and known contradictions as escaped metadata, separate from the Markdown file.
The tool fixes proposal identity and Git dates so identical input and base return
the same `refs/heads/proposals/<commit>`; the Git date is not an event timestamp.

## Exact proposal receipt recovery

`MemoryStore.recoverProposal(base:path:replacement:reason:contradictions:)` is a
library-only boundary. Supply the exact saved base, allowed target path,
replacement bytes, reason, and contradictions. It derives the same deterministic
commit and `refs/heads/proposals/<commit>` as `propose`. It verifies only that
exact direct ref, sole parent, metadata, target bytes and mode `100644`, and
single changed path. The base must still have the dedicated memory-store layout.

A valid published ref returns its original ref, commit, and base even after a
human fast-forward advances main. Recovery does not require current main to
match the saved base. An absent exact ref returns `nil`, including when the
commit exists only as an orphan object. Symbolic, conflicting, or malformed refs
fail without repair. Recovery does not scan refs or accept a caller's receipt.

Recovery can write deterministic local blobs, trees, and commit objects to derive
identity; it is not fully read-only. It never creates, changes, or deletes refs,
merges memory, or changes main, the human index, configuration, or working files.
It uses the same isolated Git execution and locked direct-ref verification as
publication. The existing `propose` command still refuses stale main before
constructing objects or checking duplicates. Recovery adds no command, model call,
decision validation, saved-run completion, or progress installation.

## Session census

`dream-scan` is a separate read-only census, not the `/dream` checkpoint. It reads
Pi session files and prints a JSON census with sorted keys. It makes no model
calls, keeps no run state, and writes no proposals.

```zsh
pi-core-memories dream-scan --sessions ~/.pi/agent/sessions \
  --snippets ~/.pi/agent/extensions/prompt-snippets/snippets \
  --prompts ~/.pi/agent/prompts --samples 0
```

It opens `*.jsonl` files exactly two levels under `--sessions` that changed after
`--since` (ISO 8601, default 30 days ago). Only entries after `--since` produce
units; older entries are context. `--samples <n>` copies up to `n` human texts per
evidence label into the census; the default is 0. A `--snippets` or `--prompts` folder
with no usable Markdown file is an error.

A table of rules classifies each session:

1. A name that starts with `om-observer-`, `om-consolidator-`, or `comment-shape-`
   is infrastructure. The reader stops after the header.
2. A header with `parentSession` is a child.
3. A name such as `code-reviewer#938949b9` is a child.
4. Any other session is primary.

Only primary sessions supply human evidence: typed text, skill arguments, and
`ask_user_question` answers. The reader removes skill bodies, attached file
blocks, and prompt-snippet bodies from `--snippets`, and it counts acknowledgements
and unknown markup without using them.

Pi stores a `/name` prompt template as its expanded
text. The reader matches each `--prompts` template and keeps only the arguments, as it
does for skills. Attached-file markup that remains after stripping counts as
unknown markup. Each `ask_user_question` answer gives an `answered` unit for typed text
and a separate `picked` unit for the options the agent wrote. A child session's digest type has no human field, so
answers inside a child only increase `childAnswers`.

The census reports these values:

- The window, the file count, class counts, infrastructure names, and child markers.
- The folder kinds of each class and the reader counts.
- Agent statements, subagent exchanges, path touches, and stuck signals.
- Project-key resolution, loaded snippets and prompts, samples, and elapsed seconds.

A session that Pi forked from another session also has `parentSession`, so the reader
counts it as a child. Each project-key lookup runs `git rev-parse` through a scratch
folder under `$TMPDIR` that the command deletes; Git and the session files stay unchanged.

## Exact session preparation

`SessionReader.prepare(progress:limits:)` is a library boundary for the next step
of issue #706. It returns an immutable `PreparedSessionBatch` and proposed
`SourcePosition` values. Preparation is not completed dreaming. It saves no
checkpoint, journal, export, or proposal, and it makes no model request.
There is no executable preparation command. The manual `/dream` adapter calls the integrated runner.

Preparation discovers all regular `*.jsonl` files exactly two levels below the
session directory. It skips each file that was not modified in the last 7 days
(`SessionReader.dreamWindow`, the census default too). It reads the remaining files
newest first and keeps them until their undreamt kept text reaches 4 MiB
(`SessionReader.dreamBacklogBytes`); the file that crosses that total is still kept.
Kept text is the primary text, its attached agent context, and selection text.
Bytes before a saved position are already dreamt and do not count toward the cap. A skipped file keeps its saved position,
and its remaining bytes are not dreamt while it stays outside these limits. Preparation holds accepted
directory descriptors and opens child directories and files relative to them, without
following symbolic links. Only the root and current session folder stay open during capture.
An unvisited folder replacement fails closed instead of redirecting capture.
It captures each file's byte ceiling and admits only records that end with a newline. Preparation reports
an unfinished tail by path and byte range but does not consume it. Record timestamps
do not decide which records are new.

A supplied position binds the relative path, session identifier, complete byte
offset, full-prefix hash, and classification hash. Missing tracked files, shrink,
rewrites, duplicate session identities (including identical copies), unsafe paths,
read failures, malformed complete records, and unknown potentially human payloads
block preparation. It does not reset progress to recover from these errors.
Preparation checks all complete captured classification metadata, including names
beyond the batch boundary or line 20. A changed saved classification blocks preparation.
Old records supply ancestry context but do not become new primary evidence.

The primary evidence type permits only typed text, typed skill arguments, and
typed answers. Selected options and agent-written questions stay in a separate
context collection, including questions for typed-only answers. Child sessions,
generated custom context, native system messages, summaries, tool output, and attached bodies cannot supply primary support. Known exclusions have
versioned reasons.

A batch stores exact bytes only for records it keeps: records with primary evidence or
selections, and the `session` header at offset 0. Each run of other records becomes one
`skipped` span with a path, byte range, and hash of the span bytes, and no content.
Replay re-derives every stored record; it trusts preparation for skipped spans.
Saved runs from before this format keep exact bytes for every record and still validate. Each primary unit has
an exact, uncut extracted text, citation and part, timestamp, and source project
directory. Its witness has a path, byte range, and raw-record hash. This classification
does not authenticate human authorship or prove semantic support.

Preparation shares skill, snippet, template, attachment, and answer extraction
with the census, but it does not apply the census's middle cuts. It reads and hashes
the exact Markdown snippet and template inputs used for that preparation.
The default safety bounds permit 1,048,576 bytes per record with primary evidence
and 262,144 bytes per primary text or its agent context. Each batch permits a kept-text
budget and 1,000 stored records. `/dream` sets the budget from the selected model's
context window: one byte per token of context (25% of the window at about 4 bytes per
token), from 65,536 to 1,048,576 bytes. It refuses a model with less than 65,536 tokens.
Skipped spans count toward neither limit. A single record above the budget forms its
own batch. Encoded frozen-payload and retained-state ceilings still apply.
Tests check these named limits; they do not establish performance or token budgets.

A selected record with primary evidence that exceeds its record or text byte
limit blocks preparation instead of clipping. Records beyond the selected batch do
not trigger these size errors until a later preparation selects them. Source integrity,
classification, and extraction checks still apply beyond the batch boundary.
Batches stop between complete records and report remaining complete input with
`isBacklog`. The returned positions cover only the selected prefix. Only a later
successful-run owner can save these positions.

## Durable core transaction

`DreamRunStore.run(selection:resume:prepare:call:)` owns one complete transaction.
The manual `/dream` adapter runs this library through one private worker process.
It does not select a provider, change a model, or initialize a memory repository.
The caller supplies explicit private state, session, memory, and stripping roots.
The root manifest also binds the optional global instruction-owner locator.
The callback receives a `DreamModelRequest`, not raw session records.

One stable private lock file holds a process-held kernel lock through capture,
the callback, validation, proposal publication, completion, and progress writes.
A concurrent or reentrant call gets a typed busy error. Process death releases
ownership without deleting the lock file. There is no lease or age-based takeover.

Each invocation prepares one bounded batch from the last verified successful
progress. Bootstrap starts with generation zero and no positions across retained
history, without the census date filter. The reader saves exact selected prefixes;
`isBacklog` tells the caller to invoke again. A truly empty no-delta batch makes
no call, run, proposal, or generation. Unfinished tails stay unconsumed.

Before a call, the store captures the exact approved base, source scope mappings,
approved memory snapshot, owner bytes, date, policy, limitations, and request.
The snapshot retains sorted path, mode, and blob tuples, selected documents,
explicit project absence, byte digests, and annotation diagnostics. Supplied
snapshot reconstruction checks those values without reading live Git.

Scope comes from each frozen session header's working directory. Successful Git
resolution uses the canonical common-directory key; linked worktrees and aliases
share it. A valid directory outside Git is distinct from a failed resolution.
Missing or inaccessible directories stay unresolved, with no global fallback.
Successfully resolved project and outside-Git sources can support global proposals,
but the saved policy requires durable cross-project meaning. Project-local facts
belong in the matching project scope.

Unresolved primary evidence requires a saved
`unresolvedScope` decision; it is not a reason to skip the callback.

The caller can supply one explicit optional global `AGENTS.md` locator.
The adapter supplies it from its agent directory; the core reads no
personal settings or default home path. Omission produces a saved coverage limitation.
The core resolves a symbolic link for this explicit locator to its regular target.
A shared global and project owner appears once, with global scope.

Owner capture reads that global file, root project `AGENTS.md`, and grounded local
Markdown instruction owner locators from those files or retained primary input.
It follows no owner links recursively and searches no device directory.
Named instruction files and explicit owner references can point outside the project. Remote locators are not fetched.
Missing files produce saved limitations. Unsafe types, invalid encoding, and bounds
fail without clipping.

Owner capture uses regular-file checks and relative file
descriptors; it follows no final symbolic link. It changes no owner.

The exact request includes a closed JSON (JavaScript Object Notation) decision schema, primary catalogue, eligible
memory anchors, owner anchors, pinned scopes, and validation limits. Agent context,
questions, selected labels, approved memory, owners, and limitations have separate
non-primary labels. Only typed text, skill arguments, and typed answer parts can
support plans. Stored annotations are references, not verified evidence.
The store saves no authentication, keys, provider configuration, or inherited environment.

Private runner storage uses schema version two. Reader preparation and decision
responses keep version one. The store explicitly refuses established schema-one state:
its response lacks pinned decision context. No live reconstruction, reset,
migration, or automatic evidence deletion takes place.

The store first saves exact input, context, and logical request bytes, then an
immutable admission that binds their hashes and the predecessor progress record.
Input hashing has no context-hash cycle. An immutable call intent precedes the
callback. The exact bound response precedes validation. All validated notes and
path-sorted single-file plans are durable before any proposal publication.

Preparation also freezes exact stripping inputs and selected-session header and
classification metadata witnesses. A reader-owned pure check derives dispositions,
primary text, and selections through the same extraction and classification code.
A forged user-as-metadata exclusion fails. Valid child, generated, selected-only,
skill-only, snippet-only, and acknowledgement exclusions remain supported.
A verified exclusions-only batch completes without a callback or fictional response.
A primary no-change or owner note requires a complete saved validated response.

For every saved plan, recovery checks the exact deterministic proposal ref before
any stale-base refusal. It retains every recovered receipt even when a sibling is
missing. Missing plans publish only at the saved main base. A publication race
triggers another complete recovery pass. There is no rebase, merge, or approval.

The checked ref transaction uses a private detached HEAD and the repository's
authoritative common ref and object directory. It does not register a worktree,
use the human index, or follow a checked shared ref through HEAD.
Main, its reflog, the human HEAD and its reflog, the index, shared index,
configuration, and working files stay unchanged.

Completion saves every note, plan and receipt binding, next positions, tails, and
backlog before installing the next immutable successful generation. Consecutive
generation records bind their predecessors and exact completion evidence.
Generation arithmetic checks overflow; positions stay monotone per source path.
A number or hash alone cannot authorize completion. There is no public progress
setter, receipt input, Boolean success input, or finish operation.

Immutable admissions and the consecutive verified generation chain are authority.
`state.json` is a checked replaceable cache. A missing cache can be rebuilt only
from that chain and the exact current admission. Orphan runs and temporary files
cannot nominate a run. Gaps, corrupt authority, unsafe files, foreign bindings,
and missing authoritative payloads fail without reset.

The runner reuses a response installed before cache loss without a second callback.
A completion installed before generation or cache loss advances once only.
Exact proposal recovery still works after a human advances main.
A recovered run returns its report; it does not also admit the next batch. Completion means that
proposals, notes, and progress are durable. Only a human can approve memory.

Pending replay reads no sources, stripping files, project resolution, owners,
or clock. Source roots can disappear after admission. Established state requires
the original configured root spellings when saved, or the saved canonical spellings otherwise. Before a new admission, the runner resolves
all configured roots and checks their exact UTF-8 paths against the saved binding.
Replay does not resolve session or stripping roots.

### Restore a missing registered prompts folder

An established profile can explicitly relocate its registered prompts role for fresh work.
Select an authoritative frozen input by run ID. Preview the complete replacement folder first.

```sh
pi-core-memories dream relocate-prompts-preview \
  --config /path/to/profile.json --baseline-run <run-id> --to /canonical/replacement/prompts
pi-core-memories dream relocate-prompts-confirm \
  --config /path/to/profile.json --baseline-run <run-id> --to /canonical/replacement/prompts \
  --preview <previewHash> --confirm yes
```

The baseline must be a verified completed run or the current verified admission.
An explicitly selected older completed run is allowed. The preview reports newer captures and encountered inventory differences.
Equality covers only that input's complete template subset, not all historical versions or outstanding expansions.
The comparison includes every sorted Markdown name and all raw bytes, including frontmatter.
Missing, extra, renamed, changed, or unusable definitions cannot authorize confirmation.
Confirmation recaptures the folder and requires the exact current preview hash and explicit caller intent.
It does not verify human identity. A changed head, admission, target, or store requires another preview.
An unrelated approved-memory advance does not invalidate the preview.

Confirmation installs only `prompt-relocation.json` in the dream state directory.
It does not rewrite `root.json`, advance progress, start inference, approve memory, or change reviews or drafts.
The private record binds the store and repository identities, immutable root binding, historical prompts role,
selected frozen input, activation anchors, complete inventory proof, and confirmed preview hash.
The original source must remain absent. The target must be canonical and separate from registered sources and dream state.
Existing records cannot be overwritten, chained, removed, or reset through these commands.
The commands reject `--state` and options for another operation. They do not initialize missing state or use discovery.

Fresh worker preparation and queue inspection share the effective-source resolver.
Historical registered roots and review-source identity remain unchanged.
An unavailable or unsafe replacement blocks fresh preparation and leaves queue coverage unknown, not zero.
After confirmation, ordinary definition edits and same-path package replacement retain normal per-batch provenance.
The activation proof does not permanently pin template contents or the replacement directory's inode.

The optional record has a separate 1,048,576-byte bound.
Dream core-authority traversal excludes exactly its top-level entry without opening or following it.
All other entries, nested names, and generic review, draft, and configuration traversal retain their existing checks.
Fresh preparation and relocation commands validate the record independently.
Saved history, frozen replay, saved-response reuse, and independent manual work do not require a valid record or a live replacement.
Live confirmation and dream retries remain separate operator actions.

Before receipt recovery or publication, the runner checks the live memory root
against that same binding. Memory Git is still needed for exact proposal recovery
and publication.

An interrupted call without a saved response needs explicit `retryInterruptedCall`.
That retry uses identical saved logical request bytes, hashes, and timestamps with
the operator's current selected model and thinking level. An invalid saved response
stays pending on inspection or retry. Explicit `replaceInvalidResponse` retains its
bytes in an immutable archive before it requests another reply for the same batch.
An unsaved external response can require a repeated request. This is not an
exactly-once provider execution guarantee or a promise about provider wire bytes.

After a valid completed cache commit, the core cannot tell whether the caller
received the final report. With no active admission, `retryInterruptedCall`
recovers the last committed report without preparation or a model call, regardless
of the current selection. Default `inspectOrContinue` starts the next bounded
batch, or returns `noNewRecords` at the same generation if sources contain no new records.

Cancellation before progress commit leaves a pending admission and recoverable
refs. Cancellation does not undo published refs. After the store installs a generation,
report loss requires completed-run recovery, not rollback. Persistence failures never
return successful completion. The store retains temporary and orphan evidence.

State must be outside Git and disjoint from source, memory, and stripping trees.
Private directories use `0700`; files use `0600`, one link, and the effective user.
Checked writes handle short returns, synchronize files and directories, install
immutable files exclusively, and replace only the cache atomically.
The store refuses unsafe permissions instead of repairing them.

The default ceilings are 33,554,432 encoded bytes per frozen payload,
262,144 response text bytes, 32,768 retained positions, and 1,073,741,824 retained
state bytes. The position ceiling includes excluded sessions. Explicit positive
limits remain available. Context, request, decisions, receipts, completion,
and provenance encoding count against finite payload and retained-state bounds.
JSON and base64 expansion count; code trims no bytes.

Metadata reads permit 1,048,576 bytes. Retained scans permit at most 10,000 entries
per directory and fewer than 64 levels. Orphans count toward capacity.

These are safety bounds, not token or performance claims. Preparation still
captures whole source files and classification metadata before batch selection.
Batch limits do not bound total corpus capture memory or discovery time.
Retained-state capacity can block later work; the store does not delete evidence automatically.
Private storage uses no encryption and permits complete same-user rewriting.

Hashes and classifications do not authenticate authorship or prove semantic support,
complete owner coverage, or all contradictions. Human approval stays separate.

Synthetic checks cover exact correction-to-ref-to-progress, notes, exclusions,
backlog, late appends, scope, owners, and pinned replay after deletion.
They cover schema refusal, invalid saved responses, cache loss, sibling stale
recovery, publication races, cancellation, successive generations, and unsafe authority.
They also cover real short and failed system calls, kernel lock contention,
and process death. Tests use disposable repositories and no live sessions
or provider requests.

## Validated decision library

`MemoryStore.decisionSnapshot(base:projectKeys:limits:)` reads the exact saved
commit, not current main. Supply a full lowercase 40- or 64-digit commit object
identifier. The whole tree must have the dedicated memory layout: regular
`MEMORY.md` and only allowed regular memory files.

The snapshot binds every path, mode, and blob identity in a sorted layout hash.
It loads global, explicitly requested projects, and the selected device's matching layers.
A requested missing project has explicit absence; global cannot be absent.
Invalid Unicode Transformation Format 8-bit (UTF-8) and null (NUL) bytes fail.
Annotation failures remain diagnostics so an exact update can repair an existing
invalid block.

Sanitized Git disables hooks, signing, filesystem monitors, replacement objects,
and lazy fetching. This read does not change objects, refs, the index,
configuration, or working files. Git process transport uses temporary files.

`DreamDecisionContext(run:snapshot:scopes:owners:addedDate:limits:)` is the throwing
provided-input boundary. Every frozen primary text part needs exactly one
`PinnedEvidenceScope`. That scope binds its exact frozen source-directory string.
A resolution supplies a canonical project key with explicit global eligibility,
explicit outside-Git status with global eligibility, or unresolved status.

A directory is not a project key. There is no project-to-global fallback.
Snapshot project keys must match the distinct resolved scope keys exactly.
Unresolved evidence can support
only an `unresolvedScope` no-change note.

Owners are explicit `PinnedOwnerInput` values: local key, safe reference text,
global or resolved-project scope, exact UTF-8 bytes, and a code-computed digest.
The library never opens an owner reference. It checks supplied bytes, not owner
authority. Primary, memory-block, and owner anchor catalogues have immutable
`Sendable` values.

The sorted-key context digest binds schema version, run and input identities,
run fields, snapshot identities and bytes, scopes, owners, date, and limits.
It does not depend on live resolution or native Markdown object identities.

`DreamDecision.validate(response:context:)` accepts one closed version-one JSON
(JavaScript Object Notation) object with exactly `schemaVersion`, `contextHash`,
and `decisions`. The hash must match the supplied context. Each variant has
exactly these fields:

| kind | required fields besides kind |
| --- | --- |
| `add` | scope, text, sources, contradictions, reason |
| `update` | scope, anchor, text, sources, contradictions, reason |
| `noChange` | sources, reasonCode, explanation |
| `ownerNote` | sources, owner, contradictions, explanation |

Scope is `{"kind":"global"}` or `{"kind":"project","key":"<64 lowercase hex>"}`.
A device-enabled context also permits `{"kind":"device","deviceKey":"<pinned device key>"}`
and `{"kind":"deviceProject","deviceKey":"<pinned device key>","key":"<pinned project key>"}`.
A saved context without device configuration keeps its original schema and prompt.
A source has exactly session, entry, and integral part fields. Only frozen typed
text, typed skill arguments, and typed answers can supply primary support.
Picked labels, agent context, generated memory, child records, and owner bytes
cannot.

Every primary part must have proposal support or one terminal note, never both.
Empty evidence permits only an empty decision array. The pure validator saves no state.
No-change codes are `notDurable`, `alreadyRepresented`, `insufficientEvidence`,
and `unresolvedScope`. Duplicate keys, missing or extra fields, unknown tags,
nulls, nonintegral ranges, nested unsupported data, fences, and trailing prose fail.

A memory anchor has exactly scope, documentHash, start, end, and before fields.
Offsets count original UTF-8 bytes from zero, with an exclusive end. Updates need
one eligible complete native paragraph block, its exact document digest, and
exact before bytes. The shared Foundation Markdown analysis keeps existing
annotation-validation semantics.

Headings, thematic breaks, reference definitions, code blocks, raw fallback ranges,
and overlapping ranges cannot serve as update targets.
Equal text at distinct eligible offsets remains valid: the exact digest, range,
and bytes identify the target. Partial Unicode, duplicate targets, and
overlapping updates fail. An update can repair invalid ordinary annotations,
but untouched invalid content blocks the final replacement.

An owner anchor has exactly key, ownerHash, start, end, and before fields. It
references a nonempty UTF-8-boundary slice of supplied owner bytes. An owner note
creates no Markdown and changes no owner.

Contradictions use closed primary, memory, or owner records with an explanation
and their source or anchor. They must stay within eligible global or
matching-project scope. Each update must include its replaced memory anchor
as a contradiction. Empty contradictions mean none supplied, not that no
conflict exists.

Model text must stay within bounds and contain nonempty, single-line prose with
no controls or metadata markers. Code escapes Markdown, encodes leading ASCII
spaces without trimming, and generates source annotations and the pinned date.
Each generated range must be an ordinary document-level paragraph in the final
replacement. Content inside an unclosed fence or another container fails.
Code applies updates in descending original-offset
order and preserves all bytes outside targets.

Code appends additions in response order with a fixed two-line-feed (LF) separator.
An absent project starts with `# Memory` and LF. All final Markdown must pass
the existing checker. The library trims no input or output.

The result contains immutable notes and at most one `SingleFileProposalPlan` per
path, sorted by path. Each plan retains exact base, derived path, replacement,
canonical versioned reason and contradictions strings, before/after digests, and
validated references. These are the exact arguments for later `propose` and
`recoverProposal` calls. This library calls neither method.

Every plan uses the same saved base. The library does not promise atomic human
approval across files or rebase stale plans. Private source records, source
directories, and complete owner bodies stay out of proposal metadata except
required exact cited anchor snippets.

The defaults set these safety bounds:

| input or output | maximum |
| --- | --- |
| response text | 262,144 bytes |
| aggregate frozen provided input | 33,554,432 bytes |
| layout | 10,000 entries; 1,048,576 tuple bytes |
| selected snapshot | 4,194,304 total bytes; 1,048,576 per document; 64 project keys |
| owners | 64 owners; 1,048,576 total bytes; 262,144 per owner; 256 bytes per key or reference |
| decisions | 256 decisions; 64 sources and 64 contradictions per decision; 4,096 references |
| prose and anchors | 16,384 bytes per prose field; 262,144 per before text |
| plans | 65 plans; 1,048,576 bytes per replacement; 4,194,304 total output bytes; 262,144 per metadata string |

These positive limits have no configuration override or automatic trimming.
They are not token or performance claims. The decision input limit counts the
structural validator's aggregate record, primary-text, agent-context,
source-directory, question, and selected-label bytes.

The runner checks each encoded frozen payload against its separate byte ceiling.
Frozen provenance and serialization expansion count toward that storage ceiling.

The integrated runner saves the snapshot, resolved scopes, owners, date, limits,
policy, limitations, catalogues, and exact logical request before the callback.
Replay reconstructs that same context without live reads. It saves every validated
plan and note before exact proposal recovery or publication, then installs progress
only after durable completion. The pure decision validator remains available for
provided-input checks and does not publish proposals itself.

Membership, hashes, syntax, and supplied conflicts do not prove human authorship,
semantic support, durable relevance, complete conflicts, or owner authority.
Human approval remains separate.

## Human approval

`review` prints the parent/base, reason, contradictions, and committed diff for
human inspection. It displays terminal controls as `\u{HEX}`, using uppercase
hexadecimal without leading zeroes: ESC becomes `\u{1B}` and CR becomes `\u{D}`.
This includes C0/C1 controls, DEL, and directional controls; LF, tabs, printable
Unicode, and emoji stay unchanged. Stored Markdown bytes and metadata values
stay exact. `render` does not apply these display escapes.

It supplies instructions for a HUMAN to inspect and approve the change. In the
data repository, confirm that the index and working tree are clean and main still
matches the reviewed base. Then use `git switch main` and
`git merge --ff-only <proposal-commit>`.

A stale main or dirty data repository needs human reconciliation. Never reset or
force to make a proposal fit. There is no approve command or automatic promotion.
Review and proposal generation do not grant approval.

## Build and tests

From the source repository, run `/bin/zsh tools/pi-core-memories/build.zsh` for an
explicit warnings-denied release build. The script queries that build's binary
path and copies its verified executable to `target/release/pi-core-memories`.
The installer owns publication; calling the installed binary never builds it.
See [testing commands](../../docs/testing.md#core-memories) for format, build,
and core plus executable tests. Tests use disposable repositories, not live memory.

## Pi session loader

The `core-memories` extension calls the installed `pi-core-memories render` command
before the first model request of each session. It uses
`~/.local/share/pi-core-memories` as the data repository. Set
`PI_CORE_MEMORIES_REPO` to use another private store. A relative override is
resolved from the session's project directory. The loader never initializes data.
Use the store-only `init`, `propose`, and `review` commands explicitly.

A successful render supplies the approved memory layers for the current project and device.
Other devices' text does not enter that snapshot. Linked worktrees share the project's Git common-directory identity.
Dirty files and pending proposals do not load. Missing commands, missing stores,
invalid approved documents, invalid UTF-8 output, and renders that a signal stops
leave no snapshot. The loader tries again on the next prompt. A terminal session
shows one warning per session; other modes do not show a terminal notice.

The loader returns the snapshot from `before_agent_start`, so Pi saves it after
the first user message and after the system prompt. It is one hidden, versioned
custom message with the session identifier, project directory, data path, and
`approved-core-memory` origin. Resume and reload reuse a matching snapshot on the
active branch without another render. New sessions, forks, and branches without a
snapshot render again on their next prompt.

At request time, the loader drops inherited or out-of-scope snapshots and keeps at
most one matching snapshot. After a compaction removes the saved snapshot from
context, the loader adds that same saved text back after the compaction summary.
It does not render again or save a copy. It does not restore a snapshot that a
context edit omitted or replaced.

The model sees a generated-context label and exact stored Markdown annotations.
Pi converts custom messages to user-role model context without their metadata.
That role does not prove human authorship, and stored references are not verified
evidence. The loader does not rewrite real user or assistant messages or change the
system or tool prompt. It does not start a turn or select a model or thinking level.

Source edits take effect through normal installation and a Pi restart. This loader
adds no live reload, data import, or automatic initialization. The tests build the
Swift command and use disposable stores with installed Pi SDK 1.1.0. They do not
install the extension or change live Pi settings.

## Manual dreaming

Run `/dream` in Pi after you initialize the separate private memory store.
It waits until the agent is idle, then captures the current model and thinking level once.
`/dream` processes one bounded batch. `/dream all` processes successive bounded
batches with the same captured selection. It saves each batch report before starting
the next worker, and continues only after a completed report with `isBacklog`.
It stops when the backlog ends, or on pending, blocked, busy, no new records,
cancellation, shutdown, or an error. It never retries an interrupted call or
approves proposals automatically. The terminal progress view shows the batch number.
Nothing runs from startup, the approved loader, a timer, or a scheduler.
A missing model fails before a worker starts.

`/dream retry` repeats only an interrupted call with no saved response. It can
bill again. It reuses the exact saved request, timestamps, and hashes with the
operator's current selected model and thinking level. A saved response or
committed report needs no model call.

`/dream replace` requests a new reply only for a saved reply that failed decision
validation. It can bill again. It keeps the original batch, context, request,
timestamps, hashes, and admission unchanged, and uses the operator's current
selected model and thinking level. It does not repair offsets or relax validation.
A valid reply or committed run cannot be replaced. Ordinary inspection, `/dream all`,
and `/dream retry` never replace a saved invalid reply.

Each run permits at most 32 replacement attempts, within the existing storage limit.
Before a replacement call, the runner durably saves the rejected response envelope
byte for byte as `rejected-N.json`, then installs `replacement-N.json` with the
admission, request, and rejected-response hashes. Both files are immutable.
The intent selects `replacement-N-response.json` as the active reply; the original
`response.json` and all earlier replies remain unchanged. The attempt's
`replacement-N-call-started.json` records its call selection.

A crash before the intent leaves the previous reply active. A crash after the
intent but before a saved reply leaves an interrupted attempt. `/dream` inspects
it without a call; `/dream retry` explicitly repeats it and can bill again.
A second `/dream replace` does not repeat an interrupted attempt. Recovery verifies
all rejected archives and their strict validation failures, and synchronizes the
active archive and intent before a retry call. A saved replacement reply passes
the same validation and proposal/completion transaction as an original reply.
No proposals or progress changes occur before successful validation.

Only `/dream`, `/dream all`, `/dream retry`, and `/dream replace` are accepted. Combined or other
arguments fail without starting a worker. No model, thinking level, credentials, or routing
settings change. Pi's registry owns request-time authentication.

The adapter passes only the worker's saved system prompt and text messages to the
captured registry. It adds no active conversation, approved-loader snapshot, tools,
or current system prompt. The saved `off` selection becomes omitted reasoning only
at the transport boundary. Only a complete stop event and matching stop result with
bounded, nonempty text can return to the core. Text blocks join without separators,
trimming, fence removal, or repair. Tool calls and incomplete results fail.

Pi can route a virtual selection to a physical model. The saved request keeps the
logical selected model and thinking level. The registry owns the route and its physical
thinking level. A read-only payload callback records only the dispatched provider,
model identifier, and interface identifier. It does not inspect or keep the payload.

The terminal event and final result must match that observed physical identity.
Conflicting dispatch identities fail. A virtual route whose provider does not invoke
the callback also fails; the adapter does not guess its provenance. Physical selections
must match their captured identity. The adapter adds no router, fallback, or second call.

The terminal uses Pi's native progress loader. Escape stops the call at once and
closes the progress view. Shutdown also aborts the call and waits for worker cleanup.
The adapter sends cancellation, then terminates only its own worker if needed.
It accepts a final report only after valid framing and a zero exit from the reaped worker.
Cancellation leaves saved work available; it does not undo published refs or committed progress.

Defaults use the actual Pi agent directory: `sessions`, optional `prompts`, and the
explicit global `AGENTS.md` locator. The extension package's existing prompt-snippet
folder is the only snippet source. Missing optional folders stay unconfigured; the
adapter does not create them or search other folders. The data store defaults to
`~/.local/share/pi-core-memories`, with the existing `PI_CORE_MEMORIES_REPO` override.
Private state defaults to `~/.local/state/pi-core-memories`, outside Git.

On established state, the adapter reads only bounded, checked root metadata to keep
configured optional roots stable. A deleted configured folder stays configured on
replay; a new folder does not replace a saved omission. Changed addresses or unsafe
metadata fail. Core independently validates the binding and owns every durable write.
The worker receives only HOME, PATH, TMPDIR, LANG, and LC_ALL from the process environment,
not provider keys or Pi authentication configuration.

Review reports are custom session entries outside model context and primary human
evidence. They show full proposal refs, commits, bases, source identifiers, known
contradictions, notes, pending state, and the existing quoted `pi-core-memories review`
command. The adapter escapes terminal controls and directional controls. Native text wrapping
keeps full identifiers available at narrow widths. Reports contain no retained session
bodies, complete owners, source directories, or approval buttons.

A completed report means the core saved proposals, notes, and progress. It does not mean
that a human approved memory. Run `/mem-review` to review each proposed entry in Pi.
The approved loader remains unchanged and never loads proposal reports as memory.

## Individual memory review

Run `/mem-review` without arguments in terminal mode. It makes no model call.
Select one pending or deferred entry to inspect its exact old and new bytes,
source references, source text, contradictions, limitations, and current base.
Pi escapes terminal controls in retained text. Use Ctrl+B and Ctrl+F to page through the preview.

Approve, Reject, and Defer apply to one entry, not its same-file siblings.
The initial action is Back, never Approve. Reopening Pi retains dispositions.
The queue filter includes approved, rejected, deferred, and blocked entries.

Detach the initialization checkout before approval. Pi asks separately
for this change and preserves its commit, index, and working files. Declining
changes nothing. Detaching does not approve memory; select the entry again.
Approval changes `main` through a checked transaction and records an audit ref.
Unexplained intervening edits or ambiguous entry locations block approval.

Review state lives outside Git at `~/.local/state/pi-core-memories-review`.
Completed dream inputs and exact published receipts must verify before candidates
enter the queue. Review neither re-dreams sources nor advances dream progress.
Only focused native choices use the inherited anonymous private control channel.
Ordinary process input and command arguments cannot approve entries. Same-user
code can imitate this channel; it is not proof of human identity.

Each approved entry receives a stable identity and an explicit review instant.
Legacy entries have no known review date. Direct changes retain that distinction.
This increment does not add reminders.

## Direct memory management

Existing agents can use `memory_list`, `memory_get`, `memory_add`, `memory_update`,
and `memory_delete` for ordinary user requests. A clear request to add, correct,
or delete an approved entry permits that change without a second `/mem-review`
approval. The tool instructions prohibit inferred preferences, background changes,
and approval of dream candidates. These instructions are not proof of human identity.
Dream candidates still require native `/mem-review`; management never writes dream
progress or review dispositions.

`memory_list` returns the committed approved catalog, including exact base, path,
byte locator, entry bytes, identity, dates, and mutability. `memory_get`, update,
and delete require that exact target. Duplicate prose is not a search key. Stale
bases or bytes fail; list again before another change.

Add requires the current
base and an allowed memory path. Obtain project keys from `project-key`, not guesses.
Each mutation changes one entry and needs a reason. Add and update accept one
complete annotated Markdown entry without `memory-id`, `reviewed`, or `revised` metadata. Update must
retain all previous source annotations and the stable entry identity.

Direct changes set `revised`, not `reviewed`. An earlier native review date stays
unchanged. A legacy entry has no review date until native review supplies one.

Main and a separate `refs/memory-management/changes/<digest>` audit ref publish in
one checked transaction. The audit retains the reason, exact before and after
bytes, sources, identity, and revision instant. It does not verify source truth.
Delete removes the selected entry from approved memory, not from Git history.

A fresh store has an attached checkout. Run `/mem-prepare` without arguments in
Pi terminal mode to prepare it. This command works without dream state. Decline
is the first choice; only the explicit native detach choice changes the checkout.
It preserves its commit, index, working files, and approved main. It approves no
entry.

Nonterminal calls, command arguments, ordinary process input, and agent
memory tools cannot supply this confirmation. The private control channel has the
same same-user impersonation limitation as native review. Dirty or stale checkout
state fails without resetting files.

New native review and management checkout leases share the repository-bound
`.git/memory-management` authority. Native review state, dream dispositions, and
audit namespaces stay separate. Recovery requires the exact checked lease and a
proven-dead owner. Unknown Git locks are never removed automatically. For a legacy
native review lease in an external state root, reopen `/mem-review` with its
original explicit configuration. Management does not search for that old root.

Preparation waits for an idle command context. Cancellation waits for the child
process to close and escalates termination only for that child. Worker output has
incremental byte limits, strict UTF-8 decoding, and closed fields without duplicate
keys.

The bounded command transport is `pi-core-memories manage --repo <store>` with a
closed operation-specific JSON request on standard input. Limits are 1,048,576 request bytes,
262,144 replacement bytes, 16,384 reason bytes, and 1,048,576 final document bytes.
Before publication, the complete proposed catalog must pass the same read limits:
64 project documents and 4,194,304 aggregate bytes. A refusal changes neither main
nor its audit refs. Read results use the bounded approved snapshot.
The adapter starts no provider call and passes only the restricted worker environment.

An existing session retains its exact saved memory snapshot after a mutation.
Start a new session to load the changed approved memory. These source changes
need normal installation before they become available in existing Pi installations.

## Review reminders for approved entries

At terminal session start, Pi checks the committed approved catalog. Global entries
and entries for the canonical current project need review at 30 × 86,400 seconds
since their last explicit native `reviewed` instant. An unknown date needs review.
A future date is not due. `added` and `revised` never reset this interval.
Headings and reference definitions do not count as memory entries.

Due memories stay in use. The reminder gives their count and lists their paths and
text previews. It points to `/mem-rereview`.

A generated custom session entry records
that the check ran. Resume, reload, and compaction do not repeat it in that session.
A new session can remind again. This record is not human input or model context.
There is no timer, live session scan, or background model call.

Run `/mem-rereview` without arguments in terminal mode to select one existing
approved entry. It needs no `/dream` run or candidate state. The scrollable native
view shows the exact current entry, its stored source references, and its review
and revision dates. Source references remain unverified. Use Ctrl+B and Ctrl+F to
read long entries.

Back is the first choice. Only **Confirm reviewed** writes a
review date. **Defer** and **Back** leave the date and approved memory unchanged.
There is no approval of all entries and no agent tool that sets a review date.
Pending dream candidates still use the separate `/mem-review` command.

Confirmation changes only review metadata. An eligible legacy entry also gets a
stable identity. Prose, source references, revision date, and other entries stay
unchanged. The worker checks the selected base and exact bytes again. It uses the
existing private checkout lease and checked main/audit publication transaction.
The audit origin is `native-approved-entry-review`.

An attached checkout first
needs the separate `/mem-prepare` confirmation. Dirty or stale state fails closed.
Malformed metadata and duplicate identities stay readable. This route cannot
change them and does not repair them as a group. A duplicate identity anywhere in
the catalog blocks publication through the shared management safeguard.

The read-only transport is `pi-core-memories review-catalog --repo <store> --cwd
<project>`. The native entry choice uses the existing preparation worker's inherited
anonymous control channel, not process arguments or standard input. It has the
same same-user impersonation limit as the existing native review channel.
Neither a reminder nor a review refreshes an existing session's saved memory.

## Boundaries

Installation, live provider behavior, and visual evidence require separate checks.
There is no automatic legacy import. `dream-scan` remains a read-only census.
Observational memory remains the owner for within-session context. This store has
no vectors, Jev, daemon, scheduler, confidence scores, durability scores, or semantic
evidence gates.

## License

[MIT License](LICENSE). A backlink is welcome but not required.
