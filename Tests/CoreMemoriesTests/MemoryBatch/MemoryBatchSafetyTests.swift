import Foundation
import Testing

@testable import CoreMemories

@Test(arguments: [false, true])
func matchingReceiptAloneCannotHideAnUnpublishedBatch(isPublishingReceipt: Bool) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let drafts = try MemoryDraftStore(
    repository: fixture.repo, journal: memoryBatchTestJournal(fixture.root))
  let original = try drafts.create()
  let session = try MemoryBatchSession(
    repository: fixture.repo, drafts: drafts, restoring: original)
  try session.stageManual(
    MemoryManagementRequest(
      operation: .add, base: original.baseCommit, path: "MEMORY.md",
      replacement: fact("Unpublished intent."), reason: "Requested addition"))
  let draft = session.persistenceSnapshot
  try drafts.persistBatch(draft, expectedRevision: original.revision)
  let saveID = try memoryBatchDigest(draft)
  let receipt = MemoryBatchReceipt(
    saveID: saveID, draftID: draft.draftID, revision: draft.revision, base: draft.baseCommit,
    commit: isPublishingReceipt ? draft.baseCommit : nil,
    auditRef: isPublishingReceipt ? "refs/memory-batches/\(saveID)" : nil)
  try drafts.root.installReviewFile(
    MemoryReviewEncoding.encode(receipt), name: "batch-receipt-\(saveID).json")
  #expect(throws: MemoryBatchRecoveryRequired.self) { try drafts.list() }
  #expect(try drafts.read(draft.draftID, revision: draft.revision).batch?.items.count == 1)
  #expect(try fixture.store.approvedCommit() == draft.baseCommit)
}

@Test func finalSaveRechecksSelectedConfigurationAfterPreparationAndImmediatelyBeforePublication()
  throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    configurationURL: fixture.configurationURL, date: ReviewFlowFixture.reviewDate)
  let candidate = try #require(session.projection.candidates.first { $0.disposition == .pending })
  try session.stage(session.presentAcceptance(candidateID: candidate.change.id))
  drafts.beforePublication = {
    var configuration = try MemoryConfiguration.load(from: fixture.configurationURL)
    configuration.deviceKey = String(repeating: "b", count: 64)
    try configuration.save(to: fixture.configurationURL)
  }
  #expect(throws: (any Error).self) { try session.save() }
  #expect(
    try controller.list().first { $0.change.id == candidate.change.id }?.disposition == .pending)
  #expect(
    try MemoryStore(repo: fixture.transaction.memory).approvedCommit()
      == session.persistenceSnapshot.baseCommit)
}

@Test func manualOnlyBatchDoesNotRequireDreamStoreEvenWithRetainedPublishedReviewAttempts() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    date: ReviewFlowFixture.reviewDate)
  let candidate = try #require(session.projection.candidates.first { $0.disposition == .pending })
  try session.stage(session.presentAcceptance(candidateID: candidate.change.id))
  guard case .saved = try session.save() else {
    Issue.record("review batch failed")
    return
  }
  try FileManager.default.removeItem(at: fixture.transaction.state)
  let manual = try MemoryBatchSession(repository: fixture.transaction.memory, drafts: drafts)
  try manual.stageManual(
    MemoryManagementRequest(
      operation: .add, base: manual.persistenceSnapshot.baseCommit, path: "MEMORY.md",
      replacement: fact("Independent manual work."), reason: "Requested addition"))
  guard case .saved = try manual.save() else {
    Issue.record("manual work incorrectly required a dream store")
    return
  }
}

@Test func savedBatchSourceFailureReturnsRecoveryRequiredInsteadOfClaimingNothingWasSaved() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    date: ReviewFlowFixture.reviewDate)
  let candidate = try #require(session.projection.candidates.first { $0.disposition == .pending })
  try session.stage(session.presentAcceptance(candidateID: candidate.change.id))
  guard case .saved(let receipt) = try session.save() else {
    Issue.record("Save failed")
    return
  }
  try FileManager.default.removeItem(
    at: fixture.transaction.state.appendingPathComponent("root.json"))
  guard case .outcomeUnknown = try session.save() else {
    Issue.record("unverifiable saved outcome was reported as an ordinary failed Save")
    return
  }
  #expect(try MemoryStore(repo: fixture.transaction.memory).approvedCommit() == receipt.commit)
}

