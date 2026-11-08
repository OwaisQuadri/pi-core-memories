import Foundation
import Testing

@testable import CoreMemories

@Test func legacyEntryReviewUsesCommittedLocationForIdenticalEntriesWithoutIdentities() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try fixture.write(
    "# Memory\n\n" + fact("Same preference.") + "\n\n" + fact("Same preference."), path: "MEMORY.md"
  )
  try fixture.commit()
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let base = try fixture.store.approvedCommit()
  let snapshot = try fixture.store.reviewSnapshot(base: base)
  let target = try #require(snapshot.reviewEntries().filter { $0.entry.isMutable }.last)
  #expect(target.entry.identity == nil)
  let instant = try MemoryDocument.ReviewInstant("2026-07-03T00:00:00Z")
  let identity = UUID()
  let after = try MemoryDocument.reviewedBytes(
    target.entry.bytes, identity: identity, instant: instant)
  var replacement = try #require(snapshot.documents.first { $0.path == target.path }?.bytes)
  replacement.replaceSubrange(target.entry.locator.start..<target.entry.locator.end, with: after)
  let audit = try JSONSerialization.data(
    withJSONObject: [
      "origin": "native-approved-entry-review", "base": base, "path": target.path,
      "before": String(decoding: target.entry.bytes, as: UTF8.self),
      "after": String(decoding: after, as: UTF8.self), "reviewed": instant.rawValue,
    ], options: [.sortedKeys, .withoutEscapingSlashes])
  let commit = try fixture.store.reviewCommit(
    base: base, path: target.path, replacement: replacement,
    message: Data("Core memory approved entry review\n\n".utf8) + audit + Data([10]))
  _ = try fixture.git([
    "update-ref", "refs/memory-management/changes/\(SourceDigest(bytes: audit).rawValue)", commit,
  ])
  _ = try fixture.git(["update-ref", "refs/heads/main", commit, base])
  let publications = try manager.verifiedDirectPublications()
  let effect = try #require(publications[commit]?.effects.first)
  #expect(publications.count == 1)
  #expect(effect.start == target.entry.locator.start)
  #expect(effect.identity == identity)
  #expect(effect.before == target.entry.bytes && effect.after == after)
}

@Test(arguments: ["valid", "changed-entry", "changed-document"])
func legacyEntryReviewsReplayWithoutApprovingSuggestionsOrAcceptingContentChanges(
  alteration: String
) throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let store = try MemoryStore(repo: fixture.transaction.memory, environment: [:])
  let git = store.reviewGit
  let base = try store.approvedCommit()
  let snapshot = try store.reviewSnapshot(base: base)
  let target = try #require(snapshot.reviewEntries().first { $0.entry.isMutable })
  let identity = try #require(target.entry.identity)
  let instant = try MemoryDocument.ReviewInstant("2026-07-03T00:00:00Z")
  let after = try MemoryDocument.reviewedBytes(
    alteration == "changed-entry" ? Data(fact("Altered preference.").utf8) : target.entry.bytes,
    identity: identity, instant: instant)
  var replacement = try #require(snapshot.documents.first { $0.path == target.path }?.bytes)
  replacement.replaceSubrange(target.entry.locator.start..<target.entry.locator.end, with: after)
  if alteration == "changed-document" {
    replacement.append(Data(("\n" + fact("Unrelated addition.")).utf8))
  }
  let audit = try JSONSerialization.data(
    withJSONObject: [
      "origin": "native-approved-entry-review", "base": base, "path": target.path,
      "before": String(decoding: target.entry.bytes, as: UTF8.self),
      "after": String(decoding: after, as: UTF8.self), "reviewed": instant.rawValue,
    ], options: [.sortedKeys, .withoutEscapingSlashes])
  let commit = try store.reviewCommit(
    base: base, path: target.path, replacement: replacement,
    message: Data("Core memory approved entry review\n\n".utf8) + audit + Data([10]))
  _ = try git.text([
    "update-ref", "refs/memory-management/changes/\(SourceDigest(bytes: audit).rawValue)", commit,
  ])
  _ = try git.text(["update-ref", "refs/heads/main", commit, base])
  let beforeRefs = try git.text(["for-each-ref", "--format=%(refname) %(objectname)"])
  if alteration == "valid" {
    let reopened = try fixture.controller()
    let rows = try reopened.list()
    #expect(rows.filter { $0.disposition == .approved }.count == ReviewFlowFixture.retainedCount)
    #expect(rows.filter { $0.disposition == .pending }.count == ReviewFlowFixture.pendingCount)
    let pending = try #require(rows.first { $0.disposition == .pending })
    #expect(
      try reopened.preview(candidateID: pending.change.id, clockDate: ReviewFlowFixture.reviewDate)
        .currentBase == commit)
  } else {
    #expect(throws: (any Error).self) { _ = try fixture.controller().list() }
  }
  #expect(try git.text(["rev-parse", "main"]) == commit)
  #expect(try git.text(["for-each-ref", "--format=%(refname) %(objectname)"]) == beforeRefs)
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
