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
