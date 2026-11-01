import Darwin
import Foundation
import Testing

@testable import CoreMemories

@Test func draftSavePublishesOneCommitAcrossDocumentsAndRecoversLostReceipt() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let path = "projects/" + String(repeating: "a", count: 64) + ".md"
  try fixture.write("# Memory\n\n" + fact("First."), path: "MEMORY.md")
  try fixture.write("# Memory\n\n" + fact("Second."), path: path)
  try fixture.commit()
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
  let journal = fixture.root.appendingPathComponent("drafts")
  let drafts = try MemoryDraftStore(
    repository: fixture.repo, journal: canonicalDraftJournal(journal))
  var draft = try drafts.create()
  let operations = catalog.entries.filter(\.isMutable).map { row in
    MemoryManagementRequest(
      operation: .update, base: catalog.base, path: row.path, locator: row.locator,
      expected: row.expected, replacement: fact("Corrected \(row.path)."),
      reason: "Requested correction")
  }
  draft = try drafts.update(draftID: draft.draftID, expectedRevision: 0, operations: operations)
  drafts.afterPublication = { throw DreamRunError.persistenceFailure }
  #expect(throws: (any Error).self) {
    try drafts.save(
      draftID: draft.draftID, expectedRevision: draft.revision, idempotencyKey: "save")
  }
  let committed = try fixture.store.approvedCommit()
  #expect(try fixture.git(["rev-parse", "main^"]) == catalog.base)
  #expect(
    try fixture.git(["diff-tree", "--no-commit-id", "--name-only", "-r", "main"]).split(
      separator: "\n"
    ).count == 2)
  let recovered = try MemoryDraftStore(
    repository: fixture.repo, journal: canonicalDraftJournal(journal))
  let receipt = try recovered.save(
    draftID: draft.draftID, expectedRevision: draft.revision, idempotencyKey: "save")
  #expect(receipt.commit == committed)
  #expect(try fixture.git(["rev-parse", receipt.auditRef]) == committed)
  #expect(
    try recovered.save(
      draftID: draft.draftID, expectedRevision: draft.revision, idempotencyKey: "save"
    ).commit == committed)
  #expect(try fixture.store.check().isEmpty)
  #expect(
    try recovered.update(
      draftID: draft.draftID,
      expectedRevision: draft.revision, operations: operations
    ).revision == draft.revision)
  #expect(
    try recovered.save(
      draftID: draft.draftID,
      expectedRevision: draft.revision, idempotencyKey: "save"
    ).commit == committed)
  let next = try manager.execute(MemoryManagementRequest(operation: .list)).entries.filter(
    \.isMutable)
  #expect(
    next.allSatisfy { $0.expected.contains("[source: docs/owner.md#rule; added: 2024-02-29]") })
  #expect(next.allSatisfy { $0.identity != nil && $0.reviewed == nil })
}

@Test func draftRejectsStaleRevisionsSourcesDuplicateTargetsAndBasesWithoutPublishing() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try fixture.write("# Memory\n\n" + fact("Original."), path: "MEMORY.md")
  try fixture.commit()
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
  let row = try #require(catalog.entries.first(where: { $0.isMutable }))
  let drafts = try MemoryDraftStore(
    repository: fixture.repo,
    journal: canonicalDraftJournal(fixture.root.appendingPathComponent("drafts")))
  var draft = try drafts.create()
  var operation = MemoryManagementRequest(
    operation: .update, base: catalog.base, path: row.path, locator: row.locator,
    expected: row.expected, replacement: "Unsourced.\n", reason: "Correction")
  draft = try drafts.update(draftID: draft.draftID, expectedRevision: 0, operations: [operation])
  #expect(throws: (any Error).self) {
    try drafts.update(draftID: draft.draftID, expectedRevision: 0, operations: [])
  }
  #expect(throws: (any Error).self) {
    try drafts.save(draftID: draft.draftID, expectedRevision: draft.revision, idempotencyKey: "bad")
  }
  #expect(try fixture.store.approvedCommit() == catalog.base)
  operation.replacement = fact("Corrected.")
  draft = try drafts.update(
    draftID: draft.draftID, expectedRevision: draft.revision, operations: [operation, operation])
  #expect(throws: (any Error).self) {
    try drafts.save(
      draftID: draft.draftID, expectedRevision: draft.revision, idempotencyKey: "overlap")
  }
  #expect(try fixture.store.approvedCommit() == catalog.base)
  _ = try manager.execute(operation)
  draft = try drafts.update(
    draftID: draft.draftID, expectedRevision: draft.revision, operations: [operation])
  let before = try fixture.store.approvedCommit()
  #expect(throws: (any Error).self) {
    try drafts.save(
      draftID: draft.draftID, expectedRevision: draft.revision, idempotencyKey: "stale")
  }
  #expect(try fixture.store.approvedCommit() == before)
}

private func canonicalDraftJournal(_ url: URL) throws -> URL {
  let parent = url.deletingLastPathComponent()
  guard let path = realpath(parent.path, nil) else { throw DreamRunError.unsafeState }
  defer { free(path) }
  return URL(fileURLWithPath: String(cString: path)).appendingPathComponent(url.lastPathComponent)
}
