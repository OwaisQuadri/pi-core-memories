# Native source-protection and admitted views

The production dream-worker requires trusted host checking before any new frozen input, context, request or admission is written. Source records may be replaced with length-changing checked bytes. Approved-memory and owner authority must still check unchanged. No original archive, approved memory, cursor or legacy seal is rewritten.

## Private framing

Start is unchanged. Protection uses the existing private stdin/stdout newline-delimited JSON channel, not descriptor 3, a tool, model message or shared event broadcast. The host must intercept frames privately, never logging or publishing raw frames, pieces or arbitrary provider errors.

Native request, exact keys:

```json
{"version":1,"type":"sourceProtectionRequest","invocationID":"invocation","requestID":"fresh-UUID","inputDigest":"SHA256","pieces":["exact UTF-8"]}
```

Checked host reply, exact keys:

```json
{"version":1,"type":"sourceProtectionResult","invocationID":"invocation","requestID":"fresh-UUID","inputDigest":"SHA256","status":"checked","policy":"pi-credentials/redact-v1","pieces":["exact checked UTF-8"],"outputDigest":"SHA256"}
```

Blocked host reply, exact keys:

```json
{"version":1,"type":"sourceProtectionResult","invocationID":"invocation","requestID":"fresh-UUID","inputDigest":"SHA256","status":"blocked","code":"unavailable"}
```

Blocked codes: `not-ready`, `unavailable`, `timeout`, `cancelled`, `invalid-input`, `invalid-output`, `failed`. Blocked replies contain no pieces, policy, output digest or arbitrary error text.

Both digests are lowercase SHA-256 over each ordered piece's decimal UTF-8 byte count, ASCII colon and exact UTF-8 bytes, concatenated without an extra delimiter, JSON serialization or Unicode normalization. Native checks invocation/request/original-input binding, policy, piece count and bounds, and recomputes output digest. Only source admission consumes changed returned bytes; authority, cached/admitted material and derived-state rechecks require byte-exact unchanged output.

Bounds remain 1,000 pieces, 1,048,576 UTF-8 bytes per piece, 4,194,304 aggregate input bytes, 8,388,608 aggregate output bytes and 16 exchanges per invocation. JSON framing allows sixfold escaping. Each exchange has a 10-second native deadline. Host service work must leave transport margin and be cancelled when the worker exits. Cancel/EOF, unavailable, malformed, duplicate, late, mismatched or out-of-phase replies cannot authorize dispatch. Oversized requests fail rather than clip.

## Versioned source relation

Frozen preparation provenance optionally contains `admittedViews`. Absence preserves the legacy canonical representation. Each version-one view binds extraction version one, original relative path, original complete byte count/prefix hash, admitted full bytes/hash, and a relation hash over metadata and the ordered per-record relation.

Each relation records original start/end/record hash/complete-prefix hash, admitted start/end/record hash, preserved structural-identity hash and `isOmitted`. Original bodies are never stored in a new view. Session/entry/parent IDs, timestamps, working directory/classification, roles and tool-call identity/part structure must remain exact; structural changes or invalid returned JSON block. Source text, tool arguments/results/details, assistant context and raw retained/header fields are checked before extraction. Stripping files retain only admitted bytes plus a separate optional original hash; their aggregate stripping hash describes admitted inputs, not original bytes.

Original `SourcePosition` coordinates and prefix hashes remain durable cursors. Native maps original record boundaries into admitted coordinates only for admitted-byte validation/extraction. Evidence has an optional original witness separate from its admitted witness. Full-view validation verifies every admitted record/hash/identity and relation binding; selected records, skipped spans and classification provenance must match that exact view. No temporary root substitution is used.

Views are bounded to 1,000 records and 4 MiB admitted bytes per session, additionally bounded by private request limits, frozen-payload limits and the existing total state limit. Complete source units are never clipped. A large session can block until a separately authorized bounded strategy exists; this is not a general storage migration.

## Protected output omission

Before any private source frame, native links read results to their original calls. Protected paths include `.env` variants, auth/credential names, `.ssh`, `.aws`, `.netrc`, `.npmrc`, `.pem` and `.key`. Matching protected calls cannot bypass checking by changing the result's claimed tool name. Missing/mismatched read provenance is also omitted.

Only a minimal structural result stub is admitted and checked; content, details and other raw fields are discarded before the host exchange. Original record range/hash remains provenance; the relation marks the stub non-evidence. Other records proceed. Native never opens the tool's named target. Custom aliases, indirect shell reads and transformed/visual secrets are not proven covered by this conservative provenance rule or credential matching.

## Restart, legacy and queue verification

Completed frozen-chain verification supplies the latest trusted immutable views to fresh capture. Capture verifies each original prefix before reusing the exact admitted prefix and checks only new complete records for source replacement. Fresh admission and completed-chain verification require later views to extend the exact prior admitted bytes and record relations. Protection-catalogue changes cannot regenerate an old prefix; if an unchanged recheck would replace admitted bytes, the operation blocks instead.

Pending retry reuses exact sealed input/context/request. Legacy runs without a view retain the checked unchanged gate; old payloads are never resealed. Legacy cursors are not reset to rediscover excluded tools. New records after a legacy cursor can use a newly checked view without readmitting old primary evidence.

Queue candidates originate from the same verified frozen chain. Queue evidence `start`, `end` and `recordDigest` describe the original source; optional `admittedStart`, `admittedEnd` and `admittedRecordDigest` describe admitted bytes. Model request `locator` likewise remains original, with a separate `admittedLocator` only for admitted evidence. Source identity remains session/entry/part based, so changed protection output or proposal wording alone cannot reopen rejected evidence. Connected-window equality also checks original witness equality.

Approved snapshot and owner bytes check unchanged before frozen context construction and before following grounded owner links. Any required authority replacement blocks; no authority projection or publication-anchor mutation is performed.

This component does not retroactively certify raw legacy completed archives, replace caller-owned lower-level library APIs, establish human consent from model/tool bytes, or complete installation/sprint acceptance. Real TypeScript/service integration and independent review are separate gates. Tests use synthetic sources, private host fixtures and fake model sinks only.
