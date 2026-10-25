import Foundation
import Testing

@testable import CoreMemories

private func workerContext(_ request: [String: Any]) throws -> [String: Any] {
  let messages = try #require(request["messages"] as? [[String: Any]])
  let text = try #require(messages.first?["text"] as? String)
  return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func workerContextResponse(_ request: [String: Any], decisions: [[String: Any]]) throws
  -> String
{
  String(
    decoding: try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 1, "contextHash": request["contextHash"]!, "decisions": decisions,
      ], options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
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

@Test(arguments: [false, true])
func dreamWorkerFreshCaptureRetainsAdmittedWindowWithoutCountingItTwice(isRedacted: Bool) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Earlier RETAINED_SECRET preference."])
  let protect: ([String]) -> [String] = { pieces in
    pieces.map {
      isRedacted ? $0.replacingOccurrences(of: "RETAINED_SECRET", with: "[redacted]") : $0
    }
  }
  let first = try DreamWorkerProcess()
  defer { first.clean() }
  first.protectionTransform = protect
  try first.send(workerStart(fixture))
  let initial = try first.frame()
  try first.send(workerReply(initial, text: workerDecision(initial)))
  #expect(try first.frame()["generation"] as? String == "1")
  try first.finish()
  let priorProgress = try DreamRunEncoding.decode(
    DreamRunEncoding.Generation.self,
    bytes: Data(contentsOf: fixture.state.appendingPathComponent("generations/1.json"))
  )
  .progress.domain()
  try workerContextSession(fixture, text: "Later related preference.")
  let second = try DreamWorkerProcess()
  defer { second.clean() }
  second.protectionTransform = protect
  try second.send(workerStart(fixture))
  let request = try second.frame()
  #expect(request["generation"] as? String == "1")
  let context = try workerContext(request)
  let primary = try #require(context["primaryEvidence"] as? [[String: Any]])
  #expect(primary.count == 2)
  #expect(primary.filter { $0["isCurrentWindow"] as? Int == 1 }.count == 1)
  #expect(primary.filter { $0["isCurrentWindow"] as? Int == 0 }.count == 1)
  #expect((context["scopes"] as? [[String: Any]])?.count == 2)
  #expect((context["connectedWindowBindings"] as? [String])?.count == 2)
  if isRedacted { #expect(!String(describing: request).contains("RETAINED_SECRET")) }
  try second.send(workerReply(request, text: workerDecision(request)))
  #expect(try second.frame()["generation"] as? String == "2")
  try second.finish()
  let progress = try DreamRunEncoding.decode(
    DreamRunEncoding.Generation.self,
    bytes: Data(contentsOf: fixture.state.appendingPathComponent("generations/2.json"))
  )
  .progress.domain()
  #expect(progress.positions.count == 2)
  #expect(
    progress.positions.first { $0.relativePath == priorProgress.positions[0].relativePath }
      == priorProgress.positions[0])
  let repeatWorker = try DreamWorkerProcess()
  defer { repeatWorker.clean() }
  repeatWorker.protectionTransform = protect
  try repeatWorker.send(workerStart(fixture))
  let final = try repeatWorker.frame()
  #expect(final["status"] as? String == "noNewRecords")
  #expect(final["generation"] as? String == "2")
  try repeatWorker.finish()
}

@Test(arguments: ["valid", "copied", "stale-claim"])
func dreamWorkerRejectedCatalogueEnablesNativeSuccessorWithoutWeakeningAdmission(mode: String)
  throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Prefer green buttons."])
  let original = try workerContextReject(fixture)
  try workerContextSession(
    fixture, text: mode == "copied" ? "Prefer green buttons." : "Use blue buttons when printing.")
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  try worker.send(workerStart(fixture))
  let request = try worker.frame()
  let context = try workerContext(request)
  let predecessors = try #require(
    context["rejectedPredecessorsNotPrimaryEvidence"] as? [[String: Any]])
  let predecessor = try #require(predecessors.first)
  #expect(predecessors.count == 1)
  #expect(predecessor["revision"] as? String == original.revision)
  #expect(Data((predecessor["priorClaim"] as! String).utf8) == original.proposed)
  #expect(predecessor["path"] as? String == original.path)
  let primary = try #require(context["primaryEvidence"] as? [[String: Any]])
  let new = try #require(primary.first { $0["isCurrentWindow"] as? Int == 1 })
  let decision: [String: Any] = [
    "kind": "add", "scope": ["kind": "global"],
    "text": "Use blue buttons when printing; green otherwise.",
    "sources": primary.map { $0["source"]! }, "contradictions": [],
    "reason": "Preserve the new print condition.",
    "successor": [
      "version": 1, "predecessorRevision": predecessor["revision"]!,
      "priorClaim": mode == "stale-claim" ? "wrong bytes" : predecessor["priorClaim"]!,
      "newEvidence": [["source": new["source"]!, "contentDigest": new["contentDigest"]!]],
      "explanation": "The new source states a print exception to the earlier green preference.",
    ],
  ]
  try worker.send(workerReply(request, text: workerContextResponse(request, decisions: [decision])))
  #expect(try worker.frame()["status"] as? String == "completed")
  try worker.finish()
  let queue = try queueFixture(fixture, sources: fixture.store())
  let rows = try queue.list(request: MemoryQueueRequest(sessionID: "reviewer", requestID: "later"))
  let successor = try #require(rows.first { $0.finding.revision != original.revision })
  #expect((successor.blockReason == nil) == (mode == "valid"))
  if mode == "valid" {
    #expect(successor.finding.successorRejections == [original.revision])
    #expect(successor.finding.suppressionEpoch == successor.finding.revision)
  }
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
