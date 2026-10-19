import Darwin
import Foundation
import Testing

@testable import CoreMemories

@Test func draftUpdateWithoutTrailingNewlinePreservesTheFollowingEntry() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try fixture.write("# Memory\n\n" + fact("First.") + "\n" + fact("Second."), path: "MEMORY.md")
  try fixture.commit()
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
  let entries = catalog.entries.filter(\.isMutable)
  #expect(entries.count == 2)
  let first = try #require(entries.first)
  let sibling = try #require(entries.last)
  let drafts = try MemoryDraftStore(
    repository: fixture.repo,
    journal: canonicalDraftJournal(fixture.root.appendingPathComponent("drafts")))
  let draft = try drafts.create(
    base: catalog.base,
    operations: [
      MemoryManagementRequest(
        operation: .update, base: catalog.base, path: first.path,
        locator: first.locator, expected: first.expected,
        replacement: fact("Corrected.").trimmingCharacters(in: .newlines), reason: "Requested edit")
    ])
  _ = try drafts.save(
    draftID: draft.draftID, expectedRevision: draft.revision, idempotencyKey: "boundary")
  let saved = try manager.execute(MemoryManagementRequest(operation: .list)).entries.filter(
    \.isMutable)
  #expect(saved.count == 2)
  #expect(saved.first?.expected.contains("Corrected.") == true)
  #expect(saved.last?.expected == sibling.expected)
  #expect(try fixture.store.check().isEmpty)
}

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

@Test func passiveInspectionOfMissingAndCorruptStateNeverInitializesOrRepairs() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let state = fixture.root.appendingPathComponent("absent-dream")
  #expect(try !DreamInspection.read(stateRoot: state).isPresent)
  #expect(!FileManager.default.fileExists(atPath: state.path))
  try FileManager.default.createDirectory(
    at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let marker = state.appendingPathComponent("corrupt")
  try Data("invalid".utf8).write(to: marker)
  let before = try FileManager.default.contentsOfDirectory(atPath: state.path)
  #expect(throws: (any Error).self) { try DreamInspection.read(stateRoot: state) }
  #expect(try FileManager.default.contentsOfDirectory(atPath: state.path) == before)
  #expect(try Data(contentsOf: marker) == Data("invalid".utf8))
}

private func canonicalDraftJournal(_ url: URL) throws -> URL {
  let parent = url.deletingLastPathComponent()
  guard let path = realpath(parent.path, nil) else { throw DreamRunError.unsafeState }
  defer { free(path) }
  return URL(fileURLWithPath: String(cString: path)).appendingPathComponent(url.lastPathComponent)
}

@Test func draftReceiptRejectsForgedTreeAndSymbolicOrPrefixRefs() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let drafts = try MemoryDraftStore(
    repository: fixture.repo,
    journal: canonicalDraftJournal(fixture.root.appendingPathComponent("drafts")))
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  var draft = try drafts.create()
  draft = try drafts.update(
    draftID: draft.draftID, expectedRevision: 0,
    operations: [
      MemoryManagementRequest(
        operation: .add, base: draft.baseCommit, path: "MEMORY.md",
        replacement: fact("Requested."), reason: "Explicit addition")
    ])
  let receipt = try drafts.save(
    draftID: draft.draftID, expectedRevision: draft.revision, idempotencyKey: "save")
  let raw = try fixture.git(["show", "-s", "--format=%B", receipt.commit])
  let originalTree = try fixture.git(["rev-parse", draft.baseCommit + "^{tree}"])
  let forged = try fixture.git(
    ["commit-tree", originalTree, "-p", draft.baseCommit], input: Data((raw + "\n").utf8))
  _ = try fixture.git(["update-ref", receipt.auditRef, forged])
  #expect(throws: (any Error).self) {
    try drafts.save(
      draftID: draft.draftID, expectedRevision: draft.revision, idempotencyKey: "save")
  }
  _ = try fixture.git(["update-ref", "-d", receipt.auditRef])
  _ = try fixture.git(["update-ref", receipt.auditRef + "/descendant", receipt.commit])
  #expect(throws: (any Error).self) {
    try drafts.save(
      draftID: draft.draftID, expectedRevision: draft.revision, idempotencyKey: "save")
  }
  _ = try fixture.git(["update-ref", "-d", receipt.auditRef + "/descendant"])
  _ = try fixture.git(["symbolic-ref", receipt.auditRef, "refs/heads/main"])
  #expect(throws: (any Error).self) {
    try drafts.save(
      draftID: draft.draftID, expectedRevision: draft.revision, idempotencyKey: "save")
  }
  #expect(try fixture.store.approvedCommit() == receipt.commit)
}

