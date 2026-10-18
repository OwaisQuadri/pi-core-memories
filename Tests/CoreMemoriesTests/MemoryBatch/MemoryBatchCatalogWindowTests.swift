import Foundation
import Testing

@testable import CoreMemories

@Test func catalogPagingPreservesAmendedAcceptanceAndConfirmReviewedInOneCommit() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    configurationURL: fixture.configurationURL,
    date: ReviewFlowFixture.reviewDate.addingTimeInterval(1), catalogLimit: 1)
  let first = try #require(session.projection.candidates.first)
  let amendment = MemoryBatchAmendment(
    replacement: try MemoryDocument.editableEntry(first.change.after).replacingOccurrences(
      of: "Synthetic", with: "Corrected synthetic"), reason: "Requested correction")
  let amended = try session.prepareAmendment(candidateID: first.change.id, amendment: amendment)
  try session.stage(amended)
  let entry = try #require(session.projection.entries.first)
  let reviewed = try session.presentConfirmReviewed(entry)
  try session.stage(reviewed)
  session.select(amended.itemID)
  let before = session.persistenceSnapshot
  let secondPage = try session.prepareCatalog(offset: 1)
  #expect(try memoryBatchDigest(secondPage.draft) == memoryBatchDigest(before))
  #expect(secondPage.selectedItemID == amended.itemID)
  #expect(secondPage.needsReview.isEmpty)
  #expect(secondPage.retainedCandidates.map(\.change.id) == [first.change.id])
  #expect(secondPage.retainedEntries.map(\.expected) == [entry.expected])
  let second = try #require(secondPage.candidates.first)
  let accepted = try session.presentAcceptance(candidateID: second.change.id)
  try session.stage(accepted)
  try session.prepareCatalog(offset: 3)
  #expect(session.projection.needsReview.isEmpty)
  #expect(try session.presentAcceptance(candidateID: first.change.id).after == amended.after)
  #expect(try session.presentConfirmReviewed(entry).after == reviewed.after)
  let base = before.baseCommit
  guard case .saved(let receipt) = try session.save() else {
    Issue.record("cross-window batch did not save")
    return
  }
  let commit = try #require(receipt.commit)
  let git = Git(repo: fixture.transaction.memory, environment: [:])
  #expect(try git.text(["rev-list", "--count", "\(base)..\(commit)"]) == "1")
  let snapshot = try MemoryStore(repo: fixture.transaction.memory).reviewSnapshot(base: commit)
  for after in [amended.after, accepted.after, reviewed.after] {
    #expect(snapshot.reviewEntries().contains { $0.entry.bytes == after })
  }
  #expect(try controller.list().filter { $0.disposition == .approved }.count == 6)
}

@Test func restoredOffPageAmendmentAndConfirmReviewedNeedFreshReviewWithoutLosingIntent() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let original = try drafts.create()
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller, restoring: original,
    date: ReviewFlowFixture.reviewDate.addingTimeInterval(1), catalogLimit: 1)
  let candidate = try #require(session.projection.candidates.first)
  let presentation = try session.prepareAmendment(
    candidateID: candidate.change.id,
    amendment: MemoryBatchAmendment(
      replacement: try MemoryDocument.editableEntry(candidate.change.after).replacingOccurrences(
        of: "Synthetic", with: "Amended synthetic"), reason: "Requested correction"))
  try session.stage(presentation)
  let entry = try #require(session.projection.entries.first)
  let reviewed = try session.presentConfirmReviewed(entry)
  try session.stage(reviewed)
  let durable = session.persistenceSnapshot
  try drafts.persistBatch(durable, expectedRevision: original.revision)
  let listed = try drafts.list(review: controller)
  let restoredDraft = try #require(listed.first)
  let restored = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    restoring: restoredDraft,
    date: ReviewFlowFixture.reviewDate.addingTimeInterval(100), catalogLimit: 1, catalogOffset: 4)
  #expect(restored.projection.retainedCandidates.map(\.change.id) == [candidate.change.id])
  #expect(restored.projection.retainedEntries.map(\.expected) == [entry.expected])
  #expect(restored.projection.needsReview == [presentation.itemID, reviewed.itemID])
  #expect(throws: (any Error).self) { try restored.stage(presentation) }
  #expect(throws: (any Error).self) { try restored.save() }
  try restored.prepareCatalog(offset: 2)
  #expect(try memoryBatchDigest(restored.persistenceSnapshot) == memoryBatchDigest(durable))
  #expect(restored.projection.needsReview == [presentation.itemID, reviewed.itemID])
  let fresh = try restored.presentAcceptance(candidateID: candidate.change.id)
  #expect(fresh.after == presentation.after)
  try restored.stage(fresh)
  try restored.stage(restored.presentConfirmReviewed(entry))
  #expect(restored.projection.needsReview.isEmpty)
  guard case .saved = try restored.save() else {
    Issue.record("freshly reviewed restored batch did not save")
    return
  }
}

