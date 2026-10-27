import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

private func retainedNativeReviewSave(
  _ fixture: TransactionFixture, isDecisionOnly: Bool = false
) async throws -> (url: URL, draft: MemoryDraft, rootBytes: Data) {
  try fixture.write(
    "# Memory\n\n" + fact("Existing mutable memory."),
    file: fixture.memory.appendingPathComponent("MEMORY.md"))
  _ = try Git(repo: fixture.memory, environment: [:]).data(["add", "MEMORY.md"])
  try fixture.advance()
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
  let draft = try await workspace.persistBatch().draft
  let result = try await workspace.saveBatch()
  switch result {
  case .saved: #expect(!isDecisionOnly)
  case .decisionsSaved: #expect(isDecisionOnly)
  default: throw MemoryError("Expected a checked synthetic Save")
  }
  _ = await workspace.closeBatch()
  let root = fixture.state.appendingPathComponent("root.json")
  let bytes = try Data(contentsOf: root)
  try FileManager.default.removeItem(at: root)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  return (url, draft, bytes)
}

@Test func nativeNilReviewBindingTransitionsOnlyOnExplicitMixedStagingAndUndoKeepsScope()
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let workspace = Workspace(configURL: url)
  _ = try await workspace.load()
  let opened = try await workspace.openBatch()
  _ = try await workspace.batch(
    .manual(
      MemoryManagementRequest(
        operation: .add, base: opened.draft.baseCommit, path: "MEMORY.md",
        replacement: fact("Manual intent with nil review metadata."), reason: "Requested"), nil))
  let manual = try await workspace.persistBatch().draft
  _ = await workspace.closeBatch()
  try fixture.populate()
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let manager = try MemoryManagement(repository: fixture.memory)
  try manager.confirmDetach(manager.checkoutPreview())
  let restored = try await workspace.restoreBatch(manual)
  #expect(restored.draft.batch?.binding.reviewBinding == nil)
  let candidate = try #require(restored.candidates.first)
  let shown = try #require(
    try await workspace.batch(.acceptance(candidate.change.id)).presentation)
  #expect(try await workspace.openBatch().draft.batch?.binding.reviewBinding == nil)
  let mixed = try await workspace.batch(.stage(shown)).projection
  #expect(mixed.draft.batch?.binding.reviewBinding != nil)
  let path = "projects/\(String(repeating: "c", count: 64)).md"
  _ = try await workspace.batch(.path(path))
  let undone = try await workspace.batch(.undo).projection
  #expect(undone.draft.batch?.binding.reviewBinding == nil)
  #expect(undone.draft.batch?.items.count == 1)
  #expect(undone.draft.batch?.binding.preparedPaths == [path])
  do {
    _ = try await workspace.batch(.stage(shown))
    Issue.record("Undo must not restore the old presentation")
  } catch {}
  let fresh = try #require(
    try await workspace.batch(.acceptance(candidate.change.id)).presentation)
  _ = try await workspace.batch(.stage(fresh))
  let base = try fixture.main()
  guard case .saved(let receipt) = try await workspace.saveBatch(), let commit = receipt.commit
  else { throw MemoryError("Expected one complete mixed Save") }
  #expect(
    try Git(repo: fixture.memory, environment: [:]).text([
      "rev-list", "--count", "\(base)..\(commit)",
    ]) == "1")
  let saved = try MemoryStore(repo: fixture.memory).reviewSnapshot(base: commit)
  #expect(
    saved.reviewEntries().contains {
      $0.entry.bytes.range(of: Data("Manual intent with nil".utf8)) != nil
    })
  #expect(
    saved.reviewEntries().contains { $0.entry.bytes.range(of: fresh.after) != nil })
}

