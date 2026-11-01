import Foundation
import Testing

@testable import CoreMemories

private func workerContext(_ request: [String: Any]) throws -> [String: Any] {
  let messages = try #require(request["messages"] as? [[String: Any]])
  let text = try #require(messages.first?["text"] as? String)
  return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func workerContextSession(_ fixture: TransactionFixture, text: String, cwd: String? = nil)
  throws
{
  try fixture.write(
    dreamHeader("two", cwd: cwd ?? fixture.root.path, name: nil) + "\n"
      + dreamUser("later", nil, dreamOld, text) + "\n",
    file: fixture.sessions.appendingPathComponent("--fixture--/two.jsonl"))
}

private func workerContextReject(_ fixture: TransactionFixture, claim: String? = nil) throws
  -> MemoryQueueFinding
{
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  try worker.send(workerStart(fixture))
  let request = try worker.frame()
  var text = try workerDecision(request, isProposal: true)
  if let claim { text = text.replacingOccurrences(of: "Use green buttons.", with: claim) }
  try worker.send(workerReply(request, text: text))
  #expect(try worker.frame()["status"] as? String == "completed")
  try worker.finish()
  let queue = try queueFixture(fixture, sources: fixture.store())
  let identity = try MemoryQueueRequest(sessionID: "reviewer", requestID: "reject")
  let finding = try #require(queue.list(request: identity).first?.finding)
  let display = try queue.claim(revision: finding.revision, request: identity)
  try queue.presented(display, messageReference: "shown")
  let receipt = try queue.decide(
    display, action: "reject", decisionID: "reject", responseReference: "human")
  #expect(receipt.status == "rejected")
  return finding
}

@Test(arguments: ["fresh", "replay", "catalogue-only-replay"])
func dreamWorkerHistoricalLiveExclusionPrecedesProtectionAndFrozenReplay(mode: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: [String(repeating: "OLD_SESSION_SENTINEL ", count: 10)])
  _ = try workerContextReject(fixture, claim: "PRIOR_CLAIM_SENTINEL")
  try workerContextSession(
    fixture,
    text: mode == "catalogue-only-replay"
      ? String(repeating: "x", count: 262_144)
      : "Later preference.")
  let first = try DreamWorkerProcess()
  defer { first.clean() }
  var start = workerStart(fixture)
  if mode == "fresh" { start["excludedSessionIDs"] = ["one"] }
  var checked: [String] = []
  first.protectionTransform = {
    checked += $0
    return $0
  }
  try first.send(start)
  let request = try first.frame()
  let context = try workerContext(request)
  if mode == "fresh" {
    #expect(!String(describing: request).contains("OLD_SESSION_SENTINEL"))
    #expect(!String(describing: request).contains("PRIOR_CLAIM_SENTINEL"))
    #expect(
      !checked.contains {
        $0.contains("OLD_SESSION_SENTINEL") || $0.contains("PRIOR_CLAIM_SENTINEL")
      })
    try first.send(workerReply(request, text: workerDecision(request)))
    #expect(try first.frame()["status"] as? String == "completed")
    try first.finish()
    return
  }
  if mode == "catalogue-only-replay" {
    #expect((context["connectedWindowBindings"] as? [String])?.isEmpty == true)
  }
  #expect((context["rejectedPredecessorsNotPrimaryEvidence"] as? [[String: Any]])?.count == 1)
  try first.send(workerReply(request, category: "failed"))
  #expect(try first.frame()["status"] as? String == "pending")
  try first.finish()
  let names = ["input.json", "context.json", "request.json"]
  let frozen = try names.map { try Data(contentsOf: fixture.payload($0, generation: 1)) }
  let retry = try DreamWorkerProcess()
  defer { retry.clean() }
  checked = []
  retry.protectionTransform = {
    checked += $0
    return $0
  }
  start = workerStart(fixture, resume: "retryInterruptedCall")
  start["excludedSessionIDs"] = ["one"]
  try retry.send(start)
  #expect(try retry.frame()["status"] as? String == "blocked")
  try retry.finish()
  #expect(checked.isEmpty)
  #expect(try names.map { try Data(contentsOf: fixture.payload($0, generation: 1)) } == frozen)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/2.json").path))
}

