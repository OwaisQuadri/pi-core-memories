import Foundation
import Testing

@testable import CoreMemories

private func admittedBatch(
  _ fixture: TransactionFixture, progress: DreamProgress = try! DreamProgress(),
  prior: [DreamAdmittedView] = [], replacement: String = "[x]",
  inspect: @escaping ([String]) -> Void = { _ in }
) throws -> PreparedSessionBatch {
  try SessionReader(sessions: fixture.sessions, snippets: fixture.snippets, environment: [:])
    .prepareProtected(
      progress: progress, limits: DreamInputLimits(), protect: { pieces in inspect(pieces) },
      admit: { pieces in
        inspect(pieces)
        return pieces.map { $0.replacingOccurrences(of: "SYNTHETIC_SECRET", with: replacement) }
      }, priorViews: prior)
}

@Test func admittedStrippingRootIsCheckedInOneRequestAndRedactsOnlyItsSecretFile() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let secret = "---\nname: secret\n---\n\nSYNTHETIC_SECRET body\n"
  let plain = "---\nname: plain\n---\n\nPlain body\n"
  try fixture.write(secret, file: fixture.snippets.appendingPathComponent("b.md"))
  try fixture.write(plain, file: fixture.snippets.appendingPathComponent("c.md"))
  let original = try String(
    contentsOf: fixture.snippets.appendingPathComponent("strip.md"), encoding: .utf8)
  var requests: [[String]] = []
  let batch = try admittedBatch(fixture, inspect: { requests.append($0) })
  let secretRequests = requests.filter { $0.contains(secret) }
  #expect(secretRequests.count == 1)
  #expect(secretRequests.first.map(Set.init) == [secret, plain, original])
  let stripping = Dictionary(
    uniqueKeysWithValues: try #require(batch.provenance?.stripping).map { ($0.name, $0) })
  let redacted = secret.replacingOccurrences(of: "SYNTHETIC_SECRET", with: "[x]")
  #expect(stripping["b.md"]?.bytes == Data(redacted.utf8))
  #expect(stripping["b.md"]?.originalHash == SourceDigest(bytes: Data(secret.utf8)))
  #expect(stripping["c.md"]?.bytes == Data(plain.utf8))
  #expect(stripping["strip.md"]?.bytes == Data(original.utf8))
}

@Test func admittedViewLengthChangeKeepsOriginalCursorAndSeparateHashes() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Use SYNTHETIC_SECRET green buttons."])
  let raw = try Data(contentsOf: fixture.source)
  let batch = try admittedBatch(fixture)
  try SessionReader.verifyPreparation(batch)
  try DreamRunEncoding.validate(progress: DreamProgress(), batch: batch, limits: DreamRunLimits())
  let unit = try #require(batch.evidence.first)
  let origin = try #require(unit.originalWitness)
  #expect(unit.exactText == "Use [x] green buttons.")
  #expect(origin.rawRecordHash != unit.witness.rawRecordHash)
  #expect(origin.byteRange.count > unit.witness.byteRange.count)
  #expect(batch.positionsAfter.first?.completeBytes == UInt64(raw.count))
  #expect(batch.positionsAfter.first?.prefixHash == SourceDigest(bytes: raw))
  #expect(
    !String(decoding: batch.admittedViews[0].bytes, as: UTF8.self).contains("SYNTHETIC_SECRET"))
  let encoded = try DreamRunEncoding.batchBinding(batch, maximumBytes: 4_194_304)
  #expect(!String(decoding: encoded, as: UTF8.self).contains("SYNTHETIC_SECRET"))
  let queued = try MemoryQueueEvidence(unit)
  #expect(queued.start == String(origin.byteRange.lowerBound))
  #expect(queued.recordDigest == origin.rawRecordHash.rawValue)
  #expect(queued.admittedRecordDigest == unit.witness.rawRecordHash.rawValue)
  var originalUnit = unit
  originalUnit.originalWitness = nil
  #expect(try MemoryQueueEvidence(originalUnit).identity == queued.identity)
}