@Test func nativeNewIndependentManualBatchPreservesPendingHistoryAcrossEmptyRefresh() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let retained = try await retainedNativeReviewSave(fixture, isDecisionOnly: true)
  let configuration = try MemoryConfiguration.load(from: retained.url)
  let journal = URL(fileURLWithPath: configuration.journal)
  let workspace = Workspace(configURL: retained.url)
  let snapshot = try await workspace.load()
  #expect(snapshot.drafts.isEmpty)
  #expect(snapshot.draftRecoveries.count == 1)
  let before = try fixture.snapshot(journal)
  do {
    _ = try await workspace.openBatch()
    Issue.record("Pending history must not create an automatic draft")
  } catch {}
  #expect(try fixture.snapshot(journal) == before)
  let opened = try await workspace.startIndependentManualBatch()
  #expect(opened.draft.draftID != retained.draft.draftID)
  #expect(opened.draft.batch?.items.isEmpty == true)
  let path = "projects/\(String(repeating: "d", count: 64)).md"
  let prepared = try await workspace.batch(.path(path)).projection
  let refreshed = try await workspace.reprepareBatch()
  #expect(try memoryBatchDigest(refreshed.draft) == memoryBatchDigest(prepared.draft))
  #expect(refreshed.draft.batch?.binding.preparedPaths == [path])
  let entry = try #require(refreshed.entries.first { $0.isMutable })
  do {
    _ = try await workspace.batch(.reviewed(entry))
    Issue.record("Pending history must block native Confirm Reviewed")
  } catch {}
  _ = try await workspace.batch(
    .manual(
      MemoryManagementRequest(
        operation: .add, base: opened.draft.baseCommit, path: path,
        replacement: fact("Independent project intent."), reason: "Requested"), nil))
  let manual = try await workspace.persistBatch().draft
  let restored = try await workspace.restoreBatch(manual)
  #expect(restored.draft.draftID == manual.draftID)
  #expect(await workspace.draftRecoveries.count == 1)
  guard case .saved = try await workspace.saveBatch() else {
    throw MemoryError("Expected independent manual Save")
  }
  let after = try fixture.snapshot(journal)
  for (path, bytes) in before { #expect(after[path] == bytes) }
}

@Test @MainActor
func nativeRecoverySelectionIsReadOnlyAndAcknowledgedManualCreationReleasesDetails()
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let retained = try await retainedNativeReviewSave(fixture)
  let model = AppModel(configURL: retained.url, autosaveDelay: .seconds(3600))
  await model.load()
  await model.pauseQueue()
  #expect(
    model.failure == nil, "Unavailable dream details must not report a failed memory operation")
  #expect(model.dreamInspectionFailure != nil)
  #expect(model.catalog != nil)
  model.section = "Memories"
  await model.loadCandidates()
  #expect(model.failure == nil, "Pending recovery requires explicit selection, not a failure sheet")
  #expect(model.isWaitingForIndependentManualWork)
  #expect(!model.isWorkspaceLoaded)
  let descriptor = try #require(model.draftRecoveries.first)
  #expect(model.batchProjection == nil)
  #expect(model.retainedDraft == nil)
  let journal = URL(fileURLWithPath: model.configuration.journal)
  let before = try fixture.snapshot(journal)
  let base = try fixture.main()
  await model.selectMemory(.recovery(descriptor.failure.saveID))
  #expect(
    try model.draftRecoveryDetails.map(memoryBatchDigest) == memoryBatchDigest(retained.draft))
  #expect(model.batchProjection == nil)
  #expect(await model.workspace.currentDraft == nil)
  #expect(!model.isSaveEnabled)
  #expect(try fixture.snapshot(journal) == before)
  model.isConfirmingIndependentManual = true
  model.isConfirmingIndependentManual = false
  #expect(try fixture.snapshot(journal) == before)
  #expect(model.batchProjection == nil)
  await model.selectMemory(nil)
  #expect(model.draftRecoveryDetails == nil)
  await model.selectMemory(.recovery(descriptor.failure.saveID))
  await model.refresh()
  await model.pauseQueue()
  #expect(model.failure == nil, "Refreshing recovery history must remain a read-only waiting state")
  #expect(model.draftRecoveryDetails == nil)
  #expect(model.selection == nil)
  #expect(try fixture.snapshot(journal) == before)
  await model.selectMemory(.recovery(descriptor.failure.saveID))
  model.isConfirmingIndependentManual = true
  await model.startIndependentManualBatch()
  #expect(model.batchProjection != nil)
  #expect(model.draft?.draftID != retained.draft.draftID)
  #expect(model.draftRecoveryDetails == nil)
  #expect(model.draftRecoveries.count == 1)
  #expect(!model.isReviewTransitionEnabled)
  await model.add()
  model.editorText = fact("Explicit independent native manual work.")
  model.editorReason = "Requested"
  model.editorChanged()
  await model.save()
  #expect(try fixture.main() != base)
  #expect(model.stagedItems.isEmpty)
  #expect(
    model.failure == nil,
    "A successful independent Save must not report post-save waiting as failure")
  #expect(model.message == "Saved changes in one commit")
  #expect(model.isWaitingForIndependentManualWork)
  #expect(!model.isWorkspaceLoaded)
  #expect(await model.workspace.currentDraft == nil)
  let after = try fixture.snapshot(journal)
  for (path, bytes) in before { #expect(after[path] == bytes) }
  try await model.shutdown()
}

