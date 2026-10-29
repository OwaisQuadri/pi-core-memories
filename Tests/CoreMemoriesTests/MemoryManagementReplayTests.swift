import Foundation
import Testing

@testable import CoreMemories

@Test func directManagementReplayPreservesHistoryAndExactInsertionEffects() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let manager = try MemoryManagement(repository: fixture.repo, environment: [:])
  try manager.confirmDetach(manager.checkoutPreview())
  let initial = try manager.execute(MemoryManagementRequest(operation: .list))
  let added = try manager.execute(
    MemoryManagementRequest(
      operation: .add, base: initial.base, path: "MEMORY.md",
      replacement: fact("Keep clear headings."),
      reason: "Requested addition"))
  let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
  let entry = try #require(catalog.entries.first { $0.isMutable })
  let updated = try manager.execute(
    MemoryManagementRequest(
      operation: .update, base: catalog.base, path: entry.path, locator: entry.locator,
      expected: entry.expected, replacement: fact("Keep concise clear headings."),
      reason: "Requested correction"))
  let project = "projects/" + String(repeating: "a", count: 64) + ".md"
  let created = try manager.execute(
    MemoryManagementRequest(
      operation: .add, base: updated.commit, path: project,
      replacement: fact("Keep project notes."),
      reason: "Requested project addition"))
  let next = try manager.execute(MemoryManagementRequest(operation: .list))
  let projectEntry = try #require(next.entries.first { $0.path == project && $0.isMutable })
  let deleted = try manager.execute(
    MemoryManagementRequest(
      operation: .delete, base: next.base, path: project, locator: projectEntry.locator,
      expected: projectEntry.expected, reason: "Requested deletion"))
  let before = try fixture.humanState()
  let publications = try manager.verifiedDirectPublications()
  #expect(publications.count == 4)
  let addedCommit = try #require(added.commit)
  let add = try #require(publications[addedCommit])
  #expect(add.base == initial.base)
  let git = Git(repo: fixture.repo, environment: [:])
  let original = try git.data(["show", initial.base + ":MEMORY.md"])
  let firstDocument = try git.data(["show", added.commit! + ":MEMORY.md"])
  #expect(add.effects[0].start == original.count)
  #expect(add.effects[0].before.isEmpty)
  #expect(firstDocument.count == add.effects[0].start + add.effects[0].after.count)
  let createdCommit = try #require(created.commit)
  let creation = try #require(publications[createdCommit])
  #expect(creation.effects[0].start == 0 && creation.effects[0].end == 0)
  #expect(creation.effects[0].after.starts(with: Data("# Memory\n".utf8)))
  let deletedCommit = try #require(deleted.commit)
  #expect(publications[deletedCommit]?.effects[0].after.isEmpty == true)
  #expect(try fixture.humanState() == before)
}

