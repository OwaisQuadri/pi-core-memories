import Darwin
import Foundation
import Testing
import XCTest

@testable import CoreMemories
@testable import PiCoreMemories

final class MemoryQueueWorkerProcessHelper: XCTestCase {
  func testQueueWorkerHelper() throws {
    guard ProcessInfo.processInfo.environment["MEMORY_QUEUE_HELPER"] == "1" else { return }
    guard dup2(STDERR_FILENO, 3) == 3 else { throw MemoryError("missing queue control pipe") }
    let null = open("/dev/null", O_WRONLY)
    guard null >= 0, dup2(null, STDERR_FILENO) == STDERR_FILENO else {
      throw MemoryError("cannot isolate queue diagnostics")
    }
    _ = close(null)
    _exit(executeMemoryQueueWorker(arguments: ["memory-queue-worker"]))
  }
}

private final class QueueWorkerFixture {
  let input = Pipe()
  let output = Pipe()
  let control = Pipe()
  let process = Process()
  let invocation = "queue-fixture"

  init(config: URL, isReviewAvailable: Bool = true) throws {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
      "xctest", "-XCTest", "CoreMemoriesTests.MemoryQueueWorkerProcessHelper/testQueueWorkerHelper",
      Bundle(for: MemoryQueueWorkerProcessHelper.self).bundleURL.path,
    ]
    process.environment = ["PATH": "/usr/bin:/bin", "MEMORY_QUEUE_HELPER": "1"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = control.fileHandleForReading
    try process.run()
    try input.fileHandleForReading.close()
    try output.fileHandleForWriting.close()
    try control.fileHandleForReading.close()
    try send("start", ["config": config.path])
    let ready = try frame()
    #expect(ready["type"] as? String == "ready")
    #expect(ready["isReviewAvailable"] as? Bool == isReviewAvailable)
  }

  deinit {
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }

  func send(_ type: String, _ fields: [String: Any] = [:], isControl: Bool = false) throws {
    var object = fields
    object["version"] = 1
    object["type"] = type
    object["invocationID"] = invocation
    let bytes = try JSONSerialization.data(withJSONObject: object) + Data([10])
    try (isControl ? control : input).fileHandleForWriting.write(contentsOf: bytes)
  }

  func frame() throws -> [String: Any] {
    var bytes = Data()
    while bytes.count < 8 * 1_048_576 {
      var descriptor = pollfd(
        fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
      let readiness = poll(&descriptor, 1, 10_000)
      let failureCode = readiness < 0 ? errno : 0
      guard readiness == 1 else {
        let helper = process.isRunning ? "running" : "exit \(process.terminationStatus)"
        throw MemoryError(
          "queue frame missing: poll=\(readiness), errno=\(failureCode), events=\(descriptor.revents), bytes=\(bytes.count), helper=\(helper)")
      }
      guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
        let helper = process.isRunning ? "running" : "exit \(process.terminationStatus)"
        throw MemoryError("queue frame missing: EOF, bytes=\(bytes.count), helper=\(helper)")
      }
      if byte == Data([10]) {
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      }
      bytes.append(byte)
    }
    throw MemoryError("queue frame too large")
  }

  func claim() throws -> [String: Any] {
    try send("list", ["sessionID": "session", "requestID": "request", "offset": "0"])
    let rows = try #require(frame()["rows"] as? [[String: Any]])
    let finding = try #require(rows.first?["finding"] as? [String: Any])
    try send(
      "claim", ["sessionID": "session", "requestID": "request", "revision": finding["revision"]!])
    let frame = try frame()
    let bytes = try #require(Data(base64Encoded: frame["displayBytes"] as! String))
    let display = try #require(frame["display"] as? [String: Any])
    #expect(display["displayDigest"] as? String == SourceDigest(bytes: bytes).rawValue)
    return display
  }

  func tuple(_ display: [String: Any]) throws -> [String: Any] {
    let presentation = try #require(display["presentation"] as? [String: Any])
    let finding = try #require(presentation["finding"] as? [String: Any])
    let request = try #require(presentation["request"] as? [String: Any])
    return [
      "claimID": presentation["claimID"]!, "sequence": presentation["sequence"]!,
      "revision": finding["revision"]!, "previewDigest": presentation["previewDigest"]!,
      "displayDigest": display["displayDigest"]!, "sessionID": request["sessionID"]!,
      "requestID": request["requestID"]!,
    ]
  }
}

