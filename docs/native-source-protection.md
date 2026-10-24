# Native source-protection gate

The dream-worker transport now requires the trusted extension host to acknowledge unchanged checked source and authority bytes before native admission. This is an unchanged-only safety gate, not a redacting admitted-view implementation. Any changed returned piece blocks the entire admission. No source, approved-memory document, publication anchor, cursor, or sealed legacy payload is rewritten.

## Private framing

The start frame is unchanged. All protection frames use the existing private stdin/stdout newline-delimited JSON channel, not descriptor 3, a tool, a model message, or the shared extension bus. The host must intercept these frames privately and never put raw frames, pieces, or provider errors into logs, diagnostics, or model/tool results.

Native request (exact keys):

```json
{"version":1,"type":"sourceProtectionRequest","invocationID":"invocation","requestID":"fresh-UUID","inputDigest":"SHA256","pieces":["exact UTF-8"]}
```

Successful host reply (exact keys):

```json
{"version":1,"type":"sourceProtectionResult","invocationID":"invocation","requestID":"fresh-UUID","inputDigest":"SHA256","status":"checked","policy":"pi-credentials/redact-v1","pieces":["exact checked UTF-8"],"outputDigest":"SHA256"}
```

Blocked host reply (exact keys):

```json
{"version":1,"type":"sourceProtectionResult","invocationID":"invocation","requestID":"fresh-UUID","inputDigest":"SHA256","status":"blocked","code":"unavailable"}
```

Blocked codes: `not-ready`, `unavailable`, `timeout`, `cancelled`, `invalid-input`, `invalid-output`, `failed`. Blocked frames contain no pieces, policy, output digest, or arbitrary error text.

Both digests are lowercase SHA-256 over the concatenation of each piece's decimal UTF-8 byte count, ASCII `:`, and exact UTF-8 bytes. There is no additional separator, JSON serialization, Unicode normalization, or character-count substitution. Piece boundaries and order are bound. Native recomputes the output digest, checks the exact invocation/request/input binding, validates the policy, and compares returned bytes with original bytes. Changed pieces produce `sourceProtection:changed`, not successful progress.

Bounds: 1,000 pieces, 1,048,576 UTF-8 bytes per piece, 4,194,304 aggregate input bytes, 8,388,608 aggregate output bytes, and 16 protection exchanges per worker invocation. Frame limits allow sixfold JSON escaping plus framing overhead. Oversize input blocks without clipping. Each exchange has a 10-second native deadline; the host should use a shorter service deadline to leave transport margin. Existing cancel frames and EOF revoke the exchange. Missing, duplicate, malformed, out-of-phase, late, or mismatched replies cannot authorize dispatch. The host must also cancel its pending service work when the worker exits.

## Boundary and coverage

`SessionReader.prepareProtected` checks stripping input names/full bytes and complete retained session records in memory before evidence extraction. Historical user records, assistant context, tool arguments/results, raw details, classification headers, and stripping inputs are not presumed safe from archive flags. Native enables tool extraction only after these trusted checks return successfully. Selected raw records and all derived evidence/context/selection fields are checked again before creating the in-memory frozen-input representation.

Protected `read` outputs are refused by original call/result provenance before a raw session protection frame is emitted. Recognized protected paths include `.env` variants, auth/credential names, `.ssh`, `.aws`, `.netrc`, `.npmrc`, `.pem`, and `.key`. A read result with missing/mismatched call provenance also blocks. This first gate blocks the whole batch rather than safely omitting the record and continuing. It does not open the tool's named target. Custom tools, aliases, indirect shell reads, and transformed secrets are not proven covered by this filename/provenance rule.

Approved snapshot document bytes and owner-file bytes must check unchanged before frozen context construction. Owner text is checked before following its grounded Markdown locators. Authority changes block rather than changing approval or publication witnesses. Known protected owner/stripping filenames are refused before capture. The filename rule is conservative and is not a general credential detector.

Legacy pending/recovered worker runs check their decoded full retained batches (including related windows), decoded snapshot/owner authority, and exact sealed model request text before redispatch or recovered completion. Existing seals are not edited. The same frozen bytes and hashes remain authoritative. A legacy run can remain blocked if its retained read provenance is incomplete, its payload exceeds current protection bounds, or its text now requires replacement.

## Limits and compatibility

The production `dream-worker` path always supplies protection. Existing public library batch-preparation/run APIs remain caller-owned lower-level interfaces; they are not an archive attestation or an additional runtime source-root route. Queue/controller ingestion of previously completed legacy runs outside this worker is not retroactively certified by this gate.

No new durable scrub stamp or sanitized view is stored. Successful unchanged checks preserve original locator/range/digest and existing extraction version. Restart uses exact sealed bytes and repeats the check; it does not assume an archive was scrubbed or regenerate a different admitted view. Redaction changes, even length-preserving changes, are deliberately blocked. Supporting them requires a versioned immutable admitted view plus original-to-view range/prefix relation integrated with cursor validation, replay decoding, and saved-source verification; a temporary source root or post-dispatch substitution is not an equivalent implementation.

This gate does not complete secret-safe historical redacting intake, protected-output omission-and-continue, installation acceptance, or independent review acceptance. Credential-service implementation and TypeScript host consumer are separate owners. Synthetic tests use injected identity/replacement/failure replies only; no real helper, store, archive, or model is required.