@Test(arguments: [false, true])
func dreamWorkerRejectedCatalogueRegisteredSecretBlocksFreshAndReplay(isReplay: Bool) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Prefer green buttons."])
  _ = try workerContextReject(fixture, claim: "RegisteredClaimSecret")
  try workerContextSession(fixture, text: "Later preference.")
  if isReplay {
    let first = try DreamWorkerProcess()
    defer { first.clean() }
    try first.send(workerStart(fixture))
    let request = try first.frame()
    try first.send(workerReply(request, category: "failed"))
    #expect(try first.frame()["status"] as? String == "pending")
    try first.finish()
  }
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  var isClaimChecked = false
  worker.protectionTransform = { pieces in
    isClaimChecked = isClaimChecked || pieces.contains { $0.contains("RegisteredClaimSecret") }
    return pieces.map { $0.replacingOccurrences(of: "RegisteredClaimSecret", with: "[redacted]") }
  }
  try worker.send(
    workerStart(fixture, resume: isReplay ? "retryInterruptedCall" : "inspectOrContinue"))
  let final = try worker.frame()
  try #require(final["status"] as? String == "blocked", "Unexpected worker frame: \(final)")
  #expect(final["reason"] as? String == "sourceProtection:changed")
  try worker.finish()
  #expect(isClaimChecked)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/2.json").path))
}

@Test func dreamWorkerUnverifiedOldSourceIsNotReintroducedByHistoryOrCatalogue() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["OLD_SOURCE_SENTINEL"])
  let finding = try workerContextReject(fixture, claim: "OLD_CLAIM_SENTINEL")
  try fixture.populate(texts: ["Rewritten source with the old timestamp."])
  try FileManager.default.setAttributes(
    [.modificationDate: Date().addingTimeInterval(-8 * 86_400)], ofItemAtPath: fixture.source.path)
  try workerContextSession(fixture, text: "A current preference.")
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  try worker.send(workerStart(fixture))
  let request = try worker.frame()
  let context = try workerContext(request)
  #expect((context["primaryEvidence"] as? [[String: Any]])?.count == 1)
  #expect(context["rejectedPredecessorsNotPrimaryEvidence"] == nil)
  #expect(!String(describing: request).contains("OLD_SOURCE_SENTINEL"))
  #expect(!String(describing: request).contains("OLD_CLAIM_SENTINEL"))
  let prior = try #require(context["priorFindingsNotPrimaryEvidence"] as? [String: Any])
  #expect((prior["findings"] as? [[String: Any]])?.isEmpty == true)
  #expect((prior["omitted"] as? [String: Any])?["unverifiedSource"] as? Int == 1)
  #expect(
    (context["limitations"] as? [String])?.contains {
      $0.contains("currently verified admitted source view")
    } == true)
  try worker.send(workerReply(request, text: workerDecision(request)))
  #expect(try worker.frame()["status"] as? String == "completed")
  try worker.finish()
  let queue = try queueFixture(fixture, sources: fixture.store())
  let rows = try queue.list(request: MemoryQueueRequest(sessionID: "reviewer", requestID: "later"))
  #expect(rows.first { $0.finding.revision == finding.revision }?.finding == finding)
}