@Test func admittedViewAppendReusesIdenticalPriorBytesAndRejectsChangedOriginalPrefix() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["SYNTHETIC_SECRET first preference."])
  let first = try admittedBatch(fixture)
  let progress = try DreamProgress(generation: 1, positions: first.positionsAfter)
  try fixture.append(dreamUser("u2", nil, dreamOld, "SYNTHETIC_SECRET second preference.") + "\n")
  var checked: [String] = []
  let second = try admittedBatch(
    fixture, progress: progress, prior: first.admittedViews,
    replacement: "[different]", inspect: { checked += $0 })
  try DreamRunEncoding.validate(progress: progress, batch: second, limits: DreamRunLimits())
  #expect(second.evidence.count == 1)
  #expect(second.evidence[0].exactText == "[different] second preference.")
  #expect(second.admittedViews[0].bytes.starts(with: first.admittedViews[0].bytes))
  #expect(!checked.contains { $0.contains("first preference") })
  let raw = try String(contentsOf: fixture.source, encoding: .utf8)
  try fixture.write(
    raw.replacingOccurrences(of: "first preference", with: "other preference"), file: fixture.source
  )
  #expect(throws: (any Error).self) {
    try admittedBatch(fixture, progress: progress, prior: first.admittedViews)
  }
}

@Test func admittedViewProtectedReadOmitsBodyBeforeCheckingAndKeepsOtherEvidence() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Use green buttons."])
  try fixture.append(
    "{\"type\":\"message\",\"id\":\"a1\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"read1\",\"name\":\"read\",\"arguments\":{\"path\":\".env\"}}]}}\n"
  )
  try fixture.append(
    "{\"type\":\"message\",\"id\":\"r1\",\"timestamp\":\"2026-01-01T00:00:01Z\",\"message\":{\"role\":\"toolResult\",\"toolCallId\":\"read1\",\"toolName\":\"read\",\"isError\":false,\"content\":[{\"type\":\"text\",\"text\":\"SYNTHETIC_PROTECTED_BODY\"}],\"details\":{\"raw\":\"SYNTHETIC_PROTECTED_BODY\"}}}\n"
  )
  var sent: [String] = []
  let batch = try admittedBatch(fixture, inspect: { sent += $0 })
  #expect(!sent.contains { $0.contains("SYNTHETIC_PROTECTED_BODY") })
  #expect(batch.evidence.contains { $0.exactText == "Use green buttons." })
  #expect(!batch.evidence.contains { $0.id.citation.entry == "r1" })
  #expect(batch.admittedViews[0].records.last?.isOmitted == true)
  #expect(
    !String(decoding: batch.admittedViews[0].bytes, as: UTF8.self).contains(
      "SYNTHETIC_PROTECTED_BODY"))
  try DreamRunEncoding.validate(progress: DreamProgress(), batch: batch, limits: DreamRunLimits())
}

