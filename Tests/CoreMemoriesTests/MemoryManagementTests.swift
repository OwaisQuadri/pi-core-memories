import Foundation
import Testing

@testable import CoreMemories

private func managementTarget(
  _ operation: MemoryManagementRequest.Operation, catalog: MemoryManagementResult,
  row: ManagedMemoryEntry, replacement: String? = nil
) -> MemoryManagementRequest {
  MemoryManagementRequest(
    operation: operation, base: catalog.base, path: row.path, locator: row.locator,
    expected: row.expected, replacement: replacement,
    reason: operation == .get ? nil : "Explicit requested correction")
}

@Test func managementExactDuplicateTargetPreservesSourcesIdentityReviewAndHumanCheckout() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let paragraph = fact("Keep café 🐟.")
  try fixture.write("# Memory\n\n" + paragraph + "\n" + paragraph, path: "MEMORY.md")
  try fixture.commit()
  let manager = try MemoryManagement(repository: fixture.repo)
  let preview = try manager.checkoutPreview()
  let attached = try fixture.humanState()
  let initial = try manager.execute(MemoryManagementRequest(operation: .list))
  #expect(initial.entries.first?.isMutable == false)
  let row = initial.entries.filter(\.isMutable)[1]
  let request = managementTarget(
    .update, catalog: initial, row: row, replacement: fact("Only second café 🐟."))
  #expect(throws: (any Error).self) { try manager.execute(request) }
  #expect(try fixture.humanState() == attached)
  try manager.confirmDetach(preview)
  var before = try fixture.humanState()
  before.removeValue(forKey: "main")
  let result = try manager.execute(request, date: Date(timeIntervalSince1970: 1_783_036_799))
  #expect(result.message.contains("new session"))
  #expect(try fixture.store.approvedCommit() == result.commit)
  #expect(try fixture.git(["rev-parse", result.auditRef!]) == result.commit)
  let commit = try fixture.git(["show", "-s", "--format=%B", result.commit!])
  #expect(commit.contains("Core memory direct management"))
  #expect(commit.contains("explicit-user-request-agent-rule"))
  #expect(!commit.contains("Core memory native review"))
  #expect(try fixture.git(["for-each-ref", "--format=%(refname)", "refs/memory-review"]).isEmpty)
  let next = try manager.execute(MemoryManagementRequest(operation: .list))
  let nextRows = next.entries.filter(\.isMutable)
  #expect(nextRows.count == 2)
  #expect(nextRows[0].expected == initial.entries.filter(\.isMutable)[0].expected)
  #expect(nextRows[1].reviewed == nil)
  #expect(nextRows[1].revised != nil && nextRows[1].identity != nil)
  #expect(nextRows[1].expected.contains("[source: docs/owner.md#rule; added: 2024-02-29]"))
  var after = try fixture.humanState()
  after.removeValue(forKey: "main")
  #expect(after == before)
  #expect(throws: (any Error).self) { try manager.execute(request) }
  #expect(throws: (any Error).self) {
    try manager.execute(
      managementTarget(
        .update, catalog: next, row: nextRows[1],
        replacement: "Other. [source: new; added: 2026-01-01]\n"))
  }
  let update = try manager.execute(
    managementTarget(.update, catalog: next, row: nextRows[1], replacement: fact("Again.")))
  let updated = try manager.execute(MemoryManagementRequest(operation: .list))
  let updatedRow = updated.entries.filter(\.isMutable)[1]
  #expect(updatedRow.identity == nextRows[1].identity)
  #expect(updated.base == update.commit)
  let fetched = try manager.execute(managementTarget(.get, catalog: updated, row: updatedRow))
  #expect(fetched.entries[0].expected == updatedRow.expected)
  _ = try manager.execute(managementTarget(.delete, catalog: updated, row: updatedRow))
  let final = try manager.execute(MemoryManagementRequest(operation: .list)).entries.filter(
    \.isMutable)
  #expect(final.count == 1 && final[0].expected == paragraph)
}

@Test func managementAddAbsentProjectAndDeleteKeepOtherDocumentsAndReviewDate() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let identity = UUID()
  let reviewed = try MemoryDocument.ReviewInstant("2026-01-01T00:00:00Z")
  let old = try MemoryDocument.reviewedBytes(
    Data(fact("Old.").utf8), identity: identity, instant: reviewed)
  try fixture.write("# Memory\n\n" + String(decoding: old, as: UTF8.self), path: "MEMORY.md")
  try fixture.commit()
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
  _ = try manager.execute(
    managementTarget(
      .update, catalog: catalog, row: catalog.entries.filter(\.isMutable)[0],
      replacement: fact("New.")))
  let next = try manager.execute(MemoryManagementRequest(operation: .list))
  #expect(next.entries.filter(\.isMutable)[0].reviewed == reviewed.rawValue)
  #expect(next.entries.filter(\.isMutable)[0].identity == identity)
  let global = try fixture.git(["show", "main:MEMORY.md"])
  let path = "projects/" + String(repeating: "a", count: 64) + ".md"
  _ = try manager.execute(
    MemoryManagementRequest(
      operation: .add, base: next.base, path: path, replacement: fact("Project."),
      reason: "Requested project memory"))
  #expect(try fixture.git(["show", "main:MEMORY.md"]) == global)
  let added = try manager.execute(MemoryManagementRequest(operation: .list))
  let addedRows = added.entries.filter(\.isMutable)
  #expect(addedRows.count == 2)
  #expect(addedRows[1].path == path && addedRows[1].reviewed == nil)
  _ = try manager.execute(managementTarget(.delete, catalog: added, row: addedRows[1]))
  #expect(try fixture.git(["show", "main:MEMORY.md"]) == global)
  #expect(try fixture.store.check().isEmpty)
}