@Test func dreamWorkerPriorContextSuppliesOtherSessionNotesAndFindingsAndReplaysFrozen() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Prefer green buttons."])
  let rejected = try workerContextReject(fixture)
  try workerContextSession(fixture, text: "Later preference.")
  let second = try DreamWorkerProcess()
  defer { second.clean() }
  try second.send(workerStart(fixture))
  let noted = try second.frame()
  try second.send(workerReply(noted, text: workerDecision(noted)))
  #expect(try second.frame()["status"] as? String == "completed")
  try second.finish()
  let elsewhere = fixture.root.appendingPathComponent("elsewhere")
  try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
  try fixture.write(
    dreamHeader("three", cwd: elsewhere.path, name: nil) + "\n"
      + dreamUser("third", nil, dreamOld, "An unrelated preference.") + "\n",
    file: fixture.sessions.appendingPathComponent("--fixture--/three.jsonl"))
  let third = try DreamWorkerProcess()
  defer { third.clean() }
  try third.send(workerStart(fixture))
  let request = try third.frame()
  let context = try workerContext(request)
  let primary = try #require(context["primaryEvidence"] as? [[String: Any]])
  #expect(primary.allSatisfy { ($0["source"] as? [String: Any])?["session"] as? String == "three" })
  let notes = try #require(context["priorDreamNotesNotPrimaryEvidence"] as? [String: Any])
  let noteItems = try #require(notes["notes"] as? [[String: Any]])
  #expect(!noteItems.isEmpty)
  #expect(noteItems.allSatisfy { $0["explanation"] as? String == "Synthetic Unicode café 🌱 note." })
  #expect(noteItems.allSatisfy { $0["generation"] as? Int == 1 })
  let findings = try #require(context["priorFindingsNotPrimaryEvidence"] as? [String: Any])
  let findingItems = try #require(findings["findings"] as? [[String: Any]])
  #expect(findingItems.count == 1)
  #expect(findingItems.first?["revision"] as? String == rejected.revision)
  #expect(findingItems.first?["status"] as? String == "rejected")
  #expect(findingItems.first?["sessions"] as? [String] == ["one"])
  #expect((findings["omitted"] as? [String: Any])?["unverifiedSource"] as? Int == 0)
  #expect((request["systemPrompt"] as? String)?.contains("priorFindingsNotPrimaryEvidence") == true)
  try third.send(workerReply(request, category: "failed"))
  #expect(try third.frame()["status"] as? String == "pending")
  try third.finish()
  try FileManager.default.removeItem(at: fixture.source)
  let retry = try DreamWorkerProcess()
  defer { retry.clean() }
  try retry.send(workerStart(fixture, resume: "retryInterruptedCall"))
  let replay = try retry.frame()
  #expect(NSDictionary(dictionary: replay).isEqual(to: request))
  try retry.send(workerReply(replay, text: workerDecision(replay)))
  #expect(try retry.frame()["status"] as? String == "completed")
  try retry.finish()
}

@Test func dreamWorkerFiltersLiveNotesBeforeRetainingNewestForty() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let oldRoot = fixture.root.appendingPathComponent("old")
  try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
  try fixture.populate(texts: ["Old live source."], cwd: oldRoot.path)
  for index in 0..<42 {
    let session = index == 0 ? "one" : String(format: "s%02d", index)
    if index > 0 {
      let sessionRoot = fixture.root.appendingPathComponent(session)
      try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
      try fixture.write(
        dreamHeader(session, cwd: sessionRoot.path, name: nil) + "\n"
          + dreamUser("u", nil, dreamOld, "Source \(session).") + "\n",
        file: fixture.sessions.appendingPathComponent("--fixture--/\(session).jsonl"))
    }
    let worker = try DreamWorkerProcess()
    defer { worker.clean() }
    try worker.send(workerStart(fixture))
    let request = try worker.frame()
    let primary = try #require(workerContext(request)["primaryEvidence"] as? [[String: Any]])
    let source = try #require(primary.first?["source"] as? [String: Any])
    #expect(primary.count == 1)
    #expect(source["session"] as? String == session)
    let explanation = session == "one" ? "LIVE_OLD_NOTE_TEXT"
      : session == "s40" ? "LIVE_NEW_NOTE_TEXT" : "Note \(session)."
    let response = try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 1, "contextHash": request["contextHash"]!,
        "decisions": [[
          "kind": "noChange", "sources": [source], "reasonCode": "notDurable",
          "explanation": explanation,
        ]],
      ], options: [.sortedKeys, .withoutEscapingSlashes])
    try worker.send(workerReply(request, text: String(decoding: response, as: UTF8.self)))
    #expect(try worker.frame()["status"] as? String == "completed")
    try worker.finish()
  }
  try workerContextSession(fixture, text: "Current source.")
  let second = try DreamWorkerProcess()
  defer { second.clean() }
  var start = workerStart(fixture)
  start["excludedSessionIDs"] = ["one", "s40"]
  try second.send(start)
  let request = try second.frame()
  let context = try workerContext(request)
  let prior = try #require(context["priorDreamNotesNotPrimaryEvidence"] as? [String: Any])
  let notes = try #require(prior["notes"] as? [[String: Any]])
  #expect(notes.count == 40)
  #expect(notes.first?["explanation"] as? String == "Note s41.")
  #expect(notes.last?["explanation"] as? String == "Note s01.")
  #expect((prior["omitted"] as? [String: Any])?["overBudget"] as? Int == 0)
  #expect((prior["omitted"] as? [String: Any])?["liveSession"] as? Int == 2)
  #expect((prior["omitted"] as? [String: Any])?["unverifiedSource"] as? Int == 0)
  let saved = try Data(contentsOf: fixture.payload("request.json", generation: 42))
  #expect(!String(decoding: saved, as: UTF8.self).contains("LIVE_OLD_NOTE_TEXT"))
  #expect(!String(decoding: saved, as: UTF8.self).contains("LIVE_NEW_NOTE_TEXT"))
  try second.send(workerReply(request, text: workerDecision(request)))
  #expect(try second.frame()["status"] as? String == "completed")
  try second.finish()
}