@Test func admittedViewMutatedBytesOrRelationCannotReplay() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["SYNTHETIC_SECRET preference."])
  let batch = try admittedBatch(fixture)
  let view = try #require(batch.admittedViews.first)
  let encoded = try DreamRunEncoding.encode(view)
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object["bytes"] = Data("changed\n".utf8).base64EncodedString()
  let broken = try JSONDecoder().decode(
    DreamAdmittedView.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(throws: (any Error).self) { try broken.validate() }
  object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object["originalPrefixHash"] = String(repeating: "0", count: 64)
  let stale = try JSONDecoder().decode(
    DreamAdmittedView.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(throws: (any Error).self) { try stale.validate() }
}

@Test func admittedViewWorkerFreezesSanitizedBytesAndReplaysExactRequestAcrossRestart() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["SYNTHETIC_SECRET durable preference."])
  let original = try fixture.protectedState()
  let first = try DreamWorkerProcess()
  defer { first.clean() }
  first.protectionTransform = {
    $0.map { $0.replacingOccurrences(of: "SYNTHETIC_SECRET", with: "[x]") }
  }
  try first.send(workerStart(fixture))
  let request = try first.frame()
  try #require(request["type"] as? String == "modelRequest")
  #expect(!String(describing: request).contains("SYNTHETIC_SECRET"))
  try first.send(workerReply(request, category: "cancelled"))
  #expect(try first.frame()["status"] as? String == "pending")
  try first.finish()
  let frozen = try fixture.snapshot(fixture.state.appendingPathComponent("runs"))
  #expect(
    frozen.values.allSatisfy {
      !String(decoding: $0.bytes, as: UTF8.self).contains("SYNTHETIC_SECRET")
    })
  let second = try DreamWorkerProcess()
  defer { second.clean() }
  try second.send(workerStart(fixture, resume: "retryInterruptedCall"))
  let retry = try second.frame()
  try #require(retry["type"] as? String == "modelRequest")
  #expect(retry["requestHash"] as? String == request["requestHash"] as? String)
  #expect(
    try JSONSerialization.data(withJSONObject: retry["messages"]!)
      == JSONSerialization.data(withJSONObject: request["messages"]!))
  try second.send(workerReply(retry, text: workerDecision(retry)))
  #expect(try second.frame()["status"] as? String == "completed")
  try second.finish()
  #expect(try fixture.protectedState() == original)
  try fixture.append(dreamUser("u2", nil, dreamOld, "Another preference.") + "\n")
  let third = try DreamWorkerProcess()
  defer { third.clean() }
  try third.send(workerStart(fixture))
  let appended = try third.frame()
  try #require(appended["type"] as? String == "modelRequest")
  #expect(!String(describing: appended).contains("SYNTHETIC_SECRET"))
  try third.send(workerReply(appended, text: workerDecision(appended)))
  #expect(try third.frame()["generation"] as? String == "2")
  try third.finish()
}

@Test func admittedViewChangedProtectionDoesNotReopenRejectedEvidenceIdentity() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Prefer SYNTHETIC_SECRET green buttons."])
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection,
      prepare: { try admittedBatch(fixture, progress: $0) }, call: { try transactionAdd($0) }))
  let queue = try queueFixture(fixture, sources: sources)
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "reject")
  let original = try #require(queue.list(request: request).first)
  let display = try queue.claim(revision: original.finding.revision, request: request)
  try queue.presented(display, messageReference: "shown")
  _ = try queue.decide(display, action: "reject", decisionID: "reject", responseReference: "human")
  let other = try TransactionFixture()
  defer { other.clean() }
  try other.populate(texts: ["Prefer SYNTHETIC_SECRET green buttons."])
  let otherSources = try other.store()
  _ = try transactionCompleted(
    otherSources.run(
      selection: other.selection,
      prepare: { try admittedBatch(other, progress: $0, replacement: "[different]") },
      call: { model in
        let context = try transactionObject(model)
        let evidence = context["primaryEvidence"] as! [[String: Any]]
        return try transactionResponse(
          model,
          decisions: [
            [
              "kind": "add", "scope": ["kind": "global"], "text": "Use green interface controls.",
              "sources": evidence.map { $0["source"]! }, "contradictions": [],
              "reason": "Changed proposal text.",
            ]
          ])
      }))
  let rows: [MemoryReviewCandidate]
  do {
    let review = try MemoryReviewController(
      repository: other.memory,
      stateRoot: other.root.appendingPathComponent("review"), sources: otherSources,
      environment: [:])
    rows = try review.list()
  }
  let review = try queue.controller()
  let later = try MemoryQueueRequest(sessionID: "later", requestID: "later")
  let imported = try #require(queue.importCandidates(rows, review: review, request: later).first)
  #expect(imported.finding.evidence[0].identity == original.finding.evidence[0].identity)
  #expect(imported.finding.evidence[0].contentDigest != original.finding.evidence[0].contentDigest)
  #expect(imported.blockReason != nil)
  #expect(imported.finding.evidence[0].admittedRecordDigest != nil)
}