private func queueWorkerConfig(_ fixture: TransactionFixture) throws -> URL {
  var configuration = MemoryConfiguration.defaults
  configuration.roots = DreamControlRoots(
    state: fixture.state.path, sessions: fixture.sessions.path, memory: fixture.memory.path,
    snippets: fixture.snippets.path, prompts: nil, globalAgents: nil)
  configuration.reviewState = fixture.root.appendingPathComponent("review").path
  configuration.journal = fixture.root.appendingPathComponent("journal").path
  configuration.diagnostics = fixture.root.appendingPathComponent("diagnostics").path
  let url = fixture.root.appendingPathComponent("config/config.json")
  try configuration.save(to: url)
  return url
}

@Test(arguments: ["host-eof", "control-eof", "helper-death"])
func queueWorkerDuplicateOwnerIsBusyAndHostDeathReleasesWithoutApproving(mode: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let config = try queueWorkerConfig(fixture)
  let original = try fixture.main()
  let worker = try QueueWorkerFixture(config: config)
  let display = try worker.claim()
  let competitor = try queueFixture(fixture, sources: sources)
  #expect(throws: DreamRunError.busy) {
    try competitor.list(request: MemoryQueueRequest(sessionID: "other", requestID: "other"))
  }
  if mode == "helper-death" {
    #expect(kill(worker.process.processIdentifier, SIGKILL) == 0)
  } else {
    try (mode == "host-eof" ? worker.input : worker.control).fileHandleForWriting.close()
    #expect(try worker.frame()["type"] as? String == "final")
  }
  worker.process.waitUntilExit()
  let rows = try competitor.list(
    request: MemoryQueueRequest(sessionID: "other", requestID: "other"))
  #expect(!rows.isEmpty)
  let finding = (display["presentation"] as! [String: Any])["finding"] as! [String: Any]
  let successor = try competitor.claim(
    revision: finding["revision"] as! String,
    request: MemoryQueueRequest(sessionID: "other", requestID: "other"))
  #expect(
    successor.presentation.claimID != (display["presentation"] as! [String: Any])["claimID"]
      as? String)
  competitor.release()
  #expect(try fixture.main() == original)
}

@Test(arguments: ["valid", "stdin", "stale", "legacy-choice"])
func queueWorkerOnlyExactPrivateOriginalReplyReturnsReceipt(mode: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  do {
    let controller = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: sources, environment: [:])
    try controller.confirmDetach(controller.checkoutPreview())
  }
  let worker = try QueueWorkerFixture(config: queueWorkerConfig(fixture))
  let original = try fixture.main()
  let display = try worker.claim()
  var tuple = try worker.tuple(display)
  tuple["messageReference"] = "message"
  try worker.send("presented", tuple, isControl: true)
  #expect(try worker.frame()["type"] as? String == "presented")
  tuple.removeValue(forKey: "messageReference")
  tuple["originalText"] = "Save that memory"
  tuple["submittedText"] = "Save that memory"
  tuple["decisionID"] = "save-1"
  tuple["responseReference"] = "human-response"
  if mode == "stale" { tuple["requestID"] = "foreign-request" }
  if mode == "legacy-choice" {
    tuple.removeValue(forKey: "originalText")
    tuple.removeValue(forKey: "submittedText")
    tuple["action"] = "approve"
    tuple["isInteractive"] = true
  }
  try worker.send(mode == "legacy-choice" ? "choice" : "reply", tuple, isControl: mode != "stdin")
  let outcome = try worker.frame()
  if mode == "valid" {
    #expect(outcome["type"] as? String == "decision")
    let receipt = try #require(outcome["receipt"] as? [String: Any])
    #expect(receipt["status"] as? String == "approved")
    #expect(receipt["commit"] as? String == (try fixture.main()))
    try worker.send("recover", ["decisionID": "save-1"])
    #expect(try worker.frame()["receipt"] as? NSDictionary == receipt as NSDictionary)
    try worker.send("finish")
    #expect(try worker.frame()["type"] as? String == "final")
  } else {
    #expect(outcome["type"] as? String == "final")
    #expect(try fixture.main() == original)
  }
  worker.process.waitUntilExit()
}

