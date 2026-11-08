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

  init(config: URL) throws {
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
    try #require(ready["type"] as? String == "ready")
    #expect(ready["isReviewAvailable"] as? Bool == false)
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
          "queue frame missing: poll=\(readiness), errno=\(failureCode), events=\(descriptor.revents), bytes=\(bytes.count), helper=\(helper)"
        )
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

  func change(_ request: MemoryManagementRequest) throws -> [String: Any] {
    for attempt in 0..<2 {
      try send(
        "manage-preview",
        [
          "sessionID": "session", "requestID": UUID().uuidString, "mode": "crud",
          "request": try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)),
        ])
      let preview = try frame()
      try #require(
        preview["type"] as? String == "manage-presentation", "attempt \(attempt): \(preview)")
      let display = try #require(preview["display"] as? [String: Any])
      let identity = try #require(display["request"] as? [String: Any])
      var tuple: [String: Any] = [
        "claimID": display["claimID"]!, "sequence": display["sequence"]!,
        "revision": display["currentBase"]!, "previewDigest": display["previewDigest"]!,
        "displayDigest": display["displayDigest"]!, "sessionID": identity["sessionID"]!,
        "requestID": identity["requestID"]!, "messageReference": "message",
      ]
      try send("manage-presented", tuple, isControl: true)
      try #require(frame()["type"] as? String == "manage-presented")
      tuple.removeValue(forKey: "messageReference")
      let decisionID = UUID().uuidString
      let approval =
        display["isDetachRequired"] as? Bool == true
        ? "Detach the memory checkout" : "Approve this memory change"
      tuple["originalText"] = approval
      tuple["submittedText"] = approval
      tuple["decisionID"] = decisionID
      tuple["responseReference"] = "later-human-message"
      try send("manage-reply", tuple, isControl: true)
      let outcome = try frame()
      try #require(outcome["type"] as? String == "manage-decision")
      let receipt = try #require(outcome["receipt"] as? [String: Any])
      try send("manage-recover", ["decisionID": decisionID])
      #expect(try frame()["receipt"] as? NSDictionary == receipt as NSDictionary)
      if display["isDetachRequired"] as? Bool == true {
        #expect(attempt == 0)
        #expect(receipt["status"] as? String == "detached")
      } else {
        try #require(receipt["status"] as? String == "approved")
        return receipt
      }
    }
    throw MemoryError("direct change did not publish after checkout preparation")
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