@Test func admittedViewRewrittenPriorRelationCannotExtendCompletedView() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["SYNTHETIC_SECRET first preference."])
  let first = try admittedBatch(fixture)
  let prior = try #require(first.admittedViews.first)
  var object = try #require(
    JSONSerialization.jsonObject(with: DreamRunEncoding.encode(prior)) as? [String: Any])
  var records = object["records"] as! [[String: Any]]
  records[1]["originalHash"] = String(repeating: "0", count: 64)
  object["records"] = records
  let rewritten = try JSONDecoder().decode(
    DreamAdmittedView.self, from: JSONSerialization.data(withJSONObject: object)
  ).sealed()
  try rewritten.validate()
  #expect(throws: DreamSourceProtectionError.invalidReply) {
    try rewritten.requireExtension(of: prior)
  }
}

@Test func admittedViewLegacyCheckedRetryNeverResealsOldPayloads() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  _ = try fixture.store().run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { _ in throw CancellationError() })
  let names = ["input.json", "context.json", "request.json"]
  let before = try names.map { try Data(contentsOf: fixture.payload($0)) }
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  try worker.send(workerStart(fixture, resume: "retryInterruptedCall"))
  let request = try worker.frame()
  try #require(request["type"] as? String == "modelRequest")
  try worker.send(workerReply(request, text: workerDecision(request)))
  #expect(try worker.frame()["status"] as? String == "completed")
  try worker.finish()
  #expect(try names.map { try Data(contentsOf: fixture.payload($0)) } == before)
}

@Test func admittedWindowsAdvanceLargeHistoricalSessionWithoutReadmittingOldEvidence() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: (0..<1_100).map { "SYNTHETIC_SECRET preference \($0)." })
  let original = try Data(contentsOf: fixture.source)
  let first = try admittedBatch(fixture)
  #expect(first.isBacklog)
  #expect(first.admittedViews[0].version == 2)
  #expect(first.admittedViews[0].records.count <= 256)
  #expect(first.positionsAfter[0].completeBytes < UInt64(original.count))
  let progress = try DreamProgress(generation: 1, positions: first.positionsAfter)
  let second = try admittedBatch(fixture, progress: progress, prior: first.admittedViews)
  try DreamRunEncoding.validate(progress: progress, batch: second, limits: DreamRunLimits())
  try second.admittedViews[0].requireExtension(of: first.admittedViews[0])
  #expect(second.isBacklog)
  #expect(second.positionsAfter[0].completeBytes > first.positionsAfter[0].completeBytes)
  #expect(second.admittedViews[0].records.count <= 256)
  #expect(Set(first.evidence.map(\.id)).isDisjoint(with: Set(second.evidence.map(\.id))))
  #expect(!second.evidence.isEmpty)
  #expect(
    second.admittedViews[0].window?.predecessorRelationHash == first.admittedViews[0].relationHash)
  #expect(
    second.positionsAfter[0].prefixHash
      == SourceDigest(bytes: original.prefix(Int(second.positionsAfter[0].completeBytes))))
  let store = try fixture.store()
  var observed: Set<PrimaryTextID> = []
  var isPriorWindowIncluded = false
  for _ in 0..<2 {
    _ = try transactionCompleted(
      store.run(
        selection: fixture.selection,
        sourceRoles: DreamSourceRoles(isSnippetsPresent: true, isPromptsPresent: false),
        protect: { _ in },
        prepare: { progress, sources in
          try admittedBatch(fixture, progress: progress, prior: sources.admittedViews)
        },
        call: { request in
          let context = try transactionObject(request)
          let primary = context["primaryEvidence"] as! [[String: Any]]
          #expect(!primary.isEmpty && primary.count <= 1_000)
          #expect((context["connectedWindowBindings"] as? [String] ?? []).count <= 8)
          #expect(!String(describing: context).contains("SYNTHETIC_SECRET"))
          for item in primary {
            let source = item["source"] as! [String: Any]
            let id = PrimaryTextID(
              citation: Citation(
                session: source["session"] as! String, entry: source["entry"] as! String),
              part: source["part"] as! Int)
            if item["isCurrentWindow"] as? Int == 1 {
              #expect(observed.insert(id).inserted)
            } else {
              isPriorWindowIncluded = true
              #expect(observed.contains(id))
            }
          }
          return try transactionNotes(request)
        }))
  }
  #expect(isPriorWindowIncluded)
  #expect(observed == Set((first.evidence + second.evidence).map(\.id)))
}
