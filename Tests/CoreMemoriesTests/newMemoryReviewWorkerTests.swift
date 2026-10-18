import Darwin
import Foundation
import Testing
import XCTest

@testable import CoreMemories
@testable import PiCoreMemories

final class MemoryReviewWorkerProcessHelper: XCTestCase {
  func testPartialMutationWorkerHelper() throws {
    guard let mode = ProcessInfo.processInfo.environment["MEMORY_REVIEW_WORKER_FAILURE"] else {
      return
    }
    guard dup2(STDERR_FILENO, 3) == 3 else { throw MemoryError("missing test control pipe") }
    let null = open("/dev/null", O_WRONLY)
    guard null >= 0, dup2(null, STDERR_FILENO) == STDERR_FILENO else {
      throw MemoryError("cannot isolate test diagnostics")
    }
    _ = close(null)
    let result = executeMemoryReviewWorker(arguments: ["memory-review-worker"]) { controller in
      guard mode != "after-batch" else { return }
      controller.persistenceFault = { event in
        if case .beforeWrite(let name) = event,
          name.hasPrefix(mode == "approve" ? "outcome-" : "detach-outcome-")
        {
          throw MemoryError("persistent outcome write failure")
        }
      }
    }
    _exit(result)
  }
}

@Test(arguments: ["approve", "detach", "after-batch"])
func reviewWorkerPreservesOneItemApprovalAndReportsIrreversibleFollowUpFailures(mode: String)
  throws
{
  let batchFixture = try mode == "after-batch" ? ReviewFlowFixture() : nil
  let fixture = try batchFixture?.transaction ?? TransactionFixture()
  defer { fixture.clean() }
  let sources = try batchFixture?.sources ?? reviewCompletedSiblings(fixture)
  if let batchFixture {
    let controller = try batchFixture.controller()
    let drafts = try MemoryDraftStore(
      repository: fixture.memory, journal: memoryBatchTestJournal(fixture.root))
    let session = try MemoryBatchSession(
      repository: fixture.memory, drafts: drafts, review: controller,
      date: ReviewFlowFixture.reviewDate)
    for candidate in session.projection.candidates.filter({ $0.disposition == .pending }).prefix(2)
    {
      try session.stage(session.presentAcceptance(candidateID: candidate.change.id))
    }
    _ = try session.stageManual(
      MemoryManagementRequest(
        operation: .add, base: session.projection.draft.baseCommit, path: "MEMORY.md",
        replacement: fact("Manual sibling in a batch."), reason: "Requested addition"))
    guard case .saved = try session.save() else {
      throw MemoryError("synthetic mixed batch did not publish")
    }
  }
  if mode == "approve" {
    let controller = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: sources, environment: [:])
    _ = try controller.list()
    try controller.confirmDetach(controller.checkoutPreview())
  }
  let input = Pipe()
  let output = Pipe()
  let control = Pipe()
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  process.arguments = [
    "xctest", "-XCTest",
    "CoreMemoriesTests.MemoryReviewWorkerProcessHelper/testPartialMutationWorkerHelper",
    Bundle(for: MemoryReviewWorkerProcessHelper.self).bundleURL.path,
  ]
  process.environment = ["PATH": "/usr/bin:/bin", "MEMORY_REVIEW_WORKER_FAILURE": mode]
  process.standardInput = input
  process.standardOutput = output
  process.standardError = control.fileHandleForReading
  try process.run()
  defer {
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
  try input.fileHandleForReading.close()
  try output.fileHandleForWriting.close()
  try control.fileHandleForReading.close()
  func send(_ object: [String: Any], isControl: Bool = false) throws {
    let bytes = try JSONSerialization.data(withJSONObject: object) + Data([10])
    try (isControl ? control : input).fileHandleForWriting.write(contentsOf: bytes)
  }
  func frame() throws -> [String: Any] {
    var bytes = Data()
    while bytes.count < 8 * 1_048_576 {
      var descriptor = pollfd(
        fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
      guard poll(&descriptor, 1, 20_000) == 1,
        let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty
      else { throw MemoryError("partial worker frame missing") }
      if byte == Data([10]) {
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      }
      bytes.append(byte)
    }
    throw MemoryError("partial worker frame too large")
  }
  let invocation = "partial-worker"
  try send([
    "version": 1, "type": "start", "invocationID": invocation,
    "roots": [
      "state": fixture.state.path, "sessions": fixture.sessions.path,
      "memory": fixture.memory.path, "snippets": fixture.snippets.path,
      "prompts": NSNull(), "globalAgents": NSNull(),
    ], "reviewState": fixture.root.appendingPathComponent("review").path,
  ])
  let queue = try frame()
  #expect(queue["type"] as? String == "queue")
  let rows = try #require(queue["candidates"] as? [[String: Any]])
  let pending = try #require(rows.first { $0["disposition"] as? String == "pending" })
  let id = try #require(pending["candidateID"] as? String)
  let beforeMain = try fixture.main()
  try send(["version": 1, "type": "preview", "invocationID": invocation, "candidateID": id])
  let preview = try frame()
  #expect(preview["type"] as? String == "preview")
  try send(
    [
      "version": 1, "type": "choice", "invocationID": invocation, "candidateID": id,
      "sequence": preview["sequence"]!, "digest": preview["digest"]!,
      "action": mode == "after-batch" ? "approve" : mode,
    ], isControl: true)
  let operation = try frame()
  #expect(operation["type"] as? String == "operation")
  #expect(operation["status"] as? String == (mode == "detach" ? "detached" : "approved"))
  let commit = try #require(operation["commit"] as? String)
  let git = Git(repo: fixture.memory, environment: [:])
  #expect(commit == (mode == "detach" ? try git.text(["rev-parse", "HEAD"]) : try fixture.main()))
  if mode != "detach" {
    let audit = try #require(operation["auditRef"] as? String)
    #expect(try git.text(["rev-parse", audit]) == commit)
  } else {
    #expect((operation["auditRef"] as? String)?.hasPrefix("refs/memory-review/detach/") == true)
  }
  if mode == "after-batch" {
    #expect(operation["reason"] is NSNull)
    #expect(try git.text(["rev-list", "--count", beforeMain + ".." + commit]) == "1")
    let refreshed = try frame()
    #expect(refreshed["type"] as? String == "queue")
    let refreshedRows = try #require(refreshed["candidates"] as? [[String: Any]])
    #expect(refreshedRows.filter { $0["disposition"] as? String == "approved" }.count == 7)
    #expect(refreshedRows.filter { $0["disposition"] as? String == "pending" }.count == 5)
    try send(["version": 1, "type": "finish", "invocationID": invocation])
  } else {
    #expect(
      (operation["reason"] as? String)?.contains("follow-up persistence or recovery is incomplete")
        == true)
  }
  let final = try frame()
  #expect(final["type"] as? String == "final")
  #expect(final["status"] as? String == (mode == "after-batch" ? "completed" : "failed"))
  process.waitUntilExit()
  #expect(process.terminationStatus == (mode == "after-batch" ? 0 : 1))
}

@Test func reviewWorkerWithoutInheritedControlChannelCannotPublish() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Keep A.", "Keep B."])
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let before = try fixture.snapshot(fixture.memory)
  let worker = try DreamWorkerProcess(arguments: ["memory-review-worker"])
  defer { worker.clean() }
  let final = try worker.frame()
  #expect(final["type"] as? String == "final")
  #expect(final["status"] as? String == "failed")
  try worker.finish(status: 1)
  #expect(try fixture.snapshot(fixture.memory) == before)
}

@Test func reviewWorkerApprovalArgumentsAreNotACommandSurface() throws {
  let worker = try DreamWorkerProcess(arguments: ["memory-review-worker", "approve"])
  defer { worker.clean() }
  let final = try worker.frame()
  #expect(final["status"] as? String == "failed")
  try worker.finish(status: 1)
}