@Test(arguments: [
  "missing-dream", "corrupt-review", "unavailable-queue", "busy-review", "unavailable-journal",
])
func queueWorkerApprovedStorageDoesNotRequireHealthyReview(failure: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let config = try queueWorkerConfig(fixture)
  let configuration = try MemoryConfiguration.load(from: config)
  do {
    let queue = try MemoryQueue(
      sources: sources, reviewState: URL(fileURLWithPath: configuration.reviewState),
      journal: URL(fileURLWithPath: configuration.journal), environment: [:])
    _ = try queue.list(request: MemoryQueueRequest(sessionID: "setup", requestID: "setup"))
  }
  var owner: MemoryReviewController?
  switch failure {
  case "missing-dream": try FileManager.default.removeItem(at: fixture.state)
  case "corrupt-review":
    try fixture.write(
      "invalid review", file: URL(fileURLWithPath: configuration.reviewState + "/root.json"))
  case "unavailable-queue":
    let root = URL(fileURLWithPath: configuration.reviewState + ".queue")
    try FileManager.default.removeItem(at: root)
    try fixture.write("unavailable queue", file: root)
  case "busy-review":
    owner = try MemoryReviewController(
      repository: fixture.memory, stateRoot: URL(fileURLWithPath: configuration.reviewState),
      sources: sources, environment: [:])
  default:
    try fixture.write("unavailable journal", file: URL(fileURLWithPath: configuration.journal))
  }
  defer { withExtendedLifetime(owner) {} }
  let manager = try MemoryManagement(repository: fixture.memory)
  let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
  let entry = try #require(catalog.entries.first { $0.isMutable })
  let request = MemoryManagementRequest(
    operation: .get, base: catalog.base, path: entry.path, locator: entry.locator,
    expected: entry.expected)
  #expect(try manager.execute(request).entries.first?.expected == entry.expected)
  #expect(try MemoryStore(repo: fixture.memory).render(cwd: fixture.root).contains(entry.expected))
  let worker = try QueueWorkerFixture(config: config)
  try worker.send("approved-list")
  #expect(try worker.frame()["type"] as? String == "approved")
  let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
  try worker.send("approved-get", ["request": object])
  #expect(try worker.frame()["type"] as? String == "approved")
  let change = MemoryManagementRequest(
    operation: .add, base: catalog.base, path: "MEMORY.md",
    replacement: "Direct memory. [source: explicit user request; added: 2026-01-01]\n",
    reason: "Explicit requested addition")
  let direct = MemoryQueueManagement(
    configurationURL: config, configuration: configuration)
  _ = try direct.preview(change, identity: MemoryQueueRequest(sessionID: "core", requestID: "core"))
  direct.release()
  let receipt = try worker.change(change)
  #expect(receipt["commit"] as? String == (try fixture.main()))
  let restarted = try QueueWorkerFixture(config: config)
  try restarted.send("manage-recover", ["decisionID": receipt["decisionID"]!])
  #expect(try restarted.frame()["receipt"] as? NSDictionary == receipt as NSDictionary)
  if failure == "missing-dream" {
    let journal = fixture.memory.deletingLastPathComponent()
      .appendingPathComponent(fixture.memory.lastPathComponent + ".management")
    let current = try DreamStateDirectory.openRoot(journal)
    let name = "management-\(try #require(receipt["decisionID"] as? String)).json"
    let queue = try DreamStateDirectory.openRoot(
      URL(fileURLWithPath: configuration.reviewState + ".queue"))
    try queue.installReviewFile(
      current.read(name, maximum: MemoryReviewEncoding.maximumFileBytes), name: name)
    try FileManager.default.removeItem(at: journal.appendingPathComponent(name))
    var legacyConfiguration = configuration
    legacyConfiguration.journal = journal.path
    try legacyConfiguration.save(to: config)
    let legacyWorker = try QueueWorkerFixture(config: config)
    try legacyWorker.send("manage-recover", ["decisionID": receipt["decisionID"]!])
    #expect(try legacyWorker.frame()["receipt"] as? NSDictionary == receipt as NSDictionary)
  }
  let added = try manager.execute(MemoryManagementRequest(operation: .list))
  let newEntry = try #require(added.entries.first { $0.expected.contains("Direct memory.") })
  let update = MemoryManagementRequest(
    operation: .update, base: added.base, path: newEntry.path, locator: newEntry.locator,
    expected: newEntry.expected,
    replacement: "Updated memory. [source: explicit user request; added: 2026-01-01]\n",
    reason: "Explicit requested update")
  _ = try worker.change(update)
  let updated = try manager.execute(MemoryManagementRequest(operation: .list))
  let updatedEntry = try #require(updated.entries.first { $0.expected.contains("Updated memory.") })
  _ = try worker.change(
    MemoryManagementRequest(
      operation: .delete, base: updated.base, path: updatedEntry.path,
      locator: updatedEntry.locator,
      expected: updatedEntry.expected, reason: "Explicit requested deletion"))
  let remaining = try manager.execute(MemoryManagementRequest(operation: .list))
  #expect(!remaining.entries.contains { $0.expected.contains("Updated memory.") })
}

@Test
func directMemoryChangeRejectsRetargetedConfiguration() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let config = try queueWorkerConfig(fixture)
  var configuration = try MemoryConfiguration.load(from: config)
  let direct = MemoryQueueManagement(configurationURL: config, configuration: configuration)
  let request = MemoryManagementRequest(
    operation: .add, base: try fixture.main(), path: "MEMORY.md",
    replacement: "Direct memory. [source: explicit user request; added: 2026-01-01]\n",
    reason: "Explicit requested addition")
  let identity = try MemoryQueueRequest(sessionID: "core", requestID: "core")
  let detach = try direct.preview(request, identity: identity)
  try direct.presented(detach, messageReference: "display-detach")
  #expect(
    try direct.decide(
      detach, action: "detach", decisionID: "detach", responseReference: "reply-detach"
    ).status == "detached")
  let display = try direct.preview(request, identity: identity)
  try direct.presented(display, messageReference: "display")
  configuration.roots?.memory = fixture.root.appendingPathComponent("another-memory").path
  try configuration.save(to: config)
  #expect(throws: DreamRunError.unsafeState) {
    try direct.decide(display, action: "approve", decisionID: "approve", responseReference: "reply")
  }
  #expect(try fixture.main() == request.base)
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

