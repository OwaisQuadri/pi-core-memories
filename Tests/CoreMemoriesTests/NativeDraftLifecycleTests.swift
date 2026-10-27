import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

@MainActor func pendingNativeModel(
  _ fixture: TransactionFixture, persistence: NativeBatchPersistence = NativeBatchPersistence()
) async throws -> AppModel {
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let model = AppModel(configURL: url, autosaveDelay: .seconds(3600), persistence: persistence)
  await model.load()
  _ = try #require(model.catalog)
  await model.add()
  model.editorText = "Retain this synthetic draft. [source: fixture; added: 2026-10-17]"
  model.editorReason = "Synthetic edit"
  model.editorChanged()
  #expect(model.isInputDirty)
  return model
}

@Test(arguments: ["missing", "corrupt"])
@MainActor func nativeActionsStayBlockedUntilTheSelectedProfileLoads(_ variant: String) async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let url = fixture.root.appendingPathComponent("profile/selected.json")
  let model = AppModel(configURL: url)
  try await model.workspace.configure(queueConfiguration(fixture))
  try FileManager.default.removeItem(at: url)
  if variant == "corrupt" { try fixture.write("{", file: url) }
  #expect(model.isBusy)
  await model.add()
  #expect(!model.isEditing)
  await model.load()
  #expect(model.failure != nil)
  #expect(model.isBusy)
  await model.add()
  #expect(!model.isEditing)
  #expect(model.catalog == nil)
  let before = try fixture.snapshot(fixture.memory)
  await model.prepareCheckout()
  #expect(model.checkout == nil)
  #expect(try fixture.snapshot(fixture.memory) == before)
  model.checkout = try MemoryManagement(repository: fixture.memory).checkoutPreview()
  let beforeDetachment = try fixture.snapshot(fixture.memory)
  await model.detach()
  #expect(model.checkout != nil)
  #expect(try fixture.snapshot(fixture.memory) == beforeDetachment)
  let delegate = ApplicationDelegate()
  delegate.model = model
  #expect(await delegate.isTerminationReady())
}

@Test @MainActor func nativeDraftFinalRemovalIsFlushedBeforeQuitAndDoesNotReturn() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let model = try await pendingNativeModel(fixture)
  try await model.shutdown()
  await model.removeItem(try #require(model.stagedItems.first).itemID)
  try await model.shutdown()
  let reopened = AppModel(configURL: model.configURL)
  await reopened.load()
  #expect(reopened.stagedItems.isEmpty)
  #expect(reopened.draft?.batch?.items.isEmpty == true)
  #expect(!model.isDraftDirty)
  try await reopened.shutdown()
}

@Test @MainActor func nativeRefreshAllowsReselectingTheSameSuggestion() async throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = AppModel(configURL: fixture.configurationURL)
  model.section = "Memories"
  await model.load()
  let candidate = try #require(model.actionableCandidates.first)
  let selection = NativeMemorySelection.candidate(candidate.change.id.rawValue)
  await model.selectMemory(selection)
  try #require(model.presentation != nil)
  await model.refresh()
  try #require(model.failure == nil)
  await model.selectMemory(selection)
  #expect(model.presentation != nil)
  await model.stageShown()
  #expect(model.stagedItems.count == 1)
  try await model.shutdown()
}

@Test @MainActor func nativeProfileReplacementClearsThePreviousRepositoryEditor() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let other = try TransactionFixture()
  defer { other.clean() }
  for (owner, text) in [(fixture, "First repository."), (other, "Second repository.")] {
    try owner.write(
      "# Memory\n\n" + fact(text), file: owner.memory.appendingPathComponent("MEMORY.md"))
    _ = try Git(repo: owner.memory, environment: [:]).data(["add", "MEMORY.md"])
    try owner.advance()
  }
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try queueConfiguration(fixture).save(to: url)
  let model = AppModel(configURL: url)
  model.section = "Memories"
  await model.load()
  let entry = try #require(model.visibleEntries.first)
  await model.selectMemory(.entry(entry.path, entry.locator.start))
  try #require(model.editorText.contains("First repository."))
  model.configuration = queueConfiguration(other)
  await model.saveSettings()
  try #require(model.failure == nil)
  #expect(model.selection == nil)
  #expect(model.editorTarget == nil)
  #expect(model.editorText.isEmpty)
  let replacement = try #require(model.visibleEntries.first)
  await model.selectMemory(.entry(replacement.path, replacement.locator.start))
  #expect(model.editorText.contains("Second repository."))
  try await model.shutdown()
}

