import Foundation
import Testing

@testable import CoreMemories

extension TransactionFixture {
  fileprivate func memoryStore() throws -> MemoryStore {
    try MemoryStore(repo: memory, environment: [:])
  }
}

@Test func mixedBatchPublishesOneCommitAndMakesAllDecisionsEffectiveTogether() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    configurationURL: fixture.configurationURL,
    date: ReviewFlowFixture.reviewDate.addingTimeInterval(1))
  let candidates = session.projection.candidates.filter { $0.disposition == .pending }
  let first = try session.presentAcceptance(candidateID: candidates[0].change.id)
  try session.stage(first)
  let amendment = MemoryBatchAmendment(
    replacement: try MemoryDocument.editableEntry(candidates[1].change.after).replacingOccurrences(
      of: "Synthetic", with: "Corrected synthetic"),
    reason: "Requested correction")
  let second = try session.presentAcceptance(
    candidateID: candidates[1].change.id, amendment: amendment)
  try session.stage(second)
  try session.stageDecision(candidateID: candidates[2].change.id, choice: .reject)
  try session.stageDecision(candidateID: candidates[3].change.id, choice: .deferCandidate)
  let entries = session.projection.entries.filter(\.isMutable)
  let existing = entries[0]
  let editable = try MemoryDocument.editableEntry(Data(existing.expected.utf8))
  try session.stageManual(
    MemoryManagementRequest(
      operation: .update, base: session.persistenceSnapshot.baseCommit, path: existing.path,
      locator: existing.locator, expected: existing.expected,
      replacement: editable.replacingOccurrences(of: "Synthetic", with: "Manually revised"),
      reason: "Requested edit"))
  try session.stage(session.presentConfirmReviewed(entries[1]))
  let base = session.persistenceSnapshot.baseCommit
  #expect(try controller.list().filter { $0.disposition == .approved }.count == 4)
  let saved = try session.save()
  guard case .saved(let receipt) = saved else {
    Issue.record("mixed batch was not saved")
    return
  }
  let commit = try #require(receipt.commit)
  #expect(try fixture.transaction.memoryStore().approvedCommit() == commit)
  let git = Git(repo: fixture.transaction.memory, environment: [:])
  #expect(try git.text(["rev-parse", "\(commit)^"]) == base)
  #expect(try git.text(["rev-parse", try #require(receipt.auditRef)]) == commit)
  let snapshot = try fixture.transaction.memoryStore().reviewSnapshot(base: commit)
  #expect(snapshot.reviewEntries().contains { $0.entry.bytes == first.after })
  #expect(snapshot.reviewEntries().contains { $0.entry.bytes == second.after })
  let rows = try controller.list()
  #expect(rows.filter { $0.disposition == .approved }.count == 6)
  #expect(rows.first { $0.change.id == candidates[2].change.id }?.disposition == .rejected)
  #expect(rows.first { $0.change.id == candidates[3].change.id }?.disposition == .deferred)
  #expect(rows.filter { $0.disposition == .pending }.count == 4)
  #expect(throws: MemoryBatchRecoveryRequired.self) { try drafts.list() }
  #expect(try drafts.list(review: controller).isEmpty)
  guard case .saved(let replayed) = try session.save() else {
    Issue.record("receipt recovery failed")
    return
  }
  #expect(replayed.commit == commit)
}

