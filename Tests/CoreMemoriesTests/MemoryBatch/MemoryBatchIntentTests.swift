import Darwin
import Foundation
import Testing

@testable import CoreMemories

func memoryBatchTestJournal(_ root: URL) throws -> URL {
  guard let resolved = realpath(root.path, nil) else { throw DreamRunError.unsafeState }
  defer { free(resolved) }
  return URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("drafts")
}

@Test func batchAdoptionPreservesLegacyDraftIdentityAndRejectsCRUDOverwrite() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let manager = try MemoryManagement(repository: fixture.repo)
  let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
  let drafts = try MemoryDraftStore(
    repository: fixture.repo, journal: memoryBatchTestJournal(fixture.root))
  let legacy = try drafts.create(operations: [
    MemoryManagementRequest(
      operation: .add, base: catalog.base, path: "MEMORY.md", replacement: fact("Requested."),
      reason: "Requested addition")
  ])
  let session = try MemoryBatchSession(repository: fixture.repo, drafts: drafts, restoring: legacy)
  let adopted = session.persistenceSnapshot
  #expect(adopted.draftID == legacy.draftID)
  #expect(adopted.created == legacy.created)
  #expect(adopted.baseCommit == legacy.baseCommit)
  let item = try #require(adopted.batch?.items.first)
  guard case .manual(let manual) = item.intent else {
    Issue.record("lost CRUD origin")
    return
  }
  #expect(manual.identity == memoryBatchIdentity("\(legacy.draftID):0"))
  try drafts.persistBatch(adopted, expectedRevision: legacy.revision)
  let durable = try drafts.list()
  let restored = try #require(durable.first)
  let reopened = try MemoryBatchSession(
    repository: fixture.repo, drafts: drafts, restoring: restored)
  #expect(try memoryBatchDigest(reopened.persistenceSnapshot) == memoryBatchDigest(adopted))
  #expect(throws: (any Error).self) {
    try drafts.update(draftID: adopted.draftID, expectedRevision: adopted.revision, operations: [])
  }
  #expect(throws: (any Error).self) {
    try drafts.save(
      draftID: adopted.draftID, expectedRevision: adopted.revision, idempotencyKey: "crud")
  }
  #expect(try fixture.store.approvedCommit() == legacy.baseCommit)
}

@Test func batchRestoreNeverRestoresConfirmReviewedAuthority() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try fixture.write("# Memory\n\n" + fact("Original."), path: "MEMORY.md")
  try fixture.commit()
  let drafts = try MemoryDraftStore(
    repository: fixture.repo, journal: memoryBatchTestJournal(fixture.root))
  let legacy = try drafts.create()
  let session = try MemoryBatchSession(repository: fixture.repo, drafts: drafts, restoring: legacy)
  let entry = try #require(session.projection.entries.first(where: { $0.isMutable }))
  let presentation = try session.presentConfirmReviewed(entry)
  try session.stage(presentation)
  #expect(session.projection.needsReview.isEmpty)
  let intent = session.persistenceSnapshot
  try drafts.persistBatch(intent, expectedRevision: legacy.revision)
  let restored = try MemoryBatchSession(repository: fixture.repo, drafts: drafts, restoring: intent)
  #expect(restored.projection.needsReview == [presentation.itemID])
  #expect(throws: (any Error).self) { try restored.stage(presentation) }
  try restored.stage(restored.presentConfirmReviewed(entry))
  #expect(restored.projection.needsReview.isEmpty)
}

@Test func preparedBatchStageSelectionRemoveAndUndoDoNotWritePersistentState() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try fixture.write("# Memory\n\n" + fact("Original."), path: "MEMORY.md")
  try fixture.commit()
  let drafts = try MemoryDraftStore(
    repository: fixture.repo, journal: memoryBatchTestJournal(fixture.root))
  let session = try MemoryBatchSession(repository: fixture.repo, drafts: drafts)
  let row = try #require(session.projection.entries.first(where: { $0.isMutable }))
  let original = session.persistenceSnapshot
  let before = try FileManager.default.contentsOfDirectory(
    atPath: fixture.root.appendingPathComponent("drafts").path)
  let id = try session.stageManual(
    MemoryManagementRequest(
      operation: .update, base: original.baseCommit, path: row.path, locator: row.locator,
      expected: row.expected, replacement: fact("Corrected."), reason: "Requested correction"))
  session.select(id)
  #expect(session.projection.selectedItemID == id)
  try session.remove(id)
  #expect(session.projection.draft.batch?.items.isEmpty == true)
  try session.undo()
  #expect(session.projection.draft.batch?.items.count == 1)
  #expect(try fixture.store.approvedCommit() == original.baseCommit)
  #expect(try drafts.list().first?.schemaVersion == 1)
  #expect(
    try FileManager.default.contentsOfDirectory(
      atPath: fixture.root.appendingPathComponent("drafts").path) == before)
}