@Test @MainActor func nativeSaveDoesNotLoseInputDeliveredDuringFinalPersistence() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let retained = try await retainedNativeReviewSave(fixture)
  let control = NativePersistenceControl()
  let model = AppModel(
    configURL: retained.url, autosaveDelay: .seconds(3600),
    persistence: NativeBatchPersistence(write: control.write))
  await model.load()
  await model.pauseQueue()
  await model.startIndependentManualBatch()
  await model.add()
  let initialRequestCount = await control.requests.count
  await control.pauseWrites()
  let owner = try #require(model.editorOwner)
  model.setEditorText(fact("Initial input before final persistence."), owner: owner)
  model.setEditorReason("Initial reason", owner: owner)
  let save = Task { await model.save() }
  let completion = Task {
    await save.value
    await control.pauseOperationCompleted()
  }
  let newerText = fact("Newer exact input delivered during final persistence.")
  let newerReason = "Newer exact reason"
  do {
    let isHeld = await control.isWritePaused(after: initialRequestCount)
    try #require(isHeld)
    try #require(await control.requests.count == initialRequestCount + 1)
    try #require(model.isBusy)
    model.setEditorText(newerText, owner: owner)
    model.setEditorReason(newerReason, owner: owner)
    await model.stageEditor()
    #expect(model.isBusy, "Stage Edit must not compete with final Save")
    await control.resumeWrites()
    await save.value
    await completion.value
  } catch {
    await control.resumeWrites()
    await save.value
    await completion.value
    throw error
  }
  guard case .saved(let receipt) = model.saveOutcome, let commit = receipt.commit else {
    throw MemoryError("Expected actual independent manual publication")
  }
  #expect(commit == (try fixture.main()))
  let published = try MemoryStore(repo: fixture.memory).reviewSnapshot(base: commit)
  let isNewerPublished = published.reviewEntries().contains {
    $0.entry.bytes.range(of: Data("Newer exact input delivered during final persistence.".utf8))
      != nil
  }
  let manifest = try MemoryBatchReplay.read(
    commit, git: Git(repo: fixture.memory, environment: [:]))
  let isNewerSubmitted =
    manifest.draft.batch?.items.contains { item in
      guard case .manual(let intent) = item.intent else { return false }
      return intent.request.replacement == newerText && intent.request.reason == newerReason
    } == true
  let isNewerRetained =
    model.isInputDirty && model.editorText == newerText && model.editorReason == newerReason
  #expect(
    (isNewerPublished && isNewerSubmitted) || isNewerRetained,
    "Input delivered during final persistence must be published exactly or retained for Discard")
  if isNewerPublished && isNewerSubmitted {
    let revision = model.inputRevision
    model.setEditorText(newerText, owner: owner)
    model.setEditorReason(newerReason, owner: owner)
    #expect(model.inputRevision == revision)
    #expect(!model.isInputDirty)
    #expect(model.editorText.isEmpty)
    #expect(model.editorReason.isEmpty)
    #expect(model.autosaveTask == nil)
    let lateText = fact("Late exact text from the consumed editor.")
    model.setEditorText(lateText, owner: owner)
    model.setEditorReason("Late exact reason", owner: owner)
    #expect(model.isRetainingConsumedInput)
    #expect(model.editorText == lateText)
    #expect(model.editorReason == "Late exact reason")
    #expect(model.isDiscardEnabled)
    #expect(model.autosaveTask == nil)
    await model.discard()
    #expect(!model.isInputDirty)
    #expect(try fixture.main() == commit)
  }
  if isNewerRetained {
    #expect(model.isDiscardEnabled)
    await model.discard()
    #expect(!model.isInputDirty)
    #expect(model.editorText.isEmpty)
    #expect(model.editorReason.isEmpty)
    #expect(try fixture.main() == commit)
  }
  try await model.shutdown()
}

