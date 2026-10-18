import Foundation
import Testing

@testable import CoreMemories

@Test(arguments: [
  "before-write", "file-sync", "install", "after-install", "directory-sync", "before-publication",
  "after-publication", "receipt",
])
func batchInterruptionNeverPartiallyPublishesAndRecoversExactHistoricalReceipt(boundary: String)
  throws
{
  let fixture = try Fixture()
  defer { fixture.clean() }
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let drafts = try MemoryDraftStore(
    repository: fixture.repo, journal: memoryBatchTestJournal(fixture.root))
  let session = try MemoryBatchSession(repository: fixture.repo, drafts: drafts)
  try session.stageManual(
    MemoryManagementRequest(
      operation: .add, base: session.persistenceSnapshot.baseCommit, path: "MEMORY.md",
      replacement: fact("Requested addition."), reason: "Requested addition"))
  let draft = session.persistenceSnapshot
  let saveID = try memoryBatchDigest(draft)
  let name = "batch-attempt-\(saveID).json"
  let event: MemoryReviewPersistenceEvent
  switch boundary {
  case "before-write": event = .beforeWrite(name)
  case "file-sync": event = .beforeFileSync(name)
  case "install": event = .beforeInstall(name)
  case "after-install": event = .afterInstall(name)
  case "directory-sync": event = .afterDirectorySync(name)
  case "before-publication": event = .beforePublication
  case "after-publication": event = .afterPublication
  default: event = .beforeWrite("batch-receipt-\(saveID).json")
  }
  drafts.batchPersistenceFault = { observed in
    if observed == event { throw MemoryError("synthetic interruption") }
  }
  let isPublished = boundary == "after-publication" || boundary == "receipt"
  if isPublished {
    guard case .savedNeedsRecovery(let receipt, _) = try session.save() else {
      Issue.record("published Save lost its known outcome")
      return
    }
    #expect(receipt.saveID == saveID)
  } else {
    #expect(throws: (any Error).self) { try session.save() }
  }
  drafts.batchPersistenceFault = nil
  let main = try fixture.store.approvedCommit()
  #expect((main != draft.baseCommit) == isPublished)
  if isPublished {
    let tree = try fixture.git(["rev-parse", main + "^{tree}"])
    let later = try fixture.git(
      ["commit-tree", tree, "-p", main], input: Data("Synthetic later advance\n".utf8))
    _ = try fixture.git(["update-ref", "refs/heads/main", later, main])
    guard
      case .saved(let receipt) = try drafts.recoverBatch(
        draftID: draft.draftID, revision: draft.revision)
    else {
      Issue.record("historical receipt was not recovered")
      return
    }
    #expect(receipt.commit == main)
    #expect(try fixture.store.approvedCommit() == later)
    #expect(try drafts.list().isEmpty)
  } else {
    #expect(try drafts.recoverBatch(draftID: draft.draftID, revision: draft.revision) == nil)
    #expect(try fixture.store.approvedCommit() == draft.baseCommit)
    guard case .saved = try session.save() else {
      Issue.record("explicit live retry did not save")
      return
    }
  }
}

@Test func restoredBatchAcceptanceCannotPublishAnUnpublishedSavedAttempt() throws {
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
  let presentation = try session.presentAcceptance(candidateID: candidate.change.id)
  try session.stage(presentation)
  drafts.batchPersistenceFault = {
    if $0 == .beforePublication { throw MemoryError("interrupted before publication") }
  }
  #expect(throws: (any Error).self) { try session.save() }
  drafts.batchPersistenceFault = nil
  let restored = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    restoring: session.persistenceSnapshot, date: ReviewFlowFixture.reviewDate)
  #expect(restored.projection.needsReview == [presentation.itemID])
  #expect(
    try drafts.recoverBatch(
      draftID: session.persistenceSnapshot.draftID, revision: session.persistenceSnapshot.revision,
      review: controller) == nil)
  #expect(throws: (any Error).self) { try restored.save() }
  #expect(throws: (any Error).self) { try restored.stage(presentation) }
  try restored.stage(restored.presentAcceptance(candidateID: candidate.change.id))
  guard case .saved = try restored.save() else {
    Issue.record("fresh explicit acceptance did not save")
    return
  }
}

@Test func changedAmendmentInvalidatesStagedAuthorityAndPreservesExactRequiredSources() throws {
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
  let original = try session.presentAcceptance(candidateID: candidate.change.id)
  try session.stage(original)
  #expect(throws: (any Error).self) {
    try session.prepareAmendment(
      candidateID: candidate.change.id,
      amendment: MemoryBatchAmendment(
        replacement: fact("Lost required source."), reason: "Requested correction"))
  }
  let editable = try MemoryDocument.editableEntry(candidate.change.after)
  let amended = try session.prepareAmendment(
    candidateID: candidate.change.id,
    amendment: MemoryBatchAmendment(
      replacement: editable.replacingOccurrences(of: "Synthetic", with: "Amended"),
      reason: "Requested correction"))
  #expect(session.projection.needsReview == [original.itemID])
  #expect(throws: (any Error).self) { try session.stage(original) }
  #expect(throws: (any Error).self) { try session.save() }
  try session.stage(amended)
  guard case .saved(let receipt) = try session.save() else {
    Issue.record("amendment was not saved")
    return
  }
  let manifest = try MemoryBatchReplay.read(
    try #require(receipt.commit), git: Git(repo: fixture.transaction.memory, environment: [:]))
  #expect(manifest.effects.first?.originalReviewedProposal == original.after)
  #expect(manifest.effects.first?.after == amended.after)
  #expect(
    MemoryDocument.sourceAnnotations(in: original.after).allSatisfy(
      MemoryDocument.sourceAnnotations(in: amended.after).contains))
}