@Test(arguments: ["forged-tree", "symbolic-ref", "prefix-ref"])
func batchRecoveryRejectsForgedPublicationAndBlocksAnotherSave(failure: String) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let drafts = try MemoryDraftStore(
    repository: fixture.repo, journal: memoryBatchTestJournal(fixture.root))
  let session = try MemoryBatchSession(repository: fixture.repo, drafts: drafts)
  try session.stageManual(
    MemoryManagementRequest(
      operation: .add, base: session.persistenceSnapshot.baseCommit, path: "MEMORY.md",
      replacement: fact("Requested addition."), reason: "Requested addition"))
  guard case .saved(let receipt) = try session.save() else {
    Issue.record("initial Save failed")
    return
  }
  let audit = try #require(receipt.auditRef)
  let commit = try #require(receipt.commit)
  _ = try fixture.git(["update-ref", "-d", audit])
  if failure == "forged-tree" {
    let tree = try fixture.git(["rev-parse", session.persistenceSnapshot.baseCommit + "^{tree}"])
    let message = try fixture.git(["show", "-s", "--format=%B", commit])
    let forged = try fixture.git(
      ["commit-tree", tree, "-p", session.persistenceSnapshot.baseCommit],
      input: Data((message + "\n").utf8))
    _ = try fixture.git(["update-ref", audit, forged])
  } else if failure == "symbolic-ref" {
    _ = try fixture.git(["symbolic-ref", audit, "refs/heads/main"])
  } else {
    _ = try fixture.git(["update-ref", audit + "/descendant", commit])
  }
  guard case .outcomeUnknown = try session.save() else {
    Issue.record("forged receipt was trusted")
    return
  }
  let next = try MemoryBatchSession(repository: fixture.repo, drafts: drafts)
  try next.stageManual(
    MemoryManagementRequest(
      operation: .add, base: next.persistenceSnapshot.baseCommit, path: "MEMORY.md",
      replacement: fact("Another request."), reason: "Requested addition"))
  guard case .outcomeUnknown = try next.save() else {
    Issue.record("unresolved outcome did not block publication")
    return
  }
  #expect(try fixture.store.approvedCommit() == commit)
}

@Test(arguments: ["before-install", "after-install", "directory-sync"])
func decisionManifestInterruptionCannotSaveOnlyPartOfTheChoices(boundary: String) throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller)
  let rows = session.projection.candidates.filter { $0.disposition == .pending }
  for row in rows.prefix(2) {
    try session.stageDecision(candidateID: row.change.id, choice: .reject)
  }
  let name = "batch-decisions-\(try memoryBatchDigest(session.persistenceSnapshot)).json"
  let event: MemoryReviewPersistenceEvent =
    boundary == "before-install"
    ? .beforeInstall(name)
    : boundary == "after-install" ? .afterInstall(name) : .afterDirectorySync(name)
  controller.persistenceFault = {
    if $0 == event { throw MemoryError("synthetic decision interruption") }
  }
  if boundary == "before-install" {
    #expect(throws: (any Error).self) { try session.save() }
  } else {
    guard case .savedNeedsRecovery = try session.save() else {
      Issue.record("installed decision manifest lost its outcome")
      return
    }
  }
  controller.persistenceFault = nil
  let saved = try controller.list().filter { $0.disposition == .rejected }
  #expect(saved.count == (boundary == "before-install" ? 0 : 2))
  #expect(
    try MemoryStore(repo: fixture.transaction.memory).approvedCommit()
      == session.persistenceSnapshot.baseCommit)
  if boundary != "before-install" {
    guard case .decisionsSaved = try session.save() else {
      Issue.record("decision receipt recovery failed")
      return
    }
  }
}