@Test @MainActor func nativeRefreshReplacesOnlyTheEmptyDraftAfterApprovedMainAdvances() async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let model = AppModel(configURL: url)
  model.section = "Memories"
  await model.load()
  await model.pauseQueue()
  let original = try #require(model.draft)
  try #require(model.stagedItems.isEmpty)
  try #require(!model.isInputDirty)
  let store = try MemoryDraftStore(
    repository: fixture.memory, journal: URL(fileURLWithPath: configuration.journal))
  let unrelated = try store.create(operations: [
    MemoryManagementRequest(
      operation: .add, base: original.baseCommit, path: "MEMORY.md",
      replacement: fact("Unrelated retained draft."), reason: "Requested addition")
  ])
  try fixture.advance()
  let advanced = try fixture.main()
  await model.refresh()
  #expect(model.failure == nil)
  #expect(model.draft?.baseCommit == advanced)
  #expect(model.draft?.draftID != original.draftID)
  #expect(model.stagedItems.isEmpty)
  #expect(try fixture.main() == advanced)
  let listed = try store.list()
  #expect(listed.contains { $0.draftID == unrelated.draftID })
  #expect(!listed.contains { $0.draftID == original.draftID })
  try await model.shutdown()
}

@Test @MainActor func nativeRefreshDrainsFinalRemovalBeforeReplacingTheEmptyOwner() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let control = NativePersistenceControl()
  let model = try await pendingNativeModel(
    fixture, persistence: NativeBatchPersistence(write: control.write))
  try await model.flushInputAndPersistence()
  await model.removeItem(try #require(model.stagedItems.first).itemID)
  let original = try #require(model.draft)
  await control.failInstalledWrite()
  try fixture.advance()
  let advanced = try fixture.main()
  await model.refresh()
  #expect(model.failure != nil)
  #expect(model.draft?.draftID == original.draftID)
  #expect(model.isDraftDirty)
  let failed = try #require(await control.requests.last)
  await control.resumeWrites()
  model.failure = nil
  await model.refresh()
  #expect(model.failure == nil)
  #expect(model.draft?.draftID != original.draftID)
  #expect(model.draft?.baseCommit == advanced)
  #expect(model.stagedItems.isEmpty)
  let retried = try #require(await control.requests.last)
  #expect(try memoryBatchDigest(failed) == memoryBatchDigest(retried))
  try await model.shutdown()
}

@Test @MainActor func nativeCheckoutReplacementAllowsReselectingTheSameSuggestion() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try queueConfiguration(fixture).save(to: url)
  let model = AppModel(configURL: url)
  model.section = "Memories"
  await model.load()
  let candidate = try #require(model.actionableCandidates.first)
  let selection = NativeMemorySelection.candidate(candidate.change.id.rawValue)
  await model.selectMemory(selection)
  try #require(model.presentation != nil)
  await model.prepareCheckout()
  try #require(model.checkout?.isDetachRequired == true)
  await model.detach()
  try #require(model.failure == nil)
  await model.selectMemory(selection)
  #expect(model.presentation != nil)
  await model.stageShown()
  #expect(model.stagedItems.count == 1)
  try await model.shutdown()
}

@Test @MainActor func nativeDraftStaleFirstAutosavePreservesEditsThroughRefreshAndRelaunch()
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let model = try await pendingNativeModel(fixture)
  let base = try fixture.main()
  try fixture.advance()
  let advanced = try fixture.main()
  await model.refresh()
  #expect(model.stagedItems.count == 1)
  #expect(model.draft?.baseCommit == base)
  try await model.shutdown()
  let reopened = AppModel(configURL: model.configURL)
  await reopened.load()
  #expect(reopened.stagedItems.count == 1)
  #expect(reopened.draft?.baseCommit == base)
  await reopened.loadCandidates()
  #expect(reopened.failure != nil)
  #expect(reopened.stagedItems.count == 1)
  await reopened.save()
  #expect(reopened.stagedItems.count == 1)
  #expect(try fixture.main() == advanced)
  try await reopened.shutdown()
}

@Test @MainActor func nativeTerminationRefusesFailedDraftFlushAndCanRetry() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let control = NativePersistenceControl()
  await control.failWrites()
  let model = try await pendingNativeModel(
    fixture, persistence: NativeBatchPersistence(write: control.write))
  let delegate = ApplicationDelegate()
  delegate.model = model
  #expect(await delegate.isTerminationReady() == false)
  #expect(model.failure != nil)
  #expect(model.stagedItems.count == 1)
  #expect(model.isDraftDirty)
  #expect(!model.isBusy)
  await control.resumeWrites()
  #expect(await delegate.isTerminationReady())
  #expect(!model.isDraftDirty)
  let requests = await control.requests
  #expect(requests.count == 2)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  #expect(try encoder.encode(requests[0]) == encoder.encode(requests[1]))
}

