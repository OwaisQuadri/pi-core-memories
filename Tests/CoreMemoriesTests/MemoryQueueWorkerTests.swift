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
