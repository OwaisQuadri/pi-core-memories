import Darwin
import Foundation
import Testing

@testable import CoreMemories

func memoryBatchTestJournal(_ root: URL) throws -> URL {
  guard let resolved = realpath(root.path, nil) else { throw DreamRunError.unsafeState }
  defer { free(resolved) }
  return URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("drafts")
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
