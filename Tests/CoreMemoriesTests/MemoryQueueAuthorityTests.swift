import Foundation
import Testing

@testable import CoreMemories

@Test func queueBindingFencesAbsentAndForeignPublicationButPermitsMatchingManualReview() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let queue = try queueFixture(fixture, sources: sources)
  _ = try queue.list(request: MemoryQueueRequest(sessionID: "session", requestID: "request"))
  let review = try queue.controller()
  try review.confirmDetach(review.checkoutPreview())
  let drafts = try MemoryDraftStore(
    repository: fixture.memory, journal: fixture.root.appendingPathComponent("journal"))
  let batch = try MemoryBatchSession(
    repository: fixture.memory, drafts: drafts, review: review, allowedPaths: ["MEMORY.md"])
  _ = try batch.stageManual(
    MemoryManagementRequest(
      operation: .add, base: batch.projection.draft.baseCommit, path: "MEMORY.md",
      replacement: fact("Requested synthetic correction."), reason: "Explicit fixture edit"))
  guard case .saved = try batch.save() else {
    Issue.record("matching-profile manual review did not publish")
    return
  }
  let store = review.store
  let base = try fixture.main()
  let checkout = try store.reviewGit.reviewCheckout().witness()
  let before = try store.reviewGit.text(["for-each-ref", "--format=%(refname)%00%(objectname)"])
  #expect(throws: (any Error).self) {
    try store.publishCheckedMemoryCommit(
      commit: base, base: base, auditRef: "refs/memory-review/absent-fixture", checkout: checkout)
  }
  let other = try TransactionFixture()
  defer { other.clean() }
  let otherSources = try reviewCompletedSiblings(other)
  let otherReview = try MemoryReviewController(
    repository: other.memory, stateRoot: other.root.appendingPathComponent("review"),
    sources: otherSources, environment: [:])
  #expect(throws: (any Error).self) {
    try store.publishCheckedMemoryCommit(
      commit: base, base: base, auditRef: "refs/memory-review/foreign-fixture", checkout: checkout,
      reviewBinding: otherReview.binding)
  }
  #expect(
    try store.reviewGit.text(["for-each-ref", "--format=%(refname)%00%(objectname)"]) == before)
  #expect(try fixture.main() == base)
}

@Test func queueBindingRejectsSecondReviewProfileAndReplacedQueueRootWithoutDeletingState() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let queue = try queueFixture(fixture, sources: sources)
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  _ = try queue.list(request: request)
  #expect(throws: (any Error).self) {
    try MemoryReviewController(
      repository: fixture.memory,
      stateRoot: fixture.root.appendingPathComponent("different-review"),
      sources: sources, environment: [:])
  }
  let original = fixture.root.appendingPathComponent("review.queue")
  let retained = fixture.root.appendingPathComponent("retained-queue")
  let bytes = try fixture.snapshot(original).values.map(\.bytes).sorted {
    $0.lexicographicallyPrecedes($1)
  }
  try FileManager.default.moveItem(at: original, to: retained)
  let replacement = try queueFixture(fixture, sources: sources)
  #expect(throws: (any Error).self) { try replacement.list(request: request) }
  #expect(
    try fixture.snapshot(retained).values.map(\.bytes).sorted { $0.lexicographicallyPrecedes($1) }
      == bytes)
  #expect(throws: (any Error).self) { try queue.list(request: request) }
}
