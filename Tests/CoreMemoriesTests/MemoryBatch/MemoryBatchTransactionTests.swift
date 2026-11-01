import Foundation
import Testing

@testable import CoreMemories

extension TransactionFixture {
  fileprivate func memoryStore() throws -> MemoryStore {
    try MemoryStore(repo: memory, environment: [:])
  }
}

@Test func mixedBatchPublishesOneCommitAndMakesAllDecisionsEffectiveTogether() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    configurationURL: fixture.configurationURL,
    date: ReviewFlowFixture.reviewDate.addingTimeInterval(1))
  let candidates = session.projection.candidates.filter { $0.disposition == .pending }
  let first = try session.presentAcceptance(candidateID: candidates[0].change.id)
  try session.stage(first)
  let amendment = MemoryBatchAmendment(
    replacement: try MemoryDocument.editableEntry(candidates[1].change.after).replacingOccurrences(
      of: "Synthetic", with: "Corrected synthetic"),
    reason: "Requested correction")
  let second = try session.presentAcceptance(
    candidateID: candidates[1].change.id, amendment: amendment)
  try session.stage(second)
  try session.stageDecision(candidateID: candidates[2].change.id, choice: .reject)
  try session.stageDecision(candidateID: candidates[3].change.id, choice: .deferCandidate)
  let entries = session.projection.entries.filter(\.isMutable)
  let existing = entries[0]
  let editable = try MemoryDocument.editableEntry(Data(existing.expected.utf8))
  try session.stageManual(
    MemoryManagementRequest(
      operation: .update, base: session.persistenceSnapshot.baseCommit, path: existing.path,
      locator: existing.locator, expected: existing.expected,
      replacement: editable.replacingOccurrences(of: "Synthetic", with: "Manually revised"),
      reason: "Requested edit"))
  try session.stage(session.presentConfirmReviewed(entries[1]))
  let base = session.persistenceSnapshot.baseCommit
  #expect(try controller.list().filter { $0.disposition == .approved }.count == 4)
  let saved = try session.save()
  guard case .saved(let receipt) = saved else {
    Issue.record("mixed batch was not saved")
    return
  }
  let commit = try #require(receipt.commit)
  #expect(try fixture.transaction.memoryStore().approvedCommit() == commit)
  let git = Git(repo: fixture.transaction.memory, environment: [:])
  #expect(try git.text(["rev-parse", "\(commit)^"]) == base)
  #expect(try git.text(["rev-parse", try #require(receipt.auditRef)]) == commit)
  let snapshot = try fixture.transaction.memoryStore().reviewSnapshot(base: commit)
  #expect(snapshot.reviewEntries().contains { $0.entry.bytes == first.after })
  #expect(snapshot.reviewEntries().contains { $0.entry.bytes == second.after })
  let rows = try controller.list()
  #expect(rows.filter { $0.disposition == .approved }.count == 6)
  #expect(rows.first { $0.change.id == candidates[2].change.id }?.disposition == .rejected)
  #expect(rows.first { $0.change.id == candidates[3].change.id }?.disposition == .deferred)
  #expect(rows.filter { $0.disposition == .pending }.count == 4)
  #expect(throws: MemoryBatchRecoveryRequired.self) { try drafts.list() }
  #expect(try drafts.list(review: controller).isEmpty)
  guard case .saved(let replayed) = try session.save() else {
    Issue.record("receipt recovery failed")
    return
  }
  #expect(replayed.commit == commit)
}
