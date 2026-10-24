import Foundation
import Testing

@testable import CoreMemories

@Test func queueManagementManualCRUDAndConfirmReviewedUseConfiguredBatchAfterBinding() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let queue = try queueFixture(fixture, sources: sources)
  _ = try queue.list(request: MemoryQueueRequest(sessionID: "session", requestID: "binding"))
  do {
    let review = try queue.controller()
    try review.confirmDetach(review.checkoutPreview())
  }
  var config = MemoryConfiguration.defaults
  config.roots = DreamControlRoots(
    state: fixture.state.path, sessions: fixture.sessions.path, memory: fixture.memory.path,
    snippets: fixture.snippets.path, prompts: nil, globalAgents: nil)
  config.reviewState = fixture.root.appendingPathComponent("review").path
  config.journal = fixture.root.appendingPathComponent("journal").path
  config.diagnostics = fixture.root.appendingPathComponent("diagnostics").path
  let url = fixture.root.appendingPathComponent("config/config.json")
  try config.save(to: url)
  let management = MemoryQueueManagement(queue: queue, configurationURL: url, configuration: config)
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "manual")
  let add = MemoryManagementRequest(
    operation: .add, base: try fixture.main(), path: "MEMORY.md",
    replacement: fact("Explicit manual correction."), reason: "Requested correction")
  let preview = try management.preview(add, identity: request)
  try management.presented(preview, messageReference: "published")
  let receipt = try management.decide(
    preview, action: "approve", decisionID: "add", responseReference: "human")
  #expect(receipt.status == "approved")
  let identity = try #require(MemoryDocument.entries(in: preview.after).first?.identity)
  for mode in ["update", "confirm-reviewed", "delete"] {
    let list = try management.inspect(MemoryManagementRequest(operation: .list))
    let entry = try #require(list.entries.first { $0.identity == identity })
    if mode == "confirm-reviewed" { Thread.sleep(forTimeInterval: 1.1) }
    let operation: MemoryManagementRequest.Operation =
      mode == "update" ? .update : mode == "delete" ? .delete : .get
    let edit = MemoryManagementRequest(
      operation: operation, base: list.base, path: entry.path, locator: entry.locator,
      expected: entry.expected,
      replacement: mode == "update" ? fact("Corrected explicit manual fact.") : nil,
      reason: mode == "confirm-reviewed" ? nil : "Requested correction")
    let display = try management.preview(
      edit, identity: request, isConfirmReviewed: mode == "confirm-reviewed")
    #expect(display.currentBase == list.base)
    #expect(display.before == Data(entry.expected.utf8))
    #expect(display.displayDigest == SourceDigest(bytes: try display.publicationBytes()).rawValue)
    try management.presented(display, messageReference: "published")
    let saved = try management.decide(
      display, action: "approve", decisionID: mode, responseReference: "human")
    #expect(saved.status == "approved")
    #expect(saved.commit == (try fixture.main()))
    #expect(try management.recover(decisionID: mode).commit == saved.commit)
  }
}
