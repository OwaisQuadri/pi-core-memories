import Foundation
import Testing

@testable import CoreMemories

@Test func mixedMultiEditPublicationTransformsUntouchedPendingRangeOnceInParentCoordinates() throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let first = fact("First café 🐟.")
  let second = fact("Second café 🐟.")
  let third = fact("Third café 🐟.")
  try fixture.write(
    "# Memory\n\n" + first + "\n" + second + "\n" + third,
    file: fixture.memory.appendingPathComponent("MEMORY.md"))
  let git = Git(repo: fixture.memory, environment: [:])
  _ = try git.data(["add", "."])
  _ = try git.data(["commit", "-m", "Synthetic entries"], additions: Git.proposalIdentity)
  try fixture.populate()
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        let context = try transactionObject(request)
        let anchors = context["eligibleMemoryAnchors"] as! [[String: Any]]
        let source = (context["primaryEvidence"] as! [[String: Any]])[0]["source"]!
        return try transactionResponse(
          request,
          decisions: anchors.enumerated().map { index, anchor in
            [
              "kind": "update", "scope": ["kind": "global"], "anchor": anchor,
              "text": "Corrected entry \(index) with a longer café 🐟 preference.",
              "sources": [source],
              "reason": "Requested correction.",
              "contradictions": [
                ["kind": "memory", "anchor": anchor, "explanation": "Replace this entry."]
              ],
            ]
          })
      }))
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  try controller.confirmDetach(controller.checkoutPreview())
  let path = "projects/" + String(repeating: "a", count: 64) + ".md"
  let drafts = try MemoryDraftStore(
    repository: fixture.memory, journal: memoryBatchTestJournal(fixture.root))
  let session = try MemoryBatchSession(
    repository: fixture.memory, drafts: drafts, review: controller,
    allowedPaths: ["MEMORY.md", path], date: ReviewFlowFixture.reviewDate)
  let rows = session.projection.candidates.sorted {
    $0.change.locator!.start < $1.change.locator!.start
  }
  #expect(rows.count == 3)
  let entries = session.projection.entries.filter(\.isMutable)
  try session.stage(session.presentAcceptance(candidateID: rows[0].change.id))
  try session.stageManual(
    MemoryManagementRequest(
      operation: .update, base: session.persistenceSnapshot.baseCommit, path: "MEMORY.md",
      locator: entries[1].locator, expected: entries[1].expected,
      replacement: fact("Manually shortened."), reason: "Requested correction"))
  try session.stageManual(
    MemoryManagementRequest(
      operation: .add, base: session.persistenceSnapshot.baseCommit, path: path,
      replacement: fact("Project addition."), reason: "Requested addition"))
  guard case .saved(let receipt) = try session.save() else {
    Issue.record("mixed publication failed")
    return
  }
  #expect(
    try git.committedChangedPathBytes(
      from: session.persistenceSnapshot.baseCommit, to: try #require(receipt.commit))
      == Data(("MEMORY.md\0" + path + "\0").utf8))
  let after = try controller.list()
  #expect(after.first { $0.change.id == rows[0].change.id }?.disposition == .approved)
  #expect(after.first { $0.change.id == rows[1].change.id }?.disposition == .blocked)
  #expect(after.first { $0.change.id == rows[2].change.id }?.disposition == .pending)
  let untouched = try controller.preview(
    candidateID: rows[2].change.id, clockDate: ReviewFlowFixture.reviewDate)
  #expect(untouched.before == Data(third.utf8))
  _ = try controller.apply(untouched)
  #expect(try controller.list().filter { $0.disposition == .approved }.count == 2)
}

@Test func repeatedBatchPublicationsReplayInAncestryOrderAndKeepUntouchedSuggestionsPending() throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  do {
    let controller = try fixture.controller()
    let drafts = try MemoryDraftStore(
      repository: fixture.transaction.memory,
      journal: memoryBatchTestJournal(fixture.transaction.root))
    for _ in 0..<3 {
      let session = try MemoryBatchSession(
        repository: fixture.transaction.memory, drafts: drafts, review: controller,
        date: ReviewFlowFixture.reviewDate)
      let pending = session.projection.candidates.filter { $0.disposition == .pending }
      for row in pending.prefix(2) {
        try session.stage(session.presentAcceptance(candidateID: row.change.id))
      }
      guard case .saved = try session.save() else {
        Issue.record("successive batch did not save")
        return
      }
    }
  }
  let reopened = try fixture.controller()
  let rows = try reopened.list()
  #expect(rows.filter { $0.disposition == .approved }.count == 10)
  #expect(rows.filter { $0.disposition == .pending }.count == 2)
  let untouched = try #require(rows.first { $0.disposition == .pending })
  _ = try reopened.preview(
    candidateID: untouched.change.id, clockDate: ReviewFlowFixture.reviewDate)
}

@Test func unknownExternalCommitStillBlocksPendingCandidateAfterVerifiedBatch() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    date: ReviewFlowFixture.reviewDate)
  let row = try #require(session.projection.candidates.first { $0.disposition == .pending })
  try session.stage(session.presentAcceptance(candidateID: row.change.id))
  guard case .saved(let receipt) = try session.save() else {
    Issue.record("Save failed")
    return
  }
  let git = Git(repo: fixture.transaction.memory, environment: [:])
  let commit = try #require(receipt.commit)
  let tree = try git.text(["rev-parse", commit + "^{tree}"])
  let later = try git.text(
    ["commit-tree", tree, "-p", commit], input: Data("Unknown external publication\n".utf8),
    additions: Git.proposalIdentity)
  _ = try git.data(["update-ref", "refs/heads/main", later, commit])
  #expect(try controller.list().filter { $0.disposition == .blocked }.count == 7)
  guard
    case .saved(let recovered) = try drafts.recoverBatch(
      draftID: session.persistenceSnapshot.draftID, revision: session.persistenceSnapshot.revision,
      review: controller)
  else {
    Issue.record("historical receipt recovery failed")
    return
  }
  #expect(recovered.commit == commit)
  #expect(try git.text(["rev-parse", "main"]) == later)
}
