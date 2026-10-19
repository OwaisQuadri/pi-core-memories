import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

@Test func nativeManualDraftSurvivesNewlyAvailableReviewInfrastructure() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let configurationBytes = try Data(contentsOf: url)
  let workspace = Workspace(configURL: url)
  _ = try await workspace.load()
  let opened = try await workspace.openBatch()
  #expect(opened.draft.batch?.binding.reviewBinding == nil)
  _ = try await workspace.batch(
    .manual(
      MemoryManagementRequest(
        operation: .add, base: opened.draft.baseCommit, path: "MEMORY.md",
        replacement: fact("Manual intent predates review infrastructure."),
        reason: "Requested addition"), nil))
  let original = try await workspace.persistBatch().draft
  let store = try MemoryDraftStore(
    repository: fixture.memory, journal: URL(fileURLWithPath: configuration.journal))
  let current = URL(fileURLWithPath: configuration.journal)
    .appendingPathComponent("\(original.draftID)-current.json")
  let durableBytes = try Data(contentsOf: current)
  let base = try fixture.main()
  try fixture.populate()
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionNotes($0) }))
  let reopened = Workspace(configURL: url)
  let snapshot = try await reopened.load()
  #expect(snapshot.drafts.contains { $0.draftID == original.draftID })
  #expect(snapshot.inspection?.isPresent == true)
  #expect(await reopened.reviewPreparationFailure == nil)
  var openingFailure: String?
  do {
    let restored = try await reopened.openBatch()
    #expect(try memoryBatchDigest(restored.draft) == memoryBatchDigest(original))
  } catch { openingFailure = String(describing: error) }
  #expect(openingFailure == nil, "R5 native reopening must preserve manual intent")
  _ = await reopened.closeBatch()
  var refreshFailure: String?
  do {
    let refreshed = try await workspace.reprepareBatch()
    #expect(try memoryBatchDigest(refreshed.draft) == memoryBatchDigest(original))
  } catch { refreshFailure = String(describing: error) }
  #expect(refreshFailure == nil, "R5 explicit Refresh must preserve manual intent")
  #expect(try Data(contentsOf: url) == configurationBytes)
  #expect(try fixture.main() == base)
  #expect(try Data(contentsOf: current) == durableBytes)
  #expect(
    try memoryBatchDigest(store.read(original.draftID, revision: original.revision))
      == memoryBatchDigest(original))
}

@Test(arguments: [false, true])
func nativeManualDraftIsNotBlockedByRetainedReviewSave(isDecisionOnly: Bool) async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let manager = try MemoryManagement(repository: fixture.memory)
  try manager.confirmDetach(manager.checkoutPreview())
  let workspace = Workspace(configURL: url)
  _ = try await workspace.load()
  let opened = try await workspace.openBatch()
  let candidate = try #require(opened.candidates.first { $0.disposition == .pending })
  if isDecisionOnly {
    _ = try await workspace.batch(.decision(candidate.change.id, .reject))
  } else {
    let shown = try #require(
      try await workspace.batch(.acceptance(candidate.change.id)).presentation)
    _ = try await workspace.batch(.stage(shown))
  }
  let savedDraft = try await workspace.persistBatch().draft
  let result = try await workspace.saveBatch()
  let receipt: MemoryBatchReceipt
  switch result {
  case .saved(let value):
    #expect(!isDecisionOnly)
    receipt = value
  case .decisionsSaved(let value):
    #expect(isDecisionOnly)
    receipt = value
  default:
    Issue.record("R6 setup requires a successful checked review-bearing Save")
    return
  }
  #expect(receipt.draftID == savedDraft.draftID)
  #expect((receipt.commit == nil) == isDecisionOnly)
  let next = try await workspace.openBatch()
  #expect(next.draft.draftID != savedDraft.draftID)
  _ = try await workspace.batch(
    .manual(
      MemoryManagementRequest(
        operation: .add, base: next.draft.baseCommit, path: "MEMORY.md",
        replacement: fact("Distinct manual draft after review Save."),
        reason: "Requested addition"), nil))
  let manual = try await workspace.persistBatch().draft
  #expect(manual.batch?.isManualOnly == true)
  _ = await workspace.closeBatch()
  let journal = URL(fileURLWithPath: configuration.journal)
  let retainedCurrent = journal.appendingPathComponent("\(savedDraft.draftID)-current.json")
  let retainedReceipt = journal.appendingPathComponent("batch-receipt-\(receipt.saveID).json")
  let currentBytes = try Data(contentsOf: retainedCurrent)
  let receiptBytes = try Data(contentsOf: retainedReceipt)
  let manualCurrent = journal.appendingPathComponent("\(manual.draftID)-current.json")
  let manualBytes = try Data(contentsOf: manualCurrent)
  let base = try fixture.main()
  let root = fixture.state.appendingPathComponent("root.json")
  try FileManager.default.removeItem(at: root)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let unavailableState = try fixture.snapshot(fixture.state)
  let reopened = Workspace(configURL: url)
  let snapshot = try await reopened.load()
  #expect(
    snapshot.drafts.contains { $0.draftID == manual.draftID },
    "R6 native global listing must retain distinct manual intent; failures: \(snapshot.failures)")
  var openingFailure: String?
  var restored: MemoryBatchProjection?
  do { restored = try await reopened.restoreBatch(manual) } catch {
    openingFailure = String(describing: error)
  }
  #expect(
    openingFailure == nil,
    "R6 unrelated saved review history must not block explicit manual restoration")
  #expect(try fixture.main() == base)
  #expect(try Data(contentsOf: manualCurrent) == manualBytes)
  if let restored {
    #expect(restored.draft.draftID == manual.draftID)
    #expect(try memoryBatchDigest(restored.draft) == memoryBatchDigest(manual))
    guard case .saved = try await reopened.saveBatch() else {
      Issue.record("R6 distinct manual draft must remain saveable without dream infrastructure")
      return
    }
  }
  #expect(try Data(contentsOf: retainedCurrent) == currentBytes)
  #expect(try Data(contentsOf: retainedReceipt) == receiptBytes)
  #expect(try fixture.snapshot(fixture.state) == unavailableState)
}

