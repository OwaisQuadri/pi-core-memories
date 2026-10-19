import Foundation
import Testing

@testable import CoreMemories

final class MemoryBatchInteractionCount: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func increment() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}

@Test func preparedCandidateSelectionStageAmendmentAndUndoPerformZeroGitOrHistoryWork() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    date: ReviewFlowFixture.reviewDate)
  let candidate = try #require(session.projection.candidates.first { $0.disposition == .pending })
  let before = try fixture.preservedFiles()
  let commands = MemoryBatchInteractionCount()
  var historyRefreshes = 0
  var journalEvents = 0
  controller.batchHistoryObserver = { historyRefreshes += 1 }
  drafts.batchPersistenceFault = { _ in journalEvents += 1 }
  try Git.$memoryBatchCommandObserver.withValue({ commands.increment() }) {
    let original = try session.presentAcceptance(candidateID: candidate.change.id)
    session.select(original.itemID)
    try session.stage(original)
    try session.remove(original.itemID)
    try session.undo()
    let editable = try MemoryDocument.editableEntry(candidate.change.after)
    let amended = try session.prepareAmendment(
      candidateID: candidate.change.id,
      amendment: MemoryBatchAmendment(
        replacement: editable.replacingOccurrences(of: "Synthetic", with: "Amended"),
        reason: "Requested correction"))
    try session.stage(amended)
    try session.stageDecision(candidateID: candidate.change.id, choice: .deferCandidate)
    try session.undo()
    #expect(session.projection.draft.batch?.items.count == 1)
  }
  #expect(commands.count == 0)
  #expect(historyRefreshes == 0)
  #expect(journalEvents == 0)
  #expect(try fixture.preservedFiles() == before)
  #expect(
    try MemoryStore(repo: fixture.transaction.memory).approvedCommit()
      == session.persistenceSnapshot.baseCommit)
}

@Test func boundedPreparedWindowsKeepPendingCandidatesAheadOfRetainedHistory() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let first = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    date: ReviewFlowFixture.reviewDate, catalogLimit: 2)
  let next = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    date: ReviewFlowFixture.reviewDate, catalogLimit: 2, catalogOffset: 2)
  #expect(first.projection.candidates.count == 2)
  #expect(next.projection.candidates.count == 2)
  #expect(first.projection.candidateCount == 12)
  #expect(first.projection.entryCount == 4)
  #expect(first.projection.entries.count == 2)
  #expect(first.projection.candidates.allSatisfy { $0.disposition == .pending })
  #expect(
    Set(first.projection.candidates.map { $0.change.id.rawValue }).isDisjoint(
      with: next.projection.candidates.map { $0.change.id.rawValue }))
}

@Test func journalPersistenceDoesNotOwnPreparedInteractionOrAcknowledgeNewerIntent() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let journal = try memoryBatchTestJournal(fixture.root)
  let drafts = try MemoryDraftStore(repository: fixture.repo, journal: journal)
  let initial = try drafts.create()
  let session = try MemoryBatchSession(repository: fixture.repo, drafts: drafts, restoring: initial)
  let snapshot = session.persistenceSnapshot
  var interactions = 0
  drafts.batchPersistenceFault = { event in
    if event == .beforeFileSync("\(snapshot.draftID)-current.json") {
      let id = try session.stageManual(
        MemoryManagementRequest(
          operation: .add, base: snapshot.baseCommit, path: "MEMORY.md",
          replacement: fact("Later intent."), reason: "Requested addition"))
      session.select(id)
      try session.remove(id)
      try session.undo()
      interactions += 1
    }
  }
  try drafts.persistBatch(snapshot, expectedRevision: initial.revision)
  #expect(interactions == 1)
  #expect(session.persistenceSnapshot.revision > snapshot.revision)
  let durable = try #require(try drafts.list().first)
  #expect(durable.revision == snapshot.revision)
  #expect(durable.batch?.items.isEmpty == true)
  #expect(session.persistenceSnapshot.batch?.items.count == 1)
}