@Test func draftAdditionIntoEmptyDocumentPreservesPreparedEntryBytes() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try fixture.write("", path: "MEMORY.md")
  try fixture.commit()
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let drafts = try MemoryDraftStore(
    repository: fixture.repo,
    journal: canonicalDraftJournal(fixture.root.appendingPathComponent("drafts")))
  var draft = try drafts.create()
  let before = try fixture.store.reviewSnapshot(base: draft.baseCommit)
  let operation = MemoryManagementRequest(
    operation: .add, base: draft.baseCommit,
    path: "MEMORY.md", replacement: fact("Hello."), reason: "Explicit addition")
  draft = try drafts.update(draftID: draft.draftID, expectedRevision: 0, operations: [operation])
  let receipt = try drafts.save(
    draftID: draft.draftID,
    expectedRevision: draft.revision, idempotencyKey: "empty-document")
  let saved = try fixture.store.reviewSnapshot(base: receipt.commit)
  let entry = try #require(saved.reviewEntries().first?.entry)
  let prepared = try manager.prepare(
    operation, snapshot: before, date: draft.created,
    newIdentity: try #require(entry.identity))
  #expect(entry.bytes == prepared.insertion)
  #expect(saved.documents.first?.bytes == prepared.document)
}

@Test func draftRecoveryOnlyRequiresExactCurrentIntentAndApprovedPublication() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let drafts = try MemoryDraftStore(
    repository: fixture.repo,
    journal: canonicalDraftJournal(fixture.root.appendingPathComponent("drafts")))
  let legacy = try drafts.create(operations: [
    MemoryManagementRequest(
      operation: .add, base: fixture.store.approvedCommit(), path: "MEMORY.md",
      replacement: fact("Exact recovery intent."), reason: "Requested addition")
  ])
  let key = "native-save-\(legacy.revision)"
  #expect(
    try drafts.recoverSave(
      draftID: legacy.draftID, expectedRevision: legacy.revision, idempotencyKey: key) == nil)
  #expect(try fixture.store.approvedCommit() == legacy.baseCommit)
  let receipt = try drafts.save(
    draftID: legacy.draftID, expectedRevision: legacy.revision, idempotencyKey: key)
  #expect(
    try drafts.recoverSave(
      draftID: legacy.draftID, expectedRevision: legacy.revision, idempotencyKey: key)?.commit
      == receipt.commit)
  _ = try fixture.git(["update-ref", "refs/heads/main", legacy.baseCommit, receipt.commit])
  #expect(throws: (any Error).self) {
    try drafts.recoverSave(
      draftID: legacy.draftID, expectedRevision: legacy.revision, idempotencyKey: key)
  }
  _ = try fixture.git(["update-ref", "refs/heads/main", receipt.commit, legacy.baseCommit])
  _ = try fixture.git(["update-ref", "-d", receipt.auditRef])
  _ = try fixture.git(["update-ref", receipt.auditRef + "/descendant", receipt.commit])
  #expect(throws: (any Error).self) {
    try drafts.recoverSave(
      draftID: legacy.draftID, expectedRevision: legacy.revision, idempotencyKey: key)
  }
  _ = try fixture.git(["update-ref", "-d", receipt.auditRef + "/descendant"])
  _ = try fixture.git(["update-ref", receipt.auditRef, receipt.commit])
  _ = try drafts.update(draftID: legacy.draftID, expectedRevision: legacy.revision, operations: [])
  #expect(throws: (any Error).self) {
    try drafts.recoverSave(
      draftID: legacy.draftID, expectedRevision: legacy.revision, idempotencyKey: key)
  }
  #expect(try fixture.store.approvedCommit() == receipt.commit)
}