@Test func catalogRetainsOnlyStagedRowsAndUndoRestoresEvictedCandidateWithoutExternalWork() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    date: ReviewFlowFixture.reviewDate, catalogLimit: 2)
  let first = try #require(session.projection.candidates.first)
  let staged = try session.presentAcceptance(candidateID: first.change.id)
  try session.stage(staged)
  for offset in stride(from: 2, through: 12, by: 2) {
    let page = try session.prepareCatalog(offset: offset)
    #expect(page.candidates.count <= 2)
    #expect(page.retainedCandidates.map(\.change.id) == [first.change.id])
    #expect(session.preparedCandidates.count == page.candidates.count + 1)
    #expect(page.entries.count <= 2)
    #expect(page.candidateCount == 12)
    #expect(page.entryCount == 4)
    #expect(page.needsReview.isEmpty)
  }
  try session.remove(staged.itemID)
  #expect(session.preparedCandidates.isEmpty)
  try session.prepareCatalog(offset: 4)
  let commands = MemoryBatchInteractionCount()
  var historyRefreshes = 0
  controller.batchHistoryObserver = { historyRefreshes += 1 }
  try Git.$memoryBatchCommandObserver.withValue(
    { commands.increment() },
    operation: {
      try session.undo()
      session.select(staged.itemID)
      let fresh = try session.presentAcceptance(candidateID: first.change.id)
      try session.stage(fresh)
      try session.stageDecision(candidateID: first.change.id, choice: .deferCandidate)
      try session.undo()
      #expect(session.projection.retainedCandidates.map(\.change.id) == [first.change.id])
    })
  #expect(commands.count == 0)
  #expect(historyRefreshes == 0)
  #expect(session.preparedCandidates.count == 3)
}

@Test(arguments: ["configuration", "base", "index", "sources", "offset"])
func failedCatalogPreparationPreservesPageStagedIntentSelectionAndAuthority(failure: String) throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    configurationURL: fixture.configurationURL, date: ReviewFlowFixture.reviewDate, catalogLimit: 1)
  let candidate = try #require(session.projection.candidates.first)
  let presentation = try session.presentAcceptance(candidateID: candidate.change.id)
  try session.stage(presentation)
  session.select(presentation.itemID)
  let before = session.projection
  switch failure {
  case "configuration":
    var configuration = try MemoryConfiguration.load(from: fixture.configurationURL)
    configuration.deviceKey = String(repeating: "b", count: 64)
    try configuration.save(to: fixture.configurationURL)
  case "base":
    let git = Git(repo: fixture.transaction.memory, environment: [:])
    let parent = try git.text(["rev-parse", before.draft.baseCommit + "^"])
    _ = try git.text(["update-ref", "refs/heads/main", parent])
  case "index":
    let index = fixture.transaction.memory.appendingPathComponent(".git/index")
    try (Data(contentsOf: index) + Data([0])).write(to: index)
  case "sources":
    try FileManager.default.removeItem(
      at: fixture.transaction.state.appendingPathComponent("root.json"))
  default: break
  }
  #expect(throws: (any Error).self) {
    try session.prepareCatalog(offset: failure == "offset" ? -1 : 1)
  }
  let after = session.projection
  #expect(try memoryBatchDigest(after.draft) == memoryBatchDigest(before.draft))
  #expect(after.catalogOffset == before.catalogOffset)
  #expect(after.candidates.map(\.change.id) == before.candidates.map(\.change.id))
  #expect(after.entries.map(\.expected) == before.entries.map(\.expected))
  #expect(after.retainedCandidates.isEmpty)
  #expect(after.selectedItemID == before.selectedItemID)
  #expect(after.needsReview.isEmpty)
  try session.stage(presentation)
}

