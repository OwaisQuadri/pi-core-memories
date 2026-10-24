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
      guard poll(&descriptor, 1, 10_000) == 1,
        let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty
      else { throw MemoryError("queue frame missing") }
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

@Test(arguments: ["valid", "stdin", "stale", "generated"])
func queueWorkerOnlyExactPrivateInteractiveChoiceReturnsReceipt(mode: String) throws {
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
  tuple["action"] = "approve"
  tuple["decisionID"] = "save-1"
  tuple["responseReference"] = "human-response"
  tuple["isInteractive"] = mode != "generated"
  if mode == "stale" { tuple["requestID"] = "foreign-request" }
  try worker.send("choice", tuple, isControl: mode != "stdin")
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
  try worker.send("finish")
  #expect(try worker.frame()["type"] as? String == "final")
  worker.process.waitUntilExit()
  #expect(try fixture.snapshot(fixture.root) == before)
}
