import Darwin
import Foundation
import Testing

@testable import CoreMemories

@Test func deviceRenderAndAtomicDraftNeverIncludeAnotherDevice() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let device = String(repeating: "a", count: 64)
  let other = String(repeating: "b", count: 64)
  let project = try #require(try MemoryStore.projectKey(cwd: fixture.memory))
  let paths = [
    "MEMORY.md", "projects/\(project).md", "devices/\(device)/MEMORY.md",
    "devices/\(device)/projects/\(project).md", "devices/\(other)/MEMORY.md",
  ]
  for (index, path) in paths.enumerated() {
    try fixture.write(
      "# Memory\n\n" + fact("Scope \(index)."), file: fixture.memory.appendingPathComponent(path))
  }
  let git = Git(repo: fixture.memory, environment: [:])
  _ = try git.text(["add", "."])
  _ = try git.text(["commit", "-m", "Synthetic scopes"], additions: Git.proposalIdentity)
  let store = try MemoryStore(repo: fixture.memory)
  let rendered = try store.render(cwd: fixture.memory, deviceKey: device)
  let positions = try (0..<4).map { index in
    try #require(rendered.range(of: "Scope \(index).")).lowerBound
  }
  #expect(positions == positions.sorted())
  #expect(!rendered.contains("Scope 4."))
  #expect(!(try store.render(cwd: fixture.memory)).contains("Scope 2."))
  let manager = try MemoryManagement(repository: fixture.memory)
  try manager.confirmDetach(manager.checkoutPreview())
  let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
  let drafts = try MemoryDraftStore(
    repository: fixture.memory, journal: fixture.root.appendingPathComponent("drafts"))
  var draft = try drafts.create()
  draft = try drafts.update(
    draftID: draft.draftID, expectedRevision: 0,
    operations: catalog.entries.filter(\.isMutable).map { row in
      MemoryManagementRequest(
        operation: .update, base: catalog.base, path: row.path, locator: row.locator,
        expected: row.expected, replacement: fact("Changed \(row.path)."),
        reason: "Explicit scoped correction")
    })
  let receipt = try drafts.save(
    draftID: draft.draftID, expectedRevision: draft.revision, idempotencyKey: "save")
  #expect(try git.text(["rev-parse", receipt.commit + "^"]) == catalog.base)
  #expect(try store.check().isEmpty)
}
