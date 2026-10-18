import Foundation
import Testing

@testable import CoreMemories

@Test func backendReproControllerCannotPublishIntoAnotherRepository() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let repositoryB = fixture.transaction.root.appendingPathComponent("cloned-memory")
  let clone = try runCommand(
    executable: URL(fileURLWithPath: "/usr/bin/git"),
    arguments: [
      "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "clone", "--no-local",
      "--branch", "main", fixture.transaction.memory.path, repositoryB.path,
    ], environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
  try #require(clone.status == 0)
  let storeA = try MemoryStore(repo: fixture.transaction.memory)
  let storeB = try MemoryStore(repo: repositoryB)
  let originalA = try storeA.approvedCommit()
  let originalB = try storeB.approvedCommit()
  try #require(originalA == originalB)
  let managerB = try MemoryManagement(repository: repositoryB)
  try managerB.confirmDetach(managerB.checkoutPreview())
  let draftsB = try MemoryDraftStore(
    repository: repositoryB, journal: memoryBatchTestJournal(fixture.transaction.root))
  var isRefused = false
  do {
    let session = try MemoryBatchSession(
      repository: repositoryB, drafts: draftsB, review: controller,
      date: ReviewFlowFixture.reviewDate)
    let candidate = try #require(
      session.projection.candidates.first { $0.disposition == .pending })
    try session.stage(session.presentAcceptance(candidateID: candidate.change.id))
    _ = try session.save()
  } catch {
    isRefused = true
  }
  #expect(try storeA.approvedCommit() == originalA)
  #expect(try storeB.approvedCommit() == originalB)
  #expect(isRefused)
  #expect(try draftsB.list().isEmpty)
  #expect(throws: (any Error).self) {
    try MemoryBatchSession(repository: fixture.transaction.memory, drafts: draftsB)
  }
  #expect(try draftsB.list().isEmpty)
  let manual = try MemoryBatchSession(repository: repositoryB, drafts: draftsB)
  try manual.stageManual(
    MemoryManagementRequest(
      operation: .add, base: originalB, path: "MEMORY.md", replacement: fact("Unpublished."),
      reason: "Requested addition"))
  try draftsB.persistBatch(manual.persistenceSnapshot, expectedRevision: 0)
  let before = try draftsB.root.names()
  #expect(throws: (any Error).self) {
    try draftsB.saveBatch(
      manual.persistenceSnapshot, expectedDigest: try memoryBatchDigest(manual.persistenceSnapshot),
      review: controller, checkout: manual.checkout, authorized: [])
  }
  #expect(throws: (any Error).self) { try draftsB.list(review: controller) }
  let recovered = try draftsB.recoverBatch(
    draftID: manual.persistenceSnapshot.draftID, revision: manual.persistenceSnapshot.revision,
    review: controller)
  guard case .outcomeUnknown = recovered else {
    Issue.record("cross-repository recovery was not refused")
    return
  }
  let publisher = MemoryBatchPublisher(root: draftsB.root, store: storeB, review: controller)
  #expect(throws: (any Error).self) { try publisher.composition(manual.persistenceSnapshot) }
  #expect(throws: (any Error).self) { try publisher.recover(manual.persistenceSnapshot) }
  #expect(try draftsB.root.names() == before)
  #expect(try storeB.approvedCommit() == originalB)
}

@Test func canonicalRepositoryAliasesRemainUsableForManualOnlyBatchSave() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let manager = try MemoryManagement(repository: fixture.repo)
  try manager.confirmDetach(manager.checkoutPreview())
  let alias = fixture.root.appendingPathComponent("alias")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.repo)
  let drafts = try MemoryDraftStore(
    repository: fixture.repo, journal: memoryBatchTestJournal(fixture.root))
  let session = try MemoryBatchSession(repository: alias, drafts: drafts)
  try session.stageManual(
    MemoryManagementRequest(
      operation: .add, base: session.persistenceSnapshot.baseCommit, path: "MEMORY.md",
      replacement: fact("Canonical aliases preserve intent."), reason: "Requested addition"))
  guard case .saved = try session.save() else {
    Issue.record("canonical repository alias was rejected")
    return
  }
}
