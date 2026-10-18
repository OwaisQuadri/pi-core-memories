import Foundation
import Testing

@testable import CoreMemories

@Test func backendReproStaleHigherRevisionCannotOverwriteDurableIntent() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let drafts = try MemoryDraftStore(
    repository: fixture.repo, journal: memoryBatchTestJournal(fixture.root))
  let legacy = try drafts.create()
  let initial = try MemoryBatchSession(repository: fixture.repo, drafts: drafts, restoring: legacy)
  let shared = initial.persistenceSnapshot
  try drafts.persistBatch(shared, expectedRevision: legacy.revision)
  let first = try MemoryBatchSession(repository: fixture.repo, drafts: drafts, restoring: shared)
  let stale = try MemoryBatchSession(repository: fixture.repo, drafts: drafts, restoring: shared)
  try first.stageManual(
    MemoryManagementRequest(
      operation: .add, base: shared.baseCommit, path: "MEMORY.md",
      replacement: fact("First session durable intent."), reason: "Requested addition"))
  let durable = first.persistenceSnapshot
  try drafts.persistBatch(durable, expectedRevision: shared.revision)
  let staleID = try stale.stageManual(
    MemoryManagementRequest(
      operation: .add, base: shared.baseCommit, path: "MEMORY.md",
      replacement: fact("Second session initial intent."), reason: "Requested addition"))
  try stale.stageManual(
    MemoryManagementRequest(
      operation: .add, base: shared.baseCommit, path: "MEMORY.md",
      replacement: fact("Second session superseding intent."), reason: "Requested edit"),
    itemID: staleID)
  try #require(stale.persistenceSnapshot.revision > durable.revision)
  let currentName = "\(shared.draftID)-current.json"
  let durableBytes = try drafts.root.read(
    currentName, maximum: MemoryReviewEncoding.maximumFileBytes)
  let originalMain = try fixture.store.approvedCommit()
  #expect(throws: (any Error).self) { try drafts.persistBatch(stale.persistenceRequest) }
  var isRefused = false
  do {
    _ = try stale.save()
  } catch {
    isRefused = true
  }
  #expect(
    try drafts.root.read(currentName, maximum: MemoryReviewEncoding.maximumFileBytes)
      == durableBytes)
  #expect(try fixture.store.approvedCommit() == originalMain)
  #expect(isRefused)
}

@Test func acknowledgedOwnBackgroundPersistenceAllowsNewerIntentWithoutAdoptingForeignReceipts()
  throws
{
  let fixture = try Fixture()
  defer { fixture.clean() }
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let drafts = try MemoryDraftStore(
    repository: fixture.repo, journal: memoryBatchTestJournal(fixture.root))
  let session = try MemoryBatchSession(repository: fixture.repo, drafts: drafts)
  let initialRequest = session.persistenceRequest
  let initialReceipt = try drafts.persistBatch(initialRequest)
  #expect(try drafts.persistBatch(initialRequest).digest == initialReceipt.digest)
  let foreign = try MemoryBatchSession(
    repository: fixture.repo, drafts: drafts, restoring: initialRequest.draft)
  #expect(throws: (any Error).self) { try foreign.acknowledgePersistence(initialReceipt) }
  try session.stageManual(
    MemoryManagementRequest(
      operation: .add, base: initialRequest.draft.baseCommit, path: "MEMORY.md",
      replacement: fact("Newer local intent."), reason: "Requested addition"))
  let before = try drafts.root.read(
    "\(initialRequest.draft.draftID)-current.json", maximum: MemoryReviewEncoding.maximumFileBytes)
  #expect(throws: (any Error).self) { try session.save() }
  #expect(
    try drafts.root.read(
      "\(initialRequest.draft.draftID)-current.json", maximum: MemoryReviewEncoding.maximumFileBytes
    ) == before)
  let commands = MemoryBatchInteractionCount()
  try Git.$memoryBatchCommandObserver.withValue(
    { commands.increment() },
    operation: {
      try session.acknowledgePersistence(initialReceipt)
      try session.acknowledgePersistence(initialReceipt)
    })
  #expect(commands.count == 0)
  let nextReceipt = try drafts.persistBatch(session.persistenceRequest)
  try session.acknowledgePersistence(nextReceipt)
  #expect(throws: (any Error).self) { try session.acknowledgePersistence(initialReceipt) }
  try session.stageManual(
    MemoryManagementRequest(
      operation: .add, base: initialRequest.draft.baseCommit, path: "MEMORY.md",
      replacement: fact("Final local intent."), reason: "Requested addition"))
  guard case .saved(let receipt) = try session.save() else {
    Issue.record("acknowledged own autosave prevented final Save")
    return
  }
  let git = Git(repo: fixture.repo, environment: [:])
  let commit = try #require(receipt.commit)
  #expect(
    try git.text(["rev-list", "--count", "\(initialRequest.draft.baseCommit)..\(commit)"]) == "1")
  let document = try git.text(["show", "refs/heads/main:MEMORY.md"])
  #expect(document.contains("Newer local intent."))
  #expect(document.contains("Final local intent."))
}

@Test func installedFinalFlushFailureRemainsOwnedWhenTheSessionContinuesEditing() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let drafts = try MemoryDraftStore(
    repository: fixture.repo, journal: memoryBatchTestJournal(fixture.root))
  let session = try MemoryBatchSession(repository: fixture.repo, drafts: drafts)
  let base = session.persistenceSnapshot.baseCommit
  try session.stageManual(
    MemoryManagementRequest(
      operation: .add, base: base, path: "MEMORY.md", replacement: fact("First change."),
      reason: "Requested addition"))
  let name = "\(session.persistenceSnapshot.draftID)-current.json"
  drafts.batchPersistenceFault = { event in
    if event == .afterInstall(name) { throw DreamRunError.persistenceFailure }
  }
  #expect(throws: (any Error).self) { try session.save() }
  #expect(try fixture.store.approvedCommit() == base)
  drafts.batchPersistenceFault = nil
  try session.stageManual(
    MemoryManagementRequest(
      operation: .add, base: base, path: "MEMORY.md", replacement: fact("Second change."),
      reason: "Requested addition"))
  guard case .saved = try session.save() else {
    Issue.record("installed own intent was treated as another session's conflict")
    return
  }
}