@Test @MainActor func nativeConsumedSaveRetainsNewerInputUntilLocalDiscard() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let retained = try await retainedNativeReviewSave(fixture)
  let model = AppModel(configURL: retained.url, autosaveDelay: .seconds(3600))
  await model.load()
  await model.pauseQueue()
  await model.startIndependentManualBatch()
  await model.add()
  let owner = try #require(model.editorOwner)
  let submittedText = fact("Only this submitted input is published.")
  model.setEditorText(submittedText, owner: owner)
  model.setEditorReason("Submitted reason", owner: owner)
  await model.workspace.failNativePublicationBookkeeping(isFailing: true)
  await model.save()
  try #require(model.isSaveUnresolved)
  let submitted = try #require(model.submittedInput)
  let published = try fixture.main()
  let newerText = fact("Retain this exact unsubmitted input.\nKeep this second line.")
  let newerReason = "Retain this exact unsubmitted reason"
  model.setEditorText(newerText, owner: owner)
  model.setEditorReason(newerReason, owner: owner)
  await model.workspace.failNativePublicationBookkeeping(isFailing: false)
  await model.recoverSave()
  try #require(!model.isSaveUnresolved)
  #expect(model.submittedInput?.revision == submitted.revision)
  #expect(model.submittedInput?.text == submittedText)
  #expect(model.message == "Saved changes in one commit")
  #expect(model.draftFailure == nil)
  #expect(model.isRetainingConsumedInput)
  #expect(model.isInputDirty)
  #expect(model.editorText == newerText)
  #expect(model.editorReason == newerReason)
  let revision = model.inputRevision
  model.setEditorText(submittedText, owner: owner)
  model.setEditorReason("Submitted reason", owner: owner)
  #expect(model.inputRevision == revision)
  #expect(model.editorText == newerText)
  #expect(model.editorReason == newerReason)
  #expect(model.editorPath == "MEMORY.md")
  #expect(model.isEditing)
  #expect(model.isDiscardEnabled)
  #expect(!model.isSaveEnabled)
  #expect(model.autosaveTask == nil)
  #expect(await !model.workspace.isNativeBatchOpen)
  let manifest = try MemoryBatchReplay.read(
    published, git: Git(repo: fixture.memory, environment: [:]))
  guard case .manual(let intent) = manifest.draft.batch?.items.first?.intent else {
    throw MemoryError("Expected the submitted manual publication")
  }
  #expect(intent.request.replacement == submittedText)
  #expect(intent.request.reason == "Submitted reason")
  let journal = URL(fileURLWithPath: model.configuration.journal)
  let before = try fixture.snapshot(journal)
  let selection = model.selection
  await model.selectMemory(nil)
  #expect(model.selection == selection)
  await model.add()
  await model.startIndependentManualBatch()
  await model.restore(retained.draft)
  #expect(model.retainedDraft == nil)
  await model.stageEditor()
  await model.saveSettings()
  await #expect(throws: NativeBatchLifecycleError.self) { try await model.shutdown() }
  await #expect(throws: NativeBatchLifecycleError.self) {
    _ = try await model.workspace.batch(.path("MEMORY.md"), expectedDraftID: owner.draft.draftID)
  }
  await #expect(throws: NativeBatchLifecycleError.self) {
    _ = try await model.workspace.persistBatch(expectedDraftID: owner.draft.draftID)
  }
  await #expect(throws: NativeBatchLifecycleError.self) {
    _ = try await model.workspace.saveBatch(expectedDraftID: owner.draft.draftID)
  }
  await model.refresh()
  await model.pauseQueue()
  await model.loadCandidates()
  #expect(model.editorText == newerText)
  #expect(model.editorReason == newerReason)
  #expect(model.selection == selection)
  #expect(model.batchProjection == nil)
  #expect(await !model.workspace.isNativeBatchOpen)
  #expect(await model.workspace.currentDraft == nil)
  #expect(await model.workspace.pendingPersistence == nil)
  #expect(try fixture.snapshot(journal) == before)
  #expect(try fixture.main() == published)
  await model.discard()
  #expect(!model.isInputDirty)
  #expect(!model.isEditing)
  #expect(model.editorText.isEmpty)
  #expect(model.editorReason.isEmpty)
  #expect(!model.isDiscardEnabled)
  #expect(try fixture.snapshot(journal) == before)
  #expect(model.draftRecoveries.count == 1)
  await model.startIndependentManualBatch()
  let replacement = try #require(model.draft)
  #expect(replacement.draftID != owner.draft.draftID)
  await #expect(throws: NativeBatchLifecycleError.self) {
    _ = try await model.workspace.batch(.path("MEMORY.md"), expectedDraftID: owner.draft.draftID)
  }
  await #expect(throws: NativeBatchLifecycleError.self) {
    _ = try await model.workspace.persistBatch(expectedDraftID: owner.draft.draftID)
  }
  #expect(await model.workspace.currentDraft?.draftID == replacement.draftID)
  #expect(await model.workspace.pendingPersistence == nil)
  model.setEditorText("Stale delivery must not mutate the new draft", owner: owner)
  #expect(model.editorText.isEmpty)
  await model.add()
  #expect(model.isEditing)
  try await model.shutdown()
}

