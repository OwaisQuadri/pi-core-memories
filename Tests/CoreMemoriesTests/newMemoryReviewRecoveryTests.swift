import Darwin
import Foundation
import Testing

@testable import CoreMemories

@Test(arguments: [MemoryReviewPersistenceEvent.beforePublication, .afterPublication])
func reviewCrashRecoveryUsesExactAuditNotAttemptOrCurrentMain(event: MemoryReviewPersistenceEvent)
  throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let state = fixture.root.appendingPathComponent("review")
  var controller: MemoryReviewController? = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  let rows = try controller!.list()
  let update = rows.first { $0.change.operation == .update }!
  let add = rows.first { $0.change.operation == .add }!
  try controller!.confirmDetach(controller!.checkoutPreview())
  let preview = try controller!.preview(
    candidateID: update.change.id, clockDate: Date(timeIntervalSince1970: 1_783_036_799))
  let original = try fixture.main()
  let git = Git(repo: fixture.memory, environment: [:])
  controller!.persistenceFault = { observed in
    if observed == event {
      if event == .afterPublication {
        let parent = try fixture.main()
        let tree = try git.text(["rev-parse", "\(parent)^{tree}"])
        let next = try git.text(
          ["commit-tree", tree, "-p", parent], input: Data("Synthetic external advance\n".utf8),
          additions: Git.proposalIdentity)
        _ = try git.data(["update-ref", "refs/heads/main", next, parent])
      }
      throw MemoryError("synthetic process interruption")
    }
  }
  #expect(throws: (any Error).self) { try controller!.apply(preview) }
  let mainAfterFailure = try fixture.main()
  #expect((mainAfterFailure == original) == (event == .beforePublication))
  controller = nil
  let reopened = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: fixture.store(), environment: [:])
  let recovered = try reopened.list()
  #expect(
    recovered.first { $0.change.id == update.change.id }?.disposition
      == (event == .afterPublication ? .approved : .pending))
  #expect(try fixture.main() == mainAfterFailure)
  #expect(throws: (any Error).self) { try reopened.apply(preview) }
  if event == .afterPublication {
    #expect(recovered.first { $0.change.id == add.change.id }?.disposition == .blocked)
    try FileManager.default.removeItem(
      at: state.appendingPathComponent("outcome-\(update.change.id.rawValue).json"))
    #expect(
      try reopened.list().first { $0.change.id == update.change.id }?.disposition == .approved)
  } else {
    #expect(recovered.first { $0.change.id == add.change.id }?.disposition == .pending)
  }
}

@Test(arguments: [MemoryReviewPersistenceEvent.beforeDetach, .afterDetach])
func reviewDetachInterruptionNeverApprovesAnEntry(event: MemoryReviewPersistenceEvent) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let state = fixture.root.appendingPathComponent("review")
  var controller: MemoryReviewController? = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  _ = try controller!.list()
  let preview = try controller!.checkoutPreview()
  let main = try fixture.main()
  controller!.persistenceFault = { observed in
    if observed == event { throw MemoryError("synthetic detach interruption") }
  }
  #expect(throws: (any Error).self) { try controller!.confirmDetach(preview) }
  controller = nil
  let reopened = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: fixture.store(), environment: [:])
  #expect(try reopened.list().allSatisfy { $0.disposition == .pending })
  #expect(try fixture.main() == main)
  #expect(try reopened.checkoutPreview().isDetachRequired == (event == .beforeDetach))
}