@Test(arguments: ["valid", "missing-audit", "namespace", "schema", "witness", "attempt"])
func legacyDetachRecoveryRequiresHistoricalProof(failure: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let config = try queueWorkerConfig(fixture)
  let configuration = try MemoryConfiguration.load(from: config)
  let management = MemoryQueueManagement(configurationURL: config, configuration: configuration)
  let display = try management.preview(
    MemoryManagementRequest(
      operation: .add, base: try fixture.main(), path: "MEMORY.md",
      replacement: "Direct memory. [source: explicit user request; added: 2026-01-01]\n",
      reason: "Explicit requested addition"),
    identity: MemoryQueueRequest(sessionID: "legacy", requestID: "legacy"))
  try management.presented(display, messageReference: "display")
  #expect(
    try management.decide(
      display, action: "detach", decisionID: "legacy", responseReference: "later-reply"
    ).status == "detached")
  let journal = fixture.memory.deletingLastPathComponent()
    .appendingPathComponent(fixture.memory.lastPathComponent + ".management")
  let current = try DreamStateDirectory.openRoot(journal)
  let queue = try DreamStateDirectory.openRoot(
    URL(fileURLWithPath: configuration.reviewState + ".queue"))
  try queue.installReviewFile(
    current.read("management-legacy.json", maximum: MemoryReviewEncoding.maximumFileBytes),
    name: "management-legacy.json")
  try FileManager.default.removeItem(at: journal.appendingPathComponent("management-legacy.json"))
  let root = try DreamStateDirectory.openRoot(URL(fileURLWithPath: configuration.reviewState))
  let original = try MemoryReviewEncoding.decode(
    ReviewDetachAttempt.self,
    bytes: current.read(
      "detach-attempt-\(display.checkoutDigest).json",
      maximum: MemoryReviewEncoding.maximumFileBytes))
  let historical = ReviewDetachAttempt(
    schemaVersion: 1, witness: original.witness, digest: original.digest,
    auditRef: "refs/memory-review/detach/\(original.digest)")
  let git = try MemoryStore(repo: fixture.memory).reviewGit
  #expect(
    try git.directRefTransaction(
      "create \(historical.auditRef) \(historical.witness.commit)\n",
      refs: [historical.auditRef], isolatedHead: historical.witness.commit
    ).status == 0)
  var outcome = try #require(
    JSONSerialization.jsonObject(with: MemoryReviewEncoding.encode(historical)) as? [String: Any])
  switch failure {
  case "missing-audit":
    #expect(
      try git.directRefTransaction(
        "delete \(historical.auditRef) \(historical.witness.commit)\n",
        refs: [historical.auditRef], isolatedHead: historical.witness.commit
      ).status == 0)
  case "namespace": outcome["auditRef"] = original.auditRef
  case "schema": outcome["schemaVersion"] = 2
  case "witness":
    var witness = try #require(outcome["witness"] as? [String: Any])
    witness["main"] = String(repeating: "0", count: 40)
    outcome["witness"] = witness
  default: break
  }
  let outcomeBytes = try JSONSerialization.data(
    withJSONObject: outcome, options: [.sortedKeys, .withoutEscapingSlashes])
  try root.installReviewFile(outcomeBytes, name: "detach-outcome-\(original.digest).json")
  try root.installReviewFile(
    failure == "attempt" ? MemoryReviewEncoding.encode(original) : outcomeBytes,
    name: "detach-attempt-\(original.digest).json")
  if failure == "valid" {
    #expect(try management.recover(decisionID: "legacy").status == "detached")
  } else {
    #expect(throws: DreamRunError.corruption) { try management.recover(decisionID: "legacy") }
  }
  #expect(try fixture.main() == display.currentBase)
}

@Test func queueWorkerBlockedPreviewReportsSafeStageWithoutPublishing() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  do {
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: sources, environment: [:])
    try review.confirmDetach(review.checkoutPreview())
  }
  let catalog = try MemoryManagement(repository: fixture.memory).execute(
    MemoryManagementRequest(operation: .list))
  let entry = try #require(catalog.entries.first)
  let request = MemoryManagementRequest(
    operation: .delete, base: String(repeating: "0", count: 40), path: entry.path,
    locator: entry.locator, expected: entry.expected, reason: "Private diagnostic test reason")
  let worker = try QueueWorkerFixture(config: queueWorkerConfig(fixture))
  let original = try fixture.main()
  try worker.send(
    "manage-preview",
    [
      "sessionID": "session", "requestID": "request", "mode": "crud",
      "request": JSONSerialization.jsonObject(with: JSONEncoder().encode(request)),
    ])
  let outcome = try worker.frame()
  #expect(outcome["type"] as? String == "blocked")
  #expect(outcome["code"] as? String == "blocked")
  #expect(outcome["reason"] as? String == "MemoryError")
  #expect(outcome["operation"] as? String == "manage-preview")
  #expect(outcome["stage"] as? String == "manualRequest")
  let text = String(decoding: try JSONSerialization.data(withJSONObject: outcome), as: UTF8.self)
  #expect(!text.contains(fixture.root.path))
  #expect(!text.contains(entry.expected))
  #expect(!text.contains("Private diagnostic test reason"))
  #expect(try fixture.main() == original)
  try worker.send(
    "manage-preview",
    [
      "sessionID": "session", "requestID": "request", "mode": "crud",
      "request": ["operation": "delete"],
    ])
  let invalid = try worker.frame()
  #expect(invalid["type"] as? String == "blocked")
  #expect(invalid["operation"] as? String == "manage-preview")
  #expect(invalid["stage"] == nil)
  #expect(try fixture.main() == original)
  try worker.send("finish")
  #expect(try worker.frame()["type"] as? String == "final")
  worker.process.waitUntilExit()
}