@Test(arguments: [false, true])
@MainActor func nativeAutosaveFailureAfterSimulatedSaveKeepsSettledFeedback(isAfterInstall: Bool)
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let retained = try await retainedNativeReviewSave(fixture)
  let control = NativePersistenceControl()
  let model = AppModel(
    configURL: retained.url, autosaveDelay: .zero,
    persistence: NativeBatchPersistence(write: control.write))
  await model.load()
  await model.pauseQueue()
  let journal = URL(fileURLWithPath: model.configuration.journal)
  let recoveryBefore = try fixture.snapshot(journal)
  let base = try fixture.main()
  await model.startIndependentManualBatch()
  await model.add()
  let initialRequestCount = await control.requests.count
  await control.pauseWrites()
  model.editorText = fact("Autosave owned by the retiring manual batch.")
  model.editorReason = "Retain the original request"
  model.editorChanged()
  let autosave = try #require(model.autosaveTask)
  let deadline = ContinuousClock.now + .seconds(5)
  while await control.requests.count == initialRequestCount && ContinuousClock.now < deadline {
    await Task.yield()
  }
  try #require(await control.requests.count == initialRequestCount + 1)
  let pending = try #require(await model.workspace.pendingPersistence)
  let generation = model.workspaceGeneration
  let saveID = try memoryBatchDigest(pending.request.draft)
  let receipt = MemoryBatchReceipt(
    saveID: saveID, draftID: pending.request.draft.draftID,
    revision: pending.request.draft.revision, base: pending.request.draft.baseCommit,
    commit: nil, auditRef: nil)
  await model.handleSave(.saved(receipt))
  try #require(model.workspaceGeneration != generation)
  try #require(model.message == "Saved changes in one commit")
  try #require(model.draftFailure == nil)
  await control.resumeWrites(
    isFailing: !isAfterInstall, isFailingAfterInstall: isAfterInstall)
  await autosave.value
  #expect(
    model.message == "Saved changes in one commit",
    "A retired autosave must not repaint successful Save feedback")
  #expect(model.draftFailure == nil, "A retired autosave must not attach a stale draft failure")
  #expect(model.failure == nil)
  #expect(model.batchProjection == nil)
  #expect(model.isWaitingForIndependentManualWork)
  #expect(model.draftRecoveries.map(\.failure.saveID) == [try memoryBatchDigest(retained.draft)])
  #expect(await model.workspace.currentDraft?.draftID == pending.request.draft.draftID)
  let failed = try #require(await model.workspace.pendingPersistence)
  #expect(failed.id == pending.id)
  #expect(failed.task == nil)
  #expect(failed.request.sessionID == pending.request.sessionID)
  #expect(failed.request.expectedDigest == pending.request.expectedDigest)
  #expect(try memoryBatchDigest(failed.request.draft) == saveID)
  await control.resumeWrites()
  _ = try await model.workspace.persistBatch()
  let requests = Array(await control.requests.dropFirst(initialRequestCount))
  try #require(requests.count == 2)
  #expect(try memoryBatchDigest(requests[0]) == memoryBatchDigest(requests[1]))
  #expect(await model.workspace.pendingPersistence == nil)
  #expect(await model.workspace.currentDraft?.draftID == pending.request.draft.draftID)
  #expect(try fixture.main() == base, "The simulated Save must not claim core publication")
  let after = try fixture.snapshot(journal)
  for (path, bytes) in recoveryBefore { #expect(after[path] == bytes) }
  try await model.shutdown()
}