@Test @MainActor func nativeFailedAutosaveKeepsInputDirtyAndRetriesWithoutInterruptingEditing()
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let control = NativePersistenceControl()
  await control.failWrites()
  let model = AppModel(
    configURL: url, autosaveDelay: .milliseconds(1),
    persistence: NativeBatchPersistence(write: control.write))
  await model.load()
  await model.add()
  model.editorText = fact("Failed autosave keeps this text.")
  model.editorReason = "Retain this reason"
  model.editorChanged()
  let autosave = try #require(model.autosaveTask)
  await autosave.value
  #expect(model.draftFailure != nil)
  #expect(model.failure == nil)
  #expect(model.isDraftDirty)
  #expect(model.editorText == fact("Failed autosave keeps this text."))
  #expect(model.editorReason == "Retain this reason")
  await control.resumeWrites()
  try await model.shutdown()
  #expect(!model.isDraftDirty)
  #expect(model.draftFailure == nil)
}

@Test @MainActor func nativeFailedRestoreLeavesTheActiveSessionAndInputIntact() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let store = try MemoryDraftStore(
    repository: fixture.memory, journal: URL(fileURLWithPath: queueConfiguration(fixture).journal))
  let stale = try store.create()
  try fixture.advance()
  _ = try store.create()
  let model = try await pendingNativeModel(fixture)
  try await model.flushInputAndPersistence()
  let active = try #require(model.draft)
  await model.restore(stale)
  #expect(model.failure != nil)
  #expect(model.draft?.draftID == active.draftID)
  #expect(model.stagedItems.count == 1)
  #expect(model.editorText == "Retain this synthetic draft. [source: fixture; added: 2026-10-17]")
  #expect(model.retainedDraft?.draftID == stale.draftID)
  try await model.shutdown()
}

@Test @MainActor func nativeEmptyPreparedWorkspaceDoesNotBlockSettingsSave() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let base = try fixture.main()
  let model = AppModel(configURL: url)
  model.section = "Memories"
  await model.load()
  await model.pauseQueue()
  try #require(model.failure == nil)
  _ = try #require(model.batchProjection)
  try #require(model.stagedItems.isEmpty)
  try #require(!model.isInputDirty)
  let diagnostics = fixture.root.appendingPathComponent("changed-diagnostics").path
  model.configuration.diagnostics = diagnostics
  await model.saveSettings()
  #expect(model.failure == nil)
  #expect(try MemoryConfiguration.load(from: url).diagnostics == diagnostics)
  #expect(try fixture.main() == base)
  try await model.shutdown()
}

@Test @MainActor func nativeSettingsWaitForFinalRemovalPersistenceAndRetainFailedRequests()
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let control = NativePersistenceControl()
  let model = try await pendingNativeModel(
    fixture, persistence: NativeBatchPersistence(write: control.write))
  try await model.flushInputAndPersistence()
  let base = try fixture.main()
  await model.removeItem(try #require(model.stagedItems.first).itemID)
  try #require(model.stagedItems.isEmpty)
  try #require(!model.isInputDirty)
  try #require(model.isDraftDirty)
  await control.failInstalledWrite()
  let diagnostics = fixture.root.appendingPathComponent("changed-diagnostics").path
  model.configuration.diagnostics = diagnostics
  await model.saveSettings()
  #expect(model.failure != nil)
  #expect(model.isDraftDirty)
  #expect(try MemoryConfiguration.load(from: model.configURL).diagnostics != diagnostics)
  let failed = try #require(await control.requests.last)
  await control.resumeWrites()
  model.failure = nil
  await model.saveSettings()
  #expect(model.failure == nil)
  #expect(try MemoryConfiguration.load(from: model.configURL).diagnostics == diagnostics)
  let retried = try #require(await control.requests.last)
  #expect(try memoryBatchDigest(failed) == memoryBatchDigest(retried))
  #expect(try fixture.main() == base)
  try await model.shutdown()
}

@Test @MainActor func nativeSettingsCannotRedirectAnEditDuringInitialDebounce() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let model = try await pendingNativeModel(fixture)
  let other = fixture.root.appendingPathComponent("other-memory")
  try FileManager.default.copyItem(at: fixture.memory, to: other)
  model.configuration.roots?.memory = other.path
  model.configuration.journal = fixture.root.appendingPathComponent("other-journal").path
  await model.saveSettings()
  #expect(model.failure?.contains("Save or discard local edits") == true)
  #expect(try MemoryConfiguration.load(from: model.configURL).memoryURL.path == fixture.memory.path)
  try await model.shutdown()
  let reopened = AppModel(configURL: model.configURL)
  await reopened.load()
  #expect(reopened.stagedItems.count == 1)
  #expect(reopened.configuration.memoryURL.path == fixture.memory.path)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.root.appendingPathComponent("other-journal").path))
  try await reopened.shutdown()
}
