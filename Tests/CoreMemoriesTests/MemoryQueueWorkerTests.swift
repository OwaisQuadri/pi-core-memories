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
    try #require(ready["type"] as? String == "ready")
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

@Test(arguments: ["missing-dream", "corrupt-review", "unavailable-queue", "busy-review", "unavailable-journal"])
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
    try fixture.write("invalid review", file: URL(fileURLWithPath: configuration.reviewState + "/root.json"))
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
  let worker = try QueueWorkerFixture(config: config, isReviewAvailable: failure != "missing-dream")
  try worker.send("approved-list")
  #expect(try worker.frame()["type"] as? String == "approved")
  let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
  try worker.send("approved-get", ["request": object])
  #expect(try worker.frame()["type"] as? String == "approved")
  let change = MemoryManagementRequest(
    operation: .add, base: catalog.base, path: "MEMORY.md",
    replacement: "Direct memory. [source: explicit user request; added: 2026-01-01]\n",
    reason: "Explicit requested addition")
  try worker.send("manage-preview", [
    "sessionID": "session", "requestID": "request", "mode": "crud",
    "request": try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)),
  ])
  #expect(try worker.frame()["type"] as? String == "manage-presentation")
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