@Test(arguments: [false, true])
@MainActor
func nativeAutosaveCurrentOwnerFailureRetainsNewerInputAndExactRetry(isAfterInstall: Bool)
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let retained = try await retainedNativeReviewSave(fixture)
  let control = NativePersistenceControl()
  let model = AppModel(
    configURL: retained.url, autosaveDelay: .zero,
    persistence: NativeBatchPersistence(write: control.write))
  await model.load()
  await model.pauseQueue()
  let journal = URL(fileURLWithPath: model.configuration.journal)
  let recoveryBefore = try fixture.snapshot(journal)
  await model.startIndependentManualBatch()
  await model.add()
  let initialRequestCount = await control.requests.count
  await control.pauseWrites()
  model.editorText = fact("First unacknowledged autosave request.")
  model.editorReason = "First reason"
  model.editorChanged()
  let autosave = try #require(model.autosaveTask)
  let deadline = ContinuousClock.now + .seconds(5)
  while await control.requests.count == initialRequestCount && ContinuousClock.now < deadline {
    await Task.yield()
  }
  try #require(await control.requests.count == initialRequestCount + 1)
  let pending = try #require(await model.workspace.pendingPersistence)
  model.editorText = fact("Newer exact text while the first request is held.")
  model.editorReason = "Newer exact reason"
  model.editorChanged()
  let newerAutosave = try #require(model.autosaveTask)
  newerAutosave.cancel()
  await control.resumeWrites(
    isFailing: !isAfterInstall, isFailingAfterInstall: isAfterInstall)
  await autosave.value
  await newerAutosave.value
  #expect(model.draftFailure != nil, "Cancellation does not acknowledge a current owner's failure")
  #expect(model.message == "Draft not yet persisted")
  #expect(model.failure == nil)
  #expect(model.isInputDirty)
  #expect(model.isDraftDirty)
  #expect(model.editorText == fact("Newer exact text while the first request is held."))
  #expect(model.editorReason == "Newer exact reason")
  let failed = try #require(await model.workspace.pendingPersistence)
  #expect(failed.id == pending.id)
  #expect(failed.task == nil)
  #expect(failed.request.sessionID == pending.request.sessionID)
  #expect(failed.request.expectedDigest == pending.request.expectedDigest)
  #expect(try memoryBatchDigest(failed.request.draft) == memoryBatchDigest(pending.request.draft))
  await control.resumeWrites()
  try await model.flushInputAndPersistence()
  let requests = Array(await control.requests.dropFirst(initialRequestCount))
  try #require(requests.count == 3)
  #expect(try memoryBatchDigest(requests[0]) == memoryBatchDigest(requests[1]))
  #expect(requests[2].revision > requests[1].revision)
  #expect(Set(requests.map(\.draftID)) == [pending.request.draft.draftID])
  guard case .manual(let latest) = requests[2].batch?.items.first?.intent else {
    throw MemoryError("Expected retained newer manual input")
  }
  #expect(latest.request.replacement == model.editorText)
  #expect(latest.request.reason == model.editorReason)
  #expect(await control.maximumInFlight == 1)
  #expect(await model.workspace.pendingPersistence == nil)
  #expect(!model.isDraftDirty)
  #expect(model.draftFailure == nil)
  #expect(model.draftRecoveries.map(\.failure.saveID) == [try memoryBatchDigest(retained.draft)])
  let after = try fixture.snapshot(journal)
  for (path, bytes) in recoveryBefore { #expect(after[path] == bytes) }
  try await model.shutdown()
}