@Test func managementRefusesCrossDocumentDuplicateIdentityAndGuessedBytes() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let identity = UUID()
  let bytes = try MemoryDocument.reviewedBytes(
    Data(fact("Café.").utf8), identity: identity,
    instant: MemoryDocument.ReviewInstant("2026-01-01T00:00:00Z"))
  for path in ["MEMORY.md", "projects/" + String(repeating: "b", count: 64) + ".md"] {
    try fixture.write("# Memory\n\n" + String(decoding: bytes, as: UTF8.self), path: path)
  }
  try fixture.commit()
  let manager = try MemoryManagement(repository: fixture.repo)
  let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
  #expect(catalog.entries.allSatisfy { !$0.isMutable })
  let duplicate = try #require(catalog.entries.first { $0.identity == identity })
  let before = try fixture.humanState()
  #expect(throws: (any Error).self) {
    try manager.execute(managementTarget(.delete, catalog: catalog, row: duplicate))
  }
  var guessed = managementTarget(.get, catalog: catalog, row: duplicate)
  guessed.expected = fact("Shared.")
  #expect(throws: (any Error).self) { try manager.execute(guessed) }
  var canonical = managementTarget(.get, catalog: catalog, row: duplicate)
  canonical.expected = duplicate.expected.replacingOccurrences(of: "Café.", with: "Cafe\u{301}.")
  #expect(canonical.expected == duplicate.expected)
  #expect(throws: (any Error).self) { try manager.execute(canonical) }
  #expect(try fixture.humanState() == before)
}

@Test func managementPreparationDeclineStaleAndDirtyLeaveCheckoutUnchanged() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let manager = try MemoryManagement(repository: fixture.repo)
  let before = try fixture.humanState()
  let preview = try manager.checkoutPreview()
  #expect(preview.isDetachRequired)
  #expect(try fixture.humanState() == before)
  try fixture.write("dirty", path: "MEMORY.md")
  let dirty = try fixture.humanState()
  #expect(throws: (any Error).self) { try manager.checkoutPreview() }
  #expect(throws: (any Error).self) { try manager.confirmDetach(preview) }
  #expect(try fixture.humanState() == dirty)
  try fixture.write("# Memory\n", path: "MEMORY.md")
  try manager.confirmDetach(manager.checkoutPreview())
  var detached = try fixture.humanState()
  detached[".git/HEAD"] = before[".git/HEAD"]
  #expect(detached == before)
  #expect(throws: (any Error).self) { try manager.confirmDetach(preview) }
}

@Test(arguments: ["projects", "bytes"])
func managementRefusesUnreadableProposedCatalogWithoutChangingMainOrAudit(boundary: String) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let count = boundary == "projects" ? 64 : 4
  for index in 0..<count {
    let key = String(format: "%064x", index)
    let text =
      boundary == "projects" ? "# Memory\n" : String(repeating: "x", count: 1_048_570) + "\n"
    try fixture.write(text, path: "projects/\(key).md")
  }
  try fixture.write("# Memory\n\n" + fact("Old."), path: "MEMORY.md")
  if boundary == "bytes" {
    let key = String(format: "%064x", 0)
    try fixture.write(String(repeating: "x", count: 1_048_000) + "\n", path: "projects/\(key).md")
  }
  try fixture.commit()
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
  let before = try fixture.humanState()
  let audit = try fixture.git([
    "for-each-ref", "--format=%(refname) %(objectname)", "refs/memory-management",
  ])
  let request =
    boundary == "projects"
    ? MemoryManagementRequest(
      operation: .add, base: catalog.base, path: "projects/" + String(format: "%064x", 64) + ".md",
      replacement: fact("New project."), reason: "Requested addition")
    : managementTarget(
      .update, catalog: catalog, row: catalog.entries.first { $0.isMutable }!,
      replacement: fact(String(repeating: "y", count: 1024)))
  #expect(throws: (any Error).self) { try manager.execute(request) }
  #expect(try fixture.humanState() == before)
  #expect(
    try fixture.git(["for-each-ref", "--format=%(refname) %(objectname)", "refs/memory-management"])
      == audit)
  #expect(try manager.execute(MemoryManagementRequest(operation: .list)).base == catalog.base)
}

@Test func managementExecutableClosedProtocolAndNativePreparationCannotApproveOnStdin() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let list = try fixture.cli(
    ["manage", "--repo", fixture.repo.path], input: Data("{\"operation\":\"list\"}".utf8))
  #expect(list.status == 0)
  let catalog = try JSONDecoder().decode(MemoryManagementResult.self, from: list.output)
  #expect(catalog.entries.filter(\.isMutable).isEmpty)
  #expect(catalog.entries.first?.expected == "# Memory\n")
  for request in [
    "{\"operation\":\"approve\"}",
    "{\"operation\":\"list\",\"candidateID\":\"anything\"}",
    "{\"operation\":\"add\",\"base\":\"main\"}",
  ] {
    #expect(
      try fixture.cli(["manage", "--repo", fixture.repo.path], input: Data(request.utf8)).status
        != 0)
  }
  for args in [["memory-prepare-worker"], ["memory-prepare-worker", "--approve"]] {
    #expect(try fixture.cli(args, input: Data("{\"action\":\"detach\"}\n".utf8)).status != 0)
  }
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let request = MemoryManagementRequest(
    operation: .add, base: catalog.base, path: "MEMORY.md", replacement: fact("CLI entry."),
    reason: "Requested addition")
  let result = try fixture.cli(
    ["manage", "--repo", fixture.repo.path], input: JSONEncoder().encode(request))
  #expect(result.status == 0)
  let receipt = try JSONDecoder().decode(MemoryManagementResult.self, from: result.output)
  #expect(receipt.commit == (try fixture.store.approvedCommit()))
}