@Test func queueWorkerOriginalReplyRetainsTheExactClaimUntilAnExplicitDecision() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  do {
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: sources, environment: [:])
    try review.confirmDetach(review.checkoutPreview())
  }
  let worker = try QueueWorkerFixture(config: queueWorkerConfig(fixture))
  let base = try fixture.main()
  let display = try worker.claim()
  var tuple = try worker.tuple(display)
  tuple["messageReference"] = "shown-memory"
  try worker.send("presented", tuple, isControl: true)
  #expect(try worker.frame()["type"] as? String == "presented")
  tuple.removeValue(forKey: "messageReference")
  tuple["decisionID"] = "conversation-save"
  tuple["responseReference"] = "original-reply"
  for (original, submitted) in [
    ("Yes", "Yes"),
    ("Save that memory", "Do not save that memory"),
    ("Save that memory if it is correct", "Save that memory if it is correct"),
  ] {
    tuple["originalText"] = original
    tuple["submittedText"] = submitted
    try worker.send("reply", tuple, isControl: true)
    #expect(try worker.frame()["type"] as? String == "reply-clarify")
    #expect(try fixture.main() == base)
  }
  let competitor = try queueFixture(fixture, sources: sources)
  #expect(throws: DreamRunError.busy) {
    try competitor.list(request: MemoryQueueRequest(sessionID: "other", requestID: "other"))
  }
  tuple["originalText"] = "Please save that memory as shown."
  tuple["submittedText"] = "Please save that memory as shown."
  try worker.send("reply", tuple, isControl: true)
  let result = try worker.frame()
  #expect(result["type"] as? String == "decision")
  let receipt = try #require(result["receipt"] as? [String: Any])
  #expect(receipt["status"] as? String == "approved")
  #expect(receipt["commit"] as? String == (try fixture.main()))
  #expect(receipt["auditRef"] is String)
  #expect(try fixture.main() != base)
  try worker.send("recover", ["decisionID": "conversation-save"])
  #expect(try worker.frame()["receipt"] as? NSDictionary == receipt as NSDictionary)
  try worker.send("finish")
  #expect(try worker.frame()["type"] as? String == "final")
  worker.process.waitUntilExit()
}

@Test(arguments: ["stdin", "stale", "before-presentation", "model-action"])
func queueWorkerRejectsMisroutedOrExpandedOriginalReplyFrames(mode: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  do {
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: sources, environment: [:])
    try review.confirmDetach(review.checkoutPreview())
  }
  let worker = try QueueWorkerFixture(config: queueWorkerConfig(fixture))
  let base = try fixture.main()
  var tuple = try worker.tuple(worker.claim())
  if mode != "before-presentation" {
    tuple["messageReference"] = "shown-memory"
    try worker.send("presented", tuple, isControl: true)
    #expect(try worker.frame()["type"] as? String == "presented")
    tuple.removeValue(forKey: "messageReference")
  }
  tuple["originalText"] = "Save that memory"
  tuple["submittedText"] = "Save that memory"
  tuple["decisionID"] = "not-approved"
  tuple["responseReference"] = "original-reply"
  if mode == "stale" { tuple["requestID"] = "foreign-request" }
  if mode == "model-action" { tuple["action"] = "approve" }
  try worker.send("reply", tuple, isControl: mode != "stdin")
  #expect(try worker.frame()["type"] as? String == "final")
  worker.process.waitUntilExit()
  #expect(try fixture.main() == base)
}

@Test func queueWorkerDifferentReviewProfilesRaceForOneRepositoryBinding() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try reviewCompletedSiblings(fixture)
  let firstConfig = try queueWorkerConfig(fixture)
  var secondConfiguration = try MemoryConfiguration.load(from: firstConfig)
  secondConfiguration.reviewState = fixture.root.appendingPathComponent("other-review").path
  let secondConfig = fixture.root.appendingPathComponent("config/second.json")
  try secondConfiguration.save(to: secondConfig)
  let first = try QueueWorkerFixture(config: firstConfig)
  let second = try QueueWorkerFixture(config: secondConfig)
  let base = try fixture.main()
  for worker in [first, second] {
    try worker.send("list", ["sessionID": "session", "requestID": "request", "offset": "0"])
  }
  let outcomes = try [first.frame(), second.frame()]
  #expect(outcomes.filter { $0["type"] as? String == "queue" }.count == 1)
  #expect(outcomes.filter { $0["type"] as? String == "blocked" }.count == 1)
  for worker in [first, second] {
    try worker.send("finish")
    #expect(try worker.frame()["type"] as? String == "final")
    worker.process.waitUntilExit()
  }
  #expect(try fixture.main() == base)
}