@Test(arguments: ["unloaded", "missing", "corrupt", "changed"])
@MainActor func nativeIndependentManualCreationFailsClosedBeforeCachedInputPersists(variant: String)
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let model = try await pendingNativeModel(fixture)
  await model.pauseQueue()
  if variant == "unloaded" {
    model.isLoaded = false
    _ = await model.workspace.closeBatch()
  } else if variant == "changed" {
    var changed = model.configuration
    changed.journal = fixture.root.appendingPathComponent("trap-journal").path
    try changed.save(to: model.configURL)
  } else {
    try FileManager.default.removeItem(at: model.configURL)
    if variant == "corrupt" { try fixture.write("{", file: model.configURL) }
  }
  let before = try fixture.snapshot(fixture.root)
  let input = model.editorText
  await model.startIndependentManualBatch()
  #expect(try fixture.snapshot(fixture.root) == before)
  #expect(model.isInputDirty)
  #expect(model.editorText == input)
  if variant != "unloaded" { #expect(model.failure != nil) }
  let unloaded = Workspace(configURL: model.configURL)
  do {
    _ = try await unloaded.startIndependentManualBatch()
    Issue.record("Workspace must not use its default profile before load")
  } catch {}
  #expect(try fixture.snapshot(fixture.root) == before)
  model.autosaveTask?.cancel()
  await model.autosaveTask?.value
}

@Test func nativePendingHistoryRejectsActiveAndUnconsumedMixedSwitchesWithoutSubsetSave()
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let retained = try await retainedNativeReviewSave(fixture)
  let configuration = try MemoryConfiguration.load(from: retained.url)
  let workspace = Workspace(configURL: retained.url)
  _ = try await workspace.load()
  let opened = try await workspace.startIndependentManualBatch()
  _ = try await workspace.batch(
    .manual(
      MemoryManagementRequest(
        operation: .add, base: opened.draft.baseCommit, path: "MEMORY.md",
        replacement: fact("Keep active manual intent."), reason: "Requested"), nil))
  let manual = try await workspace.persistBatch().draft
  let journal = URL(fileURLWithPath: configuration.journal)
  let drafts = try MemoryDraftStore(repository: fixture.memory, journal: journal)
  let other = try drafts.create()
  let before = try fixture.snapshot(journal)
  do {
    _ = try await workspace.startIndependentManualBatch()
    Issue.record("Nonempty active intent must not be abandoned")
  } catch {}
  do {
    _ = try await workspace.restoreBatch(other)
    Issue.record("A different active manual draft must block switching")
  } catch {}
  #expect(try await workspace.openBatch().draft.draftID == manual.draftID)
  #expect(try fixture.snapshot(journal) == before)
  _ = await workspace.closeBatch()
  let root = fixture.state.appendingPathComponent("root.json")
  try FileManager.default.removeItem(at: root)
  try retained.rootBytes.write(to: root)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.path)
  let healthy = Workspace(configURL: retained.url)
  _ = try await healthy.load()
  let restored = try await healthy.restoreBatch(manual)
  #expect(await healthy.draftRecoveries.isEmpty)
  #expect(await healthy.reviewPreparationFailure == nil)
  let entry = try #require(restored.entries.first { $0.isMutable })
  let shown = try #require(try await healthy.batch(.reviewed(entry)).presentation)
  _ = try await healthy.batch(.stage(shown))
  let mixed = try await healthy.persistBatch().draft
  try FileManager.default.removeItem(at: root)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let beforeBlockedSave = try fixture.main()
  do {
    _ = try await healthy.saveBatch()
    Issue.record("Fresh history inspection must block the entire mixed Save")
  } catch {}
  #expect(try fixture.main() == beforeBlockedSave)
  _ = await healthy.closeBatch()
  let blocked = Workspace(configURL: retained.url)
  _ = try await blocked.load()
  let mixedBytes = try Data(
    contentsOf: journal.appendingPathComponent("\(mixed.draftID)-current.json"))
  let base = try fixture.main()
  for action in 0..<3 {
    do {
      if action == 0 { _ = try await blocked.startIndependentManualBatch() }
      if action == 1 { _ = try await blocked.restoreBatch(other) }
      if action == 2 { _ = try await blocked.restoreBatch(mixed) }
      Issue.record("Unconsumed mixed intent must block independent manual selection")
    } catch {}
  }
  #expect(try fixture.main() == base)
  #expect(
    try Data(contentsOf: journal.appendingPathComponent("\(mixed.draftID)-current.json"))
      == mixedBytes)
}