@Test func batchRejectsAWriteThatInvalidatesAnotherCandidatesContradictionAnchor() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.write(
    "# Memory\n\n" + fact("Original preference."),
    file: fixture.memory.appendingPathComponent("MEMORY.md"))
  let git = Git(repo: fixture.memory, environment: [:])
  _ = try git.data(["add", "."])
  _ = try git.data(["commit", "-m", "Synthetic anchor"], additions: Git.proposalIdentity)
  try fixture.populate()
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        let context = try transactionObject(request)
        let anchor = (context["eligibleMemoryAnchors"] as! [[String: Any]])[0]
        let source = (context["primaryEvidence"] as! [[String: Any]])[0]["source"]!
        let contradiction: [String: Any] = [
          "kind": "memory", "anchor": anchor, "explanation": "Review this exact existing context.",
        ]
        return try transactionResponse(
          request,
          decisions: [
            [
              "kind": "update", "scope": ["kind": "global"], "anchor": anchor,
              "text": "Corrected preference.", "sources": [source],
              "reason": "Requested correction.", "contradictions": [contradiction],
            ],
            [
              "kind": "add", "scope": ["kind": "global"], "text": "Separate preference.",
              "sources": [source], "reason": "Requested addition.",
              "contradictions": [contradiction],
            ],
          ])
      }))
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  try controller.confirmDetach(controller.checkoutPreview())
  let drafts = try MemoryDraftStore(
    repository: fixture.memory, journal: memoryBatchTestJournal(fixture.root))
  let session = try MemoryBatchSession(
    repository: fixture.memory, drafts: drafts, review: controller,
    date: ReviewFlowFixture.reviewDate)
  #expect(session.projection.candidates.count == 2)
  for row in session.projection.candidates {
    try session.stage(session.presentAcceptance(candidateID: row.change.id))
  }
  #expect(throws: (any Error).self) { try session.save() }
  #expect(try fixture.main() == session.persistenceSnapshot.baseCommit)
  #expect(try controller.list().allSatisfy { $0.disposition == .pending })
}

@Test func decisionOnlyBatchInstallsOneManifestWithoutAdvancingApprovedMain() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller)
  let candidates = session.projection.candidates.filter { $0.disposition == .pending }
  try session.stageDecision(candidateID: candidates[0].change.id, choice: .reject)
  try session.stageDecision(candidateID: candidates[1].change.id, choice: .deferCandidate)
  let base = session.persistenceSnapshot.baseCommit
  guard case .decisionsSaved(let receipt) = try session.save() else {
    Issue.record("decisions were not saved")
    return
  }
  #expect(receipt.commit == nil)
  #expect(throws: MemoryBatchRecoveryRequired.self) { try drafts.list() }
  #expect(try drafts.list(review: controller).isEmpty)
  #expect(try fixture.transaction.memoryStore().approvedCommit() == base)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: fixture.reviewState.path).filter {
      $0.hasPrefix("batch-decisions-")
    }.count == 1)
  #expect(
    try controller.list().first { $0.change.id == candidates[0].change.id }?.disposition
      == .rejected)
  #expect(
    try controller.list().first { $0.change.id == candidates[1].change.id }?.disposition
      == .deferred)
  try FileManager.default.removeItem(
    at: fixture.reviewState.appendingPathComponent("batch-decisions-\(receipt.saveID).json"))
  #expect(throws: MemoryBatchRecoveryRequired.self) { try drafts.list(review: controller) }
  #expect(try drafts.read(receipt.draftID, revision: receipt.revision).batch?.items.count == 2)
}

@Test func batchRejectsOverlappingManualAndReviewEffectsWithoutPublishingDecisions() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    date: ReviewFlowFixture.reviewDate.addingTimeInterval(1))
  let entry = try #require(session.projection.entries.first { $0.isMutable })
  try session.stage(session.presentConfirmReviewed(entry))
  try session.stageManual(
    MemoryManagementRequest(
      operation: .delete, base: session.persistenceSnapshot.baseCommit, path: entry.path,
      locator: entry.locator, expected: entry.expected, reason: "Requested deletion"))
  let candidate = try #require(session.projection.candidates.first { $0.disposition == .pending })
  try session.stageDecision(candidateID: candidate.change.id, choice: .reject)
  #expect(throws: (any Error).self) { try session.save() }
  #expect(
    try fixture.transaction.memoryStore().approvedCommit() == session.persistenceSnapshot.baseCommit
  )
  #expect(
    try controller.list().first { $0.change.id == candidate.change.id }?.disposition == .pending)
}