@Test(arguments: [
  "schema", "origin", "before", "after", "identity", "instant", "extra", "parent", "tree", "mode",
  "digest", "symbolic", "tag",
])
func directManagementReplayRefusesAlteredNativePublications(boundary: String) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let manager = try MemoryManagement(repository: fixture.repo, environment: [:])
  try manager.confirmDetach(manager.checkoutPreview())
  let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
  let result = try manager.execute(
    MemoryManagementRequest(
      operation: .add, base: catalog.base, path: "MEMORY.md",
      replacement: fact("Keep stable notes."),
      reason: "Requested addition"))
  let commit = try #require(result.commit)
  let ref = try #require(result.auditRef)
  let git = Git(repo: fixture.repo, environment: [:])
  let title = "Core memory direct management\n\n"
  let message = try git.text(["show", "-s", "--format=%B", commit])
  var audit = try #require(
    JSONSerialization.jsonObject(
      with: Data(message.dropFirst(title.count).utf8)) as? [String: Any])
  if boundary == "symbolic" {
    _ = try git.data(["symbolic-ref", ref, "refs/heads/main"])
  } else if boundary == "tag" {
    _ = try git.data(
      ["tag", "-a", "synthetic-audit", commit, "-m", "Synthetic tag"],
      additions: Git.proposalIdentity)
    let tag = try git.text(["rev-parse", "synthetic-audit"])
    _ = try git.data(["update-ref", ref, tag, commit])
  } else if boundary == "digest" {
    _ = try git.data(["update-ref", "-d", ref, commit])
    _ = try git.data([
      "update-ref", "refs/memory-management/changes/" + String(repeating: "0", count: 64), commit,
    ])
  } else {
    switch boundary {
    case "schema": audit["schemaVersion"] = 2
    case "origin": audit["origin"] = "unsupported-origin"
    case "before": audit["before"] = "Changed before bytes"
    case "after":
      audit["after"] = (audit["after"] as! String).replacingOccurrences(
        of: "stable", with: "different")
    case "identity": audit["identity"] = UUID().uuidString
    case "instant": audit["revised"] = "2026-01-01T00:00:00Z"
    case "extra": audit["unsupportedField"] = "not native"
    default: break
    }
    let bytes = try JSONSerialization.data(
      withJSONObject: audit, options: [.sortedKeys, .withoutEscapingSlashes])
    var tree = try git.text(["rev-parse", commit + "^{tree}"])
    if boundary == "tree" {
      let extra = try fixture.store.reviewCommit(
        base: commit, path: "projects/" + String(repeating: "b", count: 64) + ".md",
        replacement: Data(("# Memory\n\n" + fact("Unrelated addition.")).utf8),
        message: Data("Synthetic extra tree\n".utf8))
      tree = try git.text(["rev-parse", extra + "^{tree}"])
    } else if boundary == "mode" {
      _ = try git.data(["read-tree", commit])
      _ = try git.data(["update-index", "--chmod=+x", "MEMORY.md"])
      tree = try git.text(["write-tree"])
    }
    let parents = boundary == "parent" ? ["-p", catalog.base, "-p", commit] : ["-p", catalog.base]
    let altered = try git.text(
      ["commit-tree", tree] + parents,
      input: Data(title.utf8) + bytes + Data([10]), additions: Git.proposalIdentity)
    _ = try git.data(["update-ref", "-d", ref, commit])
    _ = try git.data([
      "update-ref", "refs/memory-management/changes/" + SourceDigest(bytes: bytes).rawValue,
      altered,
    ])
    _ = try git.data(["update-ref", "refs/heads/main", altered, commit])
  }
  let before = try fixture.humanState()
  #expect(throws: (any Error).self) { try manager.verifiedDirectPublications() }
  #expect(try fixture.humanState() == before)
}

@Test func mixedDirectAndBatchHistoryKeepsSuggestionsPendingUntilFreshApproval() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let manager = try MemoryManagement(repository: fixture.transaction.memory, environment: [:])
  for index in 0..<3 {
    let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
    _ = try manager.execute(
      MemoryManagementRequest(
        operation: .add, base: catalog.base, path: "MEMORY.md",
        replacement: fact("Direct before batch \(index)."),
        reason: "Requested addition"))
  }
  do {
    let controller = try fixture.controller()
    let drafts = try MemoryDraftStore(
      repository: fixture.transaction.memory,
      journal: memoryBatchTestJournal(fixture.transaction.root))
    let session = try MemoryBatchSession(
      repository: fixture.transaction.memory, drafts: drafts,
      review: controller, date: ReviewFlowFixture.reviewDate)
    let candidate = try #require(session.projection.candidates.first { $0.disposition == .pending })
    try session.stage(session.presentAcceptance(candidateID: candidate.change.id))
    guard case .saved = try session.save() else {
      Issue.record("Synthetic mixed-history batch did not save")
      return
    }
  }
  for index in 0..<2 {
    let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
    _ = try manager.execute(
      MemoryManagementRequest(
        operation: .add, base: catalog.base, path: "MEMORY.md",
        replacement: fact("Direct after batch \(index)."),
        reason: "Requested addition"))
  }
  let git = Git(repo: fixture.transaction.memory, environment: [:])
  let beforeMain = try git.text(["rev-parse", "main"])
  let beforeRefs = try git.text(["for-each-ref", "--format=%(refname) %(objectname)"])
  let reopened = try fixture.controller()
  let rows = try reopened.list()
  #expect(rows.filter { $0.disposition == .approved }.count == ReviewFlowFixture.retainedCount + 1)
  #expect(rows.filter { $0.disposition == .pending }.count == ReviewFlowFixture.pendingCount - 1)
  #expect(!rows.contains { $0.disposition == .blocked })
  let pending = try #require(rows.first { $0.disposition == .pending })
  let preview = try reopened.preview(
    candidateID: pending.change.id, clockDate: ReviewFlowFixture.reviewDate)
  #expect(preview.currentBase == beforeMain)
  #expect(try git.text(["rev-parse", "main"]) == beforeMain)
  #expect(try git.text(["for-each-ref", "--format=%(refname) %(objectname)"]) == beforeRefs)
}