@Test func dreamPriorContextCountsOlderAndNewestLiveNotesBeforeBudgetOmissions() throws {
  let history = (0..<42).map { index in
    DreamPriorCandidate(
      item: DreamPriorNote(
        generation: 1, kind: "noChange", reasonCode: "notDurable",
        explanation: "Note \(index).", sessions: ["s\(index)"]),
      sessions: ["s\(index)"], sourcePaths: ["--fixture--/s\(index).jsonl"])
  }
  let context = try #require(
    try DreamPriorContext(
      newestNotes: history.filter { $0.sessions != ["s0"] && $0.sessions != ["s40"] },
      olderNoteCount: 2, olderLiveNoteCount: 2, newestFindings: [],
      excludedSessionIDs: ["s0", "s40"],
      isVerified: { !$0.contains("--fixture--/s2.jsonl") }))
  #expect(context.notes.count == 39)
  #expect(context.notes.first?.explanation == "Note 1.")
  #expect(context.notes.last?.explanation == "Note 41.")
  #expect(context.omittedNotes == DreamPriorOmissions(
    overBudget: 0, liveSession: 2, unverifiedSource: 1))
  #expect(context.isWithinBudget)
}

@Test func dreamPriorContextKeepsNewestWithinCapsAndCountsOmissions() throws {
  let notes = (0..<50).map { index in
    DreamPriorCandidate(
      item: DreamPriorNote(
        generation: UInt64(index), kind: "noChange", reasonCode: "notDurable",
        explanation: "Note \(index).", sessions: ["s\(index)"]),
      sessions: ["s\(index)"], sourcePaths: ["--fixture--/s\(index).jsonl"])
  }
  let findings = (0..<30).map { index in
    DreamPriorCandidate(
      item: DreamOpenFinding(
        revision: String(repeating: String(index % 10), count: 64), status: "pending",
        path: "global.md", claim: String(repeating: "x", count: 5_000), reason: "Reason.",
        sessions: ["f\(index)"]),
      sessions: ["f\(index)"], sourcePaths: index == 1 ? ["--fixture--/changed.jsonl"] : ["--fixture--/f.jsonl"])
  }
  let context = try #require(
    try DreamPriorContext(
      newestNotes: notes, olderNoteCount: 7, newestFindings: findings,
      excludedSessionIDs: ["s0"], isVerified: { !$0.contains("--fixture--/changed.jsonl") }))
  #expect(context.notes.map(\.explanation) == (1...40).map { "Note \($0)." })
  #expect(context.omittedNotes == DreamPriorOmissions(overBudget: 16, liveSession: 1))
  #expect(context.findings.allSatisfy { $0.claim.utf8.count == DreamPriorContext.maximumTextBytes })
  #expect(try DreamRunEncoding.encode(context.findings).count <= DreamPriorContext.maximumFindingBytes)
  #expect(context.findings.first?.sessions == ["f0"])
  #expect(!context.findings.contains { $0.sessions == ["f1"] })
  #expect(context.omittedFindings.unverifiedSource == 1)
  #expect(context.findings.count + context.omittedFindings.overBudget + 1 == 30)
  #expect(context.isWithinBudget)
}