@Test(arguments: ["project", "device", "device-project"])
func explicitAbsentTargetPreparationPreservesAcceptanceAndRestoresOnlyPathIntent(scope: String)
  throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  var configuration = try MemoryConfiguration.load(from: fixture.configurationURL)
  configuration.deviceKey = String(repeating: "d", count: 64)
  try configuration.save(to: fixture.configurationURL)
  let controller = try fixture.controller()
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let original = try drafts.create()
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller, restoring: original,
    configurationURL: fixture.configurationURL, allowedPaths: ["MEMORY.md"],
    date: ReviewFlowFixture.reviewDate)
  let candidate = try #require(session.projection.candidates.first { $0.disposition == .pending })
  let acceptance = try session.presentAcceptance(candidateID: candidate.change.id)
  try session.stage(acceptance)
  let project = try #require(try MemoryStore.projectKey(cwd: fixture.transaction.memory))
  #expect(!configuration.projectBindings.values.contains(project))
  let device = try #require(configuration.deviceKey)
  let path =
    scope == "project"
    ? "projects/\(project).md"
    : scope == "device"
      ? "devices/\(device)/MEMORY.md"
      : "devices/\(device)/projects/\(project).md"
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.transaction.memory.appendingPathComponent(path).path))
  let request = MemoryManagementRequest(
    operation: .add, base: session.persistenceSnapshot.baseCommit, path: path,
    replacement: fact("Requested new scope."), reason: "Requested addition")
  #expect(throws: (any Error).self) { try session.stageManual(request) }
  let before = session.persistenceSnapshot
  let prepared = try session.preparePath(path)
  #expect(prepared.draft.revision == before.revision + 1)
  #expect(prepared.draft.batch?.binding.allowedPaths == ["MEMORY.md", path].sorted())
  #expect(prepared.draft.batch?.binding.preparedPaths == [path])
  #expect(
    try memoryBatchDigest(prepared.draft.batch!.items) == memoryBatchDigest(before.batch!.items))
  #expect(prepared.needsReview.isEmpty)
  #expect(try session.preparePath(path).draft.revision == prepared.draft.revision)
  try session.stageManual(request)
  let durable = session.persistenceSnapshot
  try drafts.persistBatch(durable, expectedRevision: original.revision)
  let restored = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller, restoring: durable,
    configurationURL: fixture.configurationURL, allowedPaths: ["MEMORY.md"],
    date: ReviewFlowFixture.reviewDate)
  #expect(try memoryBatchDigest(restored.persistenceSnapshot) == memoryBatchDigest(durable))
  #expect(restored.projection.needsReview == [acceptance.itemID])
  #expect(throws: (any Error).self) { try restored.stage(acceptance) }
  guard case .saved(let receipt) = try session.save() else {
    Issue.record("mixed acceptance and new target did not save")
    return
  }
  let commit = try #require(receipt.commit)
  let git = Git(repo: fixture.transaction.memory, environment: [:])
  #expect(try git.text(["rev-list", "--count", "\(before.baseCommit)..\(commit)"]) == "1")
  let snapshot = try MemoryStore(repo: fixture.transaction.memory).reviewSnapshot(base: commit)
  #expect(snapshot.reviewEntries().contains { $0.entry.bytes == acceptance.after })
  #expect(
    snapshot.documents.first { $0.path == path }?.bytes?.contains(
      Data("Requested new scope.".utf8)) == true)
}

@Test(arguments: ["invalid-path", "configuration", "sources"])
func failedExplicitPathPreparationDoesNotExpandScopeOrReplaceStagedIntent(failure: String) throws {
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
  let acceptance = try session.presentAcceptance(candidateID: candidate.change.id)
  try session.stage(acceptance)
  session.select(acceptance.itemID)
  let before = session.projection
  if failure == "configuration" {
    var configuration = try MemoryConfiguration.load(from: fixture.configurationURL)
    configuration.deviceKey = String(repeating: "e", count: 64)
    try configuration.save(to: fixture.configurationURL)
  } else if failure == "sources" {
    try FileManager.default.removeItem(
      at: fixture.transaction.state.appendingPathComponent("root.json"))
  }
  let path =
    failure == "invalid-path" ? "../MEMORY.md" : "projects/\(String(repeating: "f", count: 64)).md"
  #expect(throws: (any Error).self) { try session.preparePath(path) }
  #expect(try memoryBatchDigest(session.persistenceSnapshot) == memoryBatchDigest(before.draft))
  #expect(session.projection.candidates.map(\.change.id) == before.candidates.map(\.change.id))
  #expect(session.projection.selectedItemID == before.selectedItemID)
  #expect(session.projection.needsReview.isEmpty)
  try session.stage(acceptance)
}