@Test func nativeCatalogPageBeyond10048EntriesRemainsReachableWithBoundedStaging() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let text = "# Memory\n\n" + (0..<10_049).map { fact("Entry \($0).") + "\n" }.joined()
  #expect(text.utf8.count < 1_048_576)
  try fixture.write(text, file: fixture.memory.appendingPathComponent("MEMORY.md"))
  let git = Git(repo: fixture.memory, environment: [:])
  _ = try git.data(["add", "MEMORY.md"])
  try fixture.advance()
  let base = try fixture.main()
  let approved = try MemoryStore(repo: fixture.memory).reviewSnapshot(base: base)
  #expect(approved.documents.count == 1)
  #expect(
    approved.reviewEntries().filter { MemoryDocument.isMemoryContent($0.entry.bytes) }.count
      == 10_049)
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let workspace = Workspace(configURL: url)
  _ = try await workspace.load()
  let opened = try await workspace.openBatch()
  #expect(opened.entries.count == 64)
  #expect(opened.entryCount == 10_049)
  _ = try await workspace.batch(
    .manual(
      MemoryManagementRequest(
        operation: .add, base: base, path: "MEMORY.md", replacement: fact("One staged item."),
        reason: "Requested addition"), nil))
  let previous = try await workspace.batch(.page(9_984)).projection
  #expect(previous.catalogOffset + 64 < max(previous.entryCount, previous.candidateCount))
  #expect(previous.entries.count == 64)
  #expect(previous.draft.batch?.items.count == 1)
  var pagingFailure: String?
  do {
    let page = try await workspace.batch(.page(previous.catalogOffset + 64)).projection
    #expect(page.catalogOffset == 10_048)
    #expect(page.entries.count == 1)
    #expect(page.entries.first?.expected.contains("Entry 10048.") == true)
    #expect(try memoryBatchDigest(page.draft) == memoryBatchDigest(previous.draft))
  } catch { pagingFailure = String(describing: error) }
  #expect(pagingFailure == nil, "R7 Next must reach the supported final entry")
  let beforeInvalid = try await workspace.openBatch()
  for offset in [Int.min, -1, 10_050, Int.max] {
    do {
      _ = try await workspace.batch(.page(offset))
      Issue.record("R7 invalid catalogue offset must fail without changing the page")
    } catch {}
    let retained = try await workspace.openBatch()
    #expect(retained.catalogOffset == beforeInvalid.catalogOffset)
    #expect(retained.entries.map(\.expected) == beforeInvalid.entries.map(\.expected))
    #expect(try memoryBatchDigest(retained.draft) == memoryBatchDigest(beforeInvalid.draft))
  }
  #expect(try fixture.main() == base)
}