@Test func queueWorkerWithoutDreamRootRetainsUsefulInventoryWithoutCreatingAuthority() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let store = try MemoryStore(repo: fixture.memory, environment: [:])
  _ = try store.propose(
    base: fixture.main(), path: "MEMORY.md",
    replacement: Data(fact("Legacy pending proposal.").utf8),
    reason: "Preserve legacy pending work")
  let drafts = try MemoryDraftStore(
    repository: fixture.memory, journal: fixture.root.appendingPathComponent("journal"))
  _ = try drafts.create(operations: [
    MemoryManagementRequest(
      operation: .add, base: fixture.main(), path: "MEMORY.md",
      replacement: fact("Unfinished manual edit."), reason: "Preserve unfinished work")
  ])
  let config = try queueWorkerConfig(fixture)
  let before = try fixture.snapshot(fixture.root)
  let worker = try QueueWorkerFixture(config: config, isReviewAvailable: false)
  try worker.send("inventory")
  let inventory = try #require(worker.frame()["inventory"] as? [String: Any])
  #expect(inventory["mode"] as? String == "inventory-only")
  #expect((inventory["limitation"] as? String)?.contains("blocked migration inventory") == true)
  let artifacts = try #require(inventory["artifacts"] as? [[String: Any]])
  #expect(artifacts.contains { $0["source"] as? String == "proposal" })
  #expect(artifacts.contains { $0["source"] as? String == "journal" })
  try worker.send("approved-list")
  let approved = try #require(worker.frame()["result"] as? [String: Any])
  #expect(approved["base"] as? String == (try fixture.main()))
  #expect(approved["entries"] is [[String: Any]])
  try worker.send(
    "approved-get",
    [
      "request": [
        "operation": "get", "base": approved["base"]!, "path": "MEMORY.md",
        "locator": ["start": 0, "end": 1], "expected": "wrong bytes",
      ]
    ])
  #expect(try worker.frame()["type"] as? String == "blocked")
  try worker.send("finish")
  #expect(try worker.frame()["type"] as? String == "final")
  worker.process.waitUntilExit()
  #expect(try fixture.snapshot(fixture.root) == before)
}

@Test(arguments: ["approve", "reject", "defer"])
func queueManagementOriginalReplyRearmsOrEndsWithoutInventingAReceipt(mode: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let config = try queueWorkerConfig(fixture)
  let queue = try queueFixture(fixture, sources: sources)
  _ = try queue.list(request: MemoryQueueRequest(sessionID: "initial", requestID: "binding"))
  do {
    let review = try queue.controller()
    try review.confirmDetach(review.checkoutPreview())
  }
  queue.release()
  let worker = try QueueWorkerFixture(config: config)
  let base = try fixture.main()
  let request: [String: Any] = [
    "sessionID": "manual", "requestID": "edit", "mode": "crud",
    "request": [
      "operation": "add", "base": base, "path": "MEMORY.md",
      "replacement": fact("Conversational fixture correction."), "reason": "Explicit edit",
    ],
  ]
  try worker.send("manage-preview", request)
  let display = try #require(worker.frame()["display"] as? [String: Any])
  var tuple: [String: Any] = ["sessionID": "manual", "requestID": "edit"]
  for key in ["claimID", "sequence", "previewDigest", "displayDigest"] { tuple[key] = display[key] }
  tuple["revision"] = display["currentBase"]
  tuple["messageReference"] = "shown-memory"
  try worker.send("manage-presented", tuple, isControl: true)
  #expect(try worker.frame()["type"] as? String == "manage-presented")
  tuple.removeValue(forKey: "messageReference")
  tuple["decisionID"] = "conversational-edit"
  tuple["responseReference"] = "original-reply"
  tuple["originalText"] = "Yes"
  tuple["submittedText"] = "Yes"
  try worker.send("manage-reply", tuple, isControl: true)
  #expect(try worker.frame()["type"] as? String == "reply-clarify")
  #expect(try fixture.main() == base)
  let text =
    mode == "approve"
    ? "Save that memory"
    : mode == "reject"
      ? "Reject that memory change" : "Leave that memory for later"
  tuple["originalText"] = text
  tuple["submittedText"] = text
  try worker.send("manage-reply", tuple, isControl: true)
  let result = try worker.frame()
  if mode == "approve" {
    #expect(result["type"] as? String == "manage-decision")
    let receipt = try #require(result["receipt"] as? [String: Any])
    #expect(receipt["status"] as? String == "approved")
    #expect(receipt["commit"] as? String == (try fixture.main()))
    #expect(receipt["auditRef"] is String)
    try worker.send("manage-recover", ["decisionID": "conversational-edit"])
    #expect(try worker.frame()["receipt"] as? NSDictionary == receipt as NSDictionary)
    #expect(try fixture.main() != base)
  } else {
    #expect(result["type"] as? String == "manage-cancelled")
    #expect(result["status"] as? String == "not-saved")
    #expect(result["receipt"] == nil)
    #expect(try fixture.main() == base)
    try worker.send("manage-preview", request)
    let next = try #require(worker.frame()["display"] as? [String: Any])
    #expect(next["claimID"] as? String != display["claimID"] as? String)
  }
  try worker.send("finish")
  #expect(try worker.frame()["type"] as? String == "final")
  worker.process.waitUntilExit()
}