@Test func recoveryInspectionKeepsStrictReceiptsAndRequiresExactDetailsDigest() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let drafts = try MemoryDraftStore(
    repository: fixture.repo, journal: memoryBatchTestJournal(fixture.root))
  let session = try MemoryBatchSession(repository: fixture.repo, drafts: drafts)
  try session.stageManual(
    MemoryManagementRequest(
      operation: .add, base: session.draft.baseCommit, path: "MEMORY.md",
      replacement: fact("Unpublished intent."), reason: "Requested"))
  let draft = session.draft
  try drafts.persistBatch(draft, expectedRevision: 0)
  let saveID = try memoryBatchDigest(draft)
  let name = "batch-receipt-\(saveID).json"
  let receipt = MemoryBatchReceipt(
    saveID: saveID, draftID: draft.draftID, revision: draft.revision, base: draft.baseCommit,
    commit: draft.baseCommit, auditRef: "refs/memory-batches/\(saveID)")
  try drafts.root.installReviewFile(MemoryReviewEncoding.encode(receipt), name: name)
  #expect(throws: MemoryBatchRecoveryRequired.self) { try drafts.list() }
  let inspection = try drafts.inspectDrafts()
  #expect(inspection.drafts.isEmpty)
  let descriptor = try #require(inspection.recoveryRequired.first)
  #expect(try memoryBatchDigest(drafts.recoveryDetails(descriptor)) == saveID)
  let forged = MemoryDraftRecovery(
    draftID: descriptor.draftID, revision: descriptor.revision, created: descriptor.created,
    failure: MemoryBatchRecoveryRequired(
      saveID: String(repeating: "0", count: 64), details: "Synthetic"))
  #expect(throws: (any Error).self) { try drafts.recoveryDetails(forged) }
  let changed = MemoryDraft(
    schemaVersion: draft.schemaVersion, draftID: draft.draftID, revision: draft.revision,
    repositoryBinding: draft.repositoryBinding, baseCommit: draft.baseCommit,
    created: draft.created.addingTimeInterval(1), operations: draft.operations, batch: draft.batch)
  let current = "\(draft.draftID)-current.json"
  try drafts.root.installReviewFile(
    MemoryReviewEncoding.encode(changed), name: current, isReplacing: true)
  #expect(throws: (any Error).self) { try drafts.recoveryDetails(descriptor) }
  try drafts.root.installReviewFile(
    MemoryReviewEncoding.encode(draft), name: current, isReplacing: true)
  let malformed = MemoryBatchReceipt(
    saveID: saveID, draftID: UUID(), revision: draft.revision, base: draft.baseCommit,
    commit: draft.baseCommit, auditRef: receipt.auditRef)
  try drafts.root.installReviewFile(
    MemoryReviewEncoding.encode(malformed), name: name, isReplacing: true)
  #expect(throws: (any Error).self) { try drafts.inspectDrafts() }
  #expect(try fixture.store.approvedCommit() == draft.baseCommit)
}

@Test(arguments: [false, true])
func memoryBatchInitialInstallRetainsExistingFaultContract(isAfterInstall: Bool) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let drafts = try MemoryDraftStore(
    repository: fixture.repo, journal: memoryBatchTestJournal(fixture.root))
  var isObserved = false
  drafts.batchPersistenceFault = { event in
    switch event {
    case .beforeInstall(let name) where !isAfterInstall && name.hasSuffix("-current.json"),
      .afterInstall(let name) where isAfterInstall && name.hasSuffix("-current.json"):
      isObserved = true
      throw MemoryError("Synthetic initial installation fault")
    default: break
    }
  }
  #expect(throws: (any Error).self) {
    try MemoryBatchSession(repository: fixture.repo, drafts: drafts)
  }
  #expect(isObserved)
  let retained = try drafts.list()
  #expect(retained.count == (isAfterInstall ? 1 : 0))
  #expect(
    retained.allSatisfy { $0.schemaVersion == 1 && $0.revision == 0 && $0.operations.isEmpty })
}
