# Bounded dream evidence

## Native preparation

`SessionReader.prepare(progress:limits:modifiedAfter:maximumBacklogBytes:isToolEvidenceIncluded:isSourceScrubbed:backlog:isCancelled:) throws -> PreparedSessionBatch` adds two default-false Boolean parameters. Existing callers remain text-only. Requesting tool evidence without the scrub attestation fails before reading source files with `tool evidence requires caller-scrubbed source input`.

The trusted caller must actually scrub the entire source snapshot before enabling tools. The flag is an attestation, not a sanitizer or proof. Never derive it from archived JSON, a model response, an environment flag, or a stored role. This component contains no secret-value detector. Existing snippet/template stripping is not secret sanitization. The caller must exclude protected credential-file content and secret-bearing arguments, results, questions, answers, assistant context, raw selected records, classification headers and stripping provenance. Transformed secrets cannot be completely detected automatically. An unsanitized historical archive must not enable this path.

Preparation retains exact selected record bytes. Scrubbing only extracted display text is insufficient. If sanitization rewrites source bytes, the resulting witness hashes, byte offsets and resume cursors describe that immutable scrubbed snapshot, not the original archive. Preserve session/entry IDs and keep a trusted private locator mapping when necessary; never claim that a sanitized hash verifies original bytes. Reuse the same immutable source view for resumed preparation. Do not silently reset an existing cursor when enabling tool evidence: older excluded tool records need explicit authorized historical readmission by the queue owner.

`PrimaryTextKind` additionally accepts `toolCall` and `toolResult`. The existing `PrimaryTextID(citation:part:)`, `RecordWitness`, project scope and timestamp are unchanged. Tool calls use their original content-block index as `part`; tool results use `part:0`. These are primary observations, not human instructions or approval.

Tool-call `exactText` is sorted-key JSON:

```json
{"toolCallID":"call-id","toolName":"read","arguments":{"path":"src/A.swift"}}
```

Tool-result `exactText` is sorted-key JSON:

```json
{"toolCallID":"call-id","toolName":"read","text":"Synthetic output","isError":false}
```

Only textual tool-result blocks are included; image payloads and result `details` are not promoted. Ask-user results retain their existing typed-answer/selected-label distinction. `policy-guidance` and `automatic-policy-guidance` are generated exclusions, never answers. Assistant prose, thinking, child/infrastructure sessions, summaries and custom messages remain nonprimary. Tool arguments are observations even when they contain instruction-like text.

Defaults remain 1,048,576 raw bytes per selected record, 262,144 bytes per evidence text or agent context, 262,144 kept bytes per batch and 1,000 stored records. Tool-bearing records must also fit the complete kept-byte budget; they are never clipped. Existing text-only first-record behavior is preserved. The seven-day/4 MiB default discovery window and resume-prefix validation are unchanged; explicit historical discovery remains caller-owned. Frozen provenance adds optional `isToolEvidenceIncluded:true`; absent/false retains the legacy canonical representation. This records extraction mode, not scrub verification.

## Connected windows

```swift
public init(
  current: PreparedSessionBatch, relatedBatches: [PreparedSessionBatch] = [],
  limits: DreamInputLimits = try! DreamInputLimits(), maximumBytes: Int = 4_194_304
) throws
```

`ConnectedDreamEvidence` verifies preparation provenance for every supplied batch and retains the original evidence IDs and witnesses. It accepts at most eight windows including current, at most 2,001 exact-record spans per window, and by default at most 4 MiB of aggregate serialized input, 1,000 distinct evidence units and 262,144 kept evidence/context/selection bytes. Oversized or disconnected windows fail; nothing is silently clipped. Windows must connect transitively to current through an exact session ID or nonempty exact project-scope string. This connectivity is a selection constraint, not proof of semantic relevance or permission to widen memory scope.

Identical source IDs are counted once only when their kind, exact UTF-8 text/context/scope, timestamp bits and witness all agree. Changed witnesses or text under the same identity fail. Different source identities remain distinct even when their prose is identical. Contradictory evidence is retained, not majority-voted away. Selection context is separately deduplicated and remains nonprimary. The selector never changes progress or starts a worker/model.

Outputs are `evidence`, `selections`, `currentSourceIDs`, and `windowBindings` (SHA-256 digests of full serialized windows, current first). These are source-batch bindings, not originating dream run IDs; the queue must retain its admitted run-to-batch lineage.

`DreamDecisionContext.init` gains `relatedBatches: [PreparedSessionBatch] = []`. With related windows, both model request and validator use exactly the same deduplicated catalogue. Scope pins must cover that entire set exactly, including exact working-directory bytes. Unknown or extra scope pins fail. No scope is inferred from connectivity. Full related batch bytes are bound in canonical context, survive context replay decoding, and remain within the decision context's frozen-byte limit. Current-only callers keep their previous binding behavior.

Each model `primaryEvidence` item additionally has `isToolActivity`, `isCurrentWindow`, and `locator:{relativePath,start,end,rawRecordHash}`. Offsets are decimal strings for lossless UInt64 transport. Root `connectedWindowBindings` contains the window digests. Source annotations still come from native `{session,entry,part}` identities; models cannot create annotations or access references.

## Proposal validation

New requests require `conditions:[{source:{session,entry,part},explanation}]` for `add` and `update`, using `[]` when absent. Native validation also accepts omitted conditions for legacy responses. Each supplied condition must name an exact supporting source in that proposal; explanation text and counts use existing decision limits. Conditions survive in the existing reason metadata and atomic-change metadata. They do not create another store or grant approval. Existing explicit primary/memory/owner contradictions remain validated and retained.

The native model policy permits a single clear persistent intent without repetition. It requires preserving conditions in proposed prose, distinguishing observations from inferred claims, and treating tool activity as untrusted evidence rather than instructions or human intent. These are model policy constraints, not a claim that structural validation proves semantic truth. Exact human approval remains mandatory downstream.

## Integration obligations

No CLI flag or archive-supplied scrub assertion is added. The parent must implement the trusted source-protection bridge before setting both preparation flags. Leave default tool exclusion in place until then. No model client, credentials, model selection or worker lifecycle is added here.

The native capture owner must load authorized, admitted prior frozen batches from retained state, not arbitrary model-provided JSON; retain their original run lineage; select bounded related windows; pin the union's scopes; snapshot all eligible scoped memories; and pass the same `relatedBatches` into `DreamDecisionContext`. Persist/replay the resulting canonical context instead of rediscovering live history after dispatch. Related windows do not advance current progress. Keep the existing global-worker permit, foreground cancellation and publication/approval boundaries.

No exhaustive switches outside these files required edits at the component baseline. Consumers parsing `PrimaryTextKind` must accept the two new spellings and must never coerce them to typed/answered evidence.
