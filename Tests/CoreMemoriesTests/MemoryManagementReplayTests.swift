import Foundation
import Testing

@testable import CoreMemories

@Test func mixedDirectAndBatchHistoryKeepsSuggestionsPendingUntilFreshApproval() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let manager = try MemoryManagement(repository: fixture.transaction.memory, environment: [:])
  for index in 0..<3 {
    let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
    _ = try manager.execute(
      MemoryManagementRequest(
        operation: .add, base: catalog.base, path: "MEMORY.md",
        replacement: fact("Direct before batch \(index)."),
        reason: "Requested addition"))
  }
  do {
    let controller = try fixture.controller()
    let drafts = try MemoryDraftStore(
      repository: fixture.transaction.memory,
      journal: memoryBatchTestJournal(fixture.transaction.root))
    let session = try MemoryBatchSession(
      repository: fixture.transaction.memory, drafts: drafts,
      review: controller, date: ReviewFlowFixture.reviewDate)
    let candidate = try #require(session.projection.candidates.first { $0.disposition == .pending })
    try session.stage(session.presentAcceptance(candidateID: candidate.change.id))
    guard case .saved = try session.save() else {
      Issue.record("Synthetic mixed-history batch did not save")
      return
    }
  }
  for index in 0..<2 {
    let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
    _ = try manager.execute(
      MemoryManagementRequest(
        operation: .add, base: catalog.base, path: "MEMORY.md",
        replacement: fact("Direct after batch \(index)."),
        reason: "Requested addition"))
  }
  let git = Git(repo: fixture.transaction.memory, environment: [:])
  let beforeMain = try git.text(["rev-parse", "main"])
  let beforeRefs = try git.text(["for-each-ref", "--format=%(refname) %(objectname)"])
  let reopened = try fixture.controller()
  let rows = try reopened.list()
  #expect(rows.filter { $0.disposition == .approved }.count == ReviewFlowFixture.retainedCount + 1)
  #expect(rows.filter { $0.disposition == .pending }.count == ReviewFlowFixture.pendingCount - 1)
  #expect(!rows.contains { $0.disposition == .blocked })
  let pending = try #require(rows.first { $0.disposition == .pending })
  let preview = try reopened.preview(
    candidateID: pending.change.id, clockDate: ReviewFlowFixture.reviewDate)
  #expect(preview.currentBase == beforeMain)
  #expect(try git.text(["rev-parse", "main"]) == beforeMain)
  #expect(try git.text(["for-each-ref", "--format=%(refname) %(objectname)"]) == beforeRefs)
}
