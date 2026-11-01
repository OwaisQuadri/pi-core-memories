import Foundation
import Testing

@testable import CoreMemories

func savedRun(_ fixture: TransactionFixture) throws -> (runID: String, approvedBase: String) {
  let admission = try DreamRunEncoding.decode(
    DreamRunEncoding.Admission.self,
    bytes: Data(contentsOf: fixture.state.appendingPathComponent("admissions/0.json")))
  return (admission.runID, admission.base)
}

func savedRecoveryPendingAddition(_ fixture: TransactionFixture) throws
  -> (DreamRunStore, (runID: String, approvedBase: String))
{
  try fixture.populate()
  let store = try fixture.store()
  store.beforePublication = { _ in throw CancellationError() }
  #expect(throws: CancellationError.self) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) })
  }
  try fixture.advance()
  return (store, try savedRun(fixture))
}

@Test func savedRecoveryOutsideMainAdvanceRequiresFreshPreviewAndExplicitEntryApproval() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let (store, pending) = try savedRecoveryPendingAddition(fixture)
  let before = try fixture.protectedState()
  let recovery = try store.previewSavedRecovery(runID: pending.runID)
  #expect(recovery.suggestions.count == 1)
  #expect(recovery.suggestions[0].blocker == nil)
  #expect(try fixture.protectedState() == before)
  _ = try transactionCompleted(store.confirmSavedRecovery(recovery))
  #expect(try fixture.protectedState() == before)
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: store, environment: [:])
  let candidate = try #require(controller.list().first)
  #expect(candidate.disposition == .pending)
  try controller.confirmDetach(controller.checkoutPreview())
  let old = try controller.preview(candidateID: candidate.change.id, clockDate: Date())
  let git = Git(repo: fixture.memory, environment: [:])
  let base = try fixture.main()
  let management = try MemoryManagement(repository: fixture.memory, environment: [:]).execute(
    .init(operation: .add, base: base, path: "MEMORY.md",
      replacement: "Keep unrelated management memory. [source: fixture; added: 2026-01-01]",
      reason: "Explicit unrelated management addition"))
  let advanced = try #require(management.commit)
  #expect(throws: (any Error).self) { try controller.apply(old) }
  let fresh = try controller.preview(candidateID: candidate.change.id, clockDate: Date())
  #expect(try fixture.main() == advanced)
  #expect(String(decoding: fresh.replacement, as: UTF8.self).contains("Keep unrelated management memory."))
  let approval = try controller.apply(fresh)
  #expect(try fixture.main() == approval.commit)
  let later = try git.text(
    ["commit-tree", "-p", approval.commit, "-m", "Later management", "\(approval.commit)^{tree}"],
    additions: Git.proposalIdentity)
  _ = try git.data(["update-ref", "refs/heads/main", later, approval.commit])
  #expect(try controller.list().first?.disposition == .approved)
}