@Test(arguments: [
  "valid", "stdin", "legacy-choice", "changed", "stale", "no-presentation", "detach",
  "attached-approve",
])
func queueManagementRequiresExactPrivateOriginalReplyAndPreservesCheckedReceipt(mode: String) throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let config = try queueWorkerConfig(fixture)
  let queue = try queueFixture(fixture, sources: sources)
  _ = try queue.list(request: MemoryQueueRequest(sessionID: "initial", requestID: "binding"))
  if !["detach", "attached-approve"].contains(mode) {
    let review = try queue.controller()
    try review.confirmDetach(review.checkoutPreview())
  }
  queue.release()
  let worker = try QueueWorkerFixture(config: config)
  let base = try fixture.main()
  try worker.send(
    "manage-preview",
    [
      "sessionID": "manual", "requestID": "edit", "mode": "crud",
      "request": [
        "operation": "add", "base": base, "path": "MEMORY.md",
        "replacement": fact("Manual fixture correction."), "reason": "Explicit manual edit",
      ],
    ])
  let frame = try worker.frame()
  #expect(frame["type"] as? String == "manage-presentation")
  let display = try #require(frame["display"] as? [String: Any])
  let bytes = try #require(Data(base64Encoded: frame["displayBytes"] as! String))
  #expect(display["displayDigest"] as? String == SourceDigest(bytes: bytes).rawValue)
  #expect(display["documentBefore"] != nil && display["replacement"] != nil)
  var tuple: [String: Any] = ["sessionID": "manual", "requestID": "edit"]
  for key in ["claimID", "sequence", "previewDigest", "displayDigest"] { tuple[key] = display[key] }
  tuple["revision"] = display["currentBase"]
  if mode != "no-presentation" {
    var presented = tuple
    presented["messageReference"] = "exact-publication"
    try worker.send("manage-presented", presented, isControl: true)
    try #require(worker.frame()["type"] as? String == "manage-presented")
  }
  let reply = mode == "detach" ? "Detach the memory checkout" : "Save that memory"
  tuple["originalText"] = reply
  tuple["submittedText"] = reply
  tuple["decisionID"] = "manual-save"
  tuple["responseReference"] = "original-response"
  if mode == "legacy-choice" {
    tuple.removeValue(forKey: "originalText")
    tuple.removeValue(forKey: "submittedText")
    tuple["action"] = "approve"
    tuple["isInteractive"] = true
  }
  if mode == "stale" { tuple["displayDigest"] = String(repeating: "0", count: 64) }
  if mode == "changed" {
    let git = Git(repo: fixture.memory, environment: [:])
    let changed = try git.text(
      ["commit-tree", "\(base)^{tree}", "-p", base, "-m", "Synthetic intervening change"],
      additions: Git.proposalIdentity)
    _ = try git.data(["update-ref", "refs/heads/main", changed, base])
  }
  let beforeChoice = try fixture.main()
  try worker.send(
    mode == "legacy-choice" ? "manage-choice" : "manage-reply", tuple, isControl: mode != "stdin")
  let outcome = try worker.frame()
  if ["valid", "detach"].contains(mode) {
    let receipt = try #require(outcome["receipt"] as? [String: Any])
    #expect(receipt["status"] as? String == (mode == "detach" ? "detached" : "approved"))
    #expect(receipt["commit"] as? String == (try fixture.main()))
    #expect((try fixture.main() != base) == (mode == "valid"))
    try worker.send("manage-recover", ["decisionID": "manual-save"])
    #expect(try worker.frame()["receipt"] as? NSDictionary == receipt as NSDictionary)
    try worker.send("finish")
    #expect(try worker.frame()["type"] as? String == "final")
  } else {
    #expect(try fixture.main() == beforeChoice)
    if outcome["type"] as? String != "final" {
      try worker.send("finish")
      #expect(try worker.frame()["type"] as? String == "final")
    }
  }
  worker.process.waitUntilExit()
}
