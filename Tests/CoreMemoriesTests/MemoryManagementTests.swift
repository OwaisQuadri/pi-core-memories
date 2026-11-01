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
