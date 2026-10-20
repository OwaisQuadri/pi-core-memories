import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

actor NativePersistenceControl {
  private(set) var requests: [MemoryDraft] = []
  private(set) var maximumInFlight = 0
  private var inFlight = 0
  private var isFailing = false
  private var isFailingAfterInstall = false
  private var isPaused = false
  private var release: CheckedContinuation<Void, Never>?

  func failWrites() { isFailing = true }
  func failInstalledWrite() { isFailingAfterInstall = true }
  func pauseWrites() { isPaused = true }
  func resumeWrites(isFailing: Bool = false, isFailingAfterInstall: Bool = false) {
    self.isFailing = isFailing
    self.isFailingAfterInstall = isFailingAfterInstall
    isPaused = false
    release?.resume()
    release = nil
  }

  func write(_ request: MemoryBatchPersistenceRequest, repository: URL, journal: URL) async throws
    -> MemoryBatchPersistenceReceipt
  {
    requests.append(request.draft)
    inFlight += 1
    maximumInFlight = max(maximumInFlight, inFlight)
    defer { inFlight -= 1 }
    guard inFlight == 1 else { throw MemoryError("Concurrent native persistence") }
    if isPaused { await withCheckedContinuation { release = $0 } }
    if isFailing { throw MemoryError("Synthetic persistence failure") }
    let store = try MemoryDraftStore(repository: repository, journal: journal)
    if isFailingAfterInstall {
      store.batchPersistenceFault = { event in
        if event == .afterInstall("\(request.draft.draftID)-current.json") {
          throw MemoryError("Synthetic lost acknowledgment")
        }
      }
    }
    return try store.persistBatch(request)
  }
}

extension Workspace {
  var isNativeBatchOpen: Bool { session != nil }

  func observeNativeHistory(_ counter: MemoryBatchInteractionCount) {
    review?.batchHistoryObserver = { counter.increment() }
  }

  func failNativePublicationBookkeeping(isFailing: Bool) {
    draftStore?.batchPersistenceFault =
      isFailing
      ? { event in
        if event == .afterPublication { throw MemoryError("Synthetic interruption") }
      } : nil
  }
}

@MainActor private func nativeReviewModel(_ fixture: ReviewFlowFixture) async throws -> AppModel {
  let model = AppModel(configURL: fixture.configurationURL, autosaveDelay: .seconds(3600))
  model.section = "Memories"
  await model.load()
  #expect(model.failure == nil)
  return model
}

@Test @MainActor func nativeConsumedInputKeepsParkedDraftHistoryIsolated() async throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = try await nativeReviewModel(fixture)
  await model.add()
  let owner = try #require(model.editorOwner)
  let journal = URL(fileURLWithPath: model.configuration.journal)
  let store = try MemoryDraftStore(repository: fixture.transaction.memory, journal: journal)
  let parkedSession = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: store,
    configurationURL: fixture.configurationURL,
    allowedPaths: try #require(model.draft?.batch?.binding.allowedPaths))
  try parkedSession.stageManual(
    MemoryManagementRequest(
      operation: .add, base: parkedSession.persistenceSnapshot.baseCommit, path: "MEMORY.md",
      replacement: fact("Parked draft B must remain available history."),
      reason: "Parked B reason"))
  _ = try store.persistBatch(parkedSession.persistenceRequest)
  let parked = parkedSession.persistenceSnapshot
  let parkedDigest = try memoryBatchDigest(parked)
  let parkedCurrent = journal.appendingPathComponent("\(parked.draftID)-current.json")
  let parkedBytes = try Data(contentsOf: parkedCurrent)
  let available = await model.workspace.refresh()
  try #require(available.draftRecoveries.isEmpty)
  try #require(available.drafts.contains { $0.draftID == parked.draftID })
  try #require(parked.schemaVersion == 2 && parked.batch?.isManualOnly == true)
  try #require(parked.draftID != owner.draft.draftID)
  let base = try fixture.transaction.main()
  let submittedText = fact("Submitted draft A.")
  model.setEditorText(submittedText, owner: owner)
  model.setEditorReason("Submitted A reason", owner: owner)
  await model.save()
  guard case .saved(let receipt) = model.saveOutcome else {
    throw MemoryError("Expected a completed Save for A")
  }
  let published = try fixture.transaction.main()
  #expect(published != base)
  #expect(receipt.commit == published)
  #expect(receipt.draftID == owner.draft.draftID)
  #expect(model.failure == nil)
  #expect(model.draftRecoveries.isEmpty)
  #expect(!model.isInputDirty)
  #expect(model.isSubmittedOwnerConsumed)
  #expect(model.retainedDraft == nil, "Clean consumed input must not adopt parked B")
  #expect(!model.isRetainedSaveRecoverable)
  #expect(model.drafts.contains { $0.draftID == parked.draftID })
  #expect(await model.workspace.currentDraft?.draftID == parked.draftID)
  let submitted = try #require(model.submittedInput)
  let laterText = fact("Exact later A input.\nKeep this second line.")
  let laterReason = "Exact later A reason"
  model.setEditorText(laterText, owner: owner)
  model.setEditorReason(laterReason, owner: owner)
  #expect(model.editorText == laterText)
  #expect(model.editorReason == laterReason)
  #expect(model.editorOwner == owner)
  #expect(model.selection == nil)
  #expect(model.isEditing)
  #expect(model.isInputDirty)
  #expect(model.isRetainingConsumedInput)
  #expect(!model.isSaveUnresolved && !model.isRetainedSaveRecoverable)
  #expect(!model.isSaveEnabled)
  #expect(model.isDiscardEnabled)
  #expect(model.batchProjection == nil)
  #expect(model.nativeDraftOwner == nil)
  #expect(model.autosaveTask == nil)
  let before = try fixture.transaction.snapshot(journal)
  await model.recoverSave()
  #expect(model.submittedInput?.owner == submitted.owner)
  #expect(model.submittedInput?.revision == submitted.revision)
  #expect(model.submittedInput?.text == submittedText)
  #expect(model.submittedInput?.reason == "Submitted A reason")
  #expect(model.isRetainingConsumedInput)
  #expect(model.message == "Saved changes in one commit")
  #expect(model.editorText == laterText)
  #expect(model.editorReason == laterReason)
  #expect(try fixture.transaction.snapshot(journal) == before)
  await model.discard()
  #expect(!model.isInputDirty)
  #expect(!model.isEditing)
  #expect(model.editorText.isEmpty)
  #expect(model.editorReason.isEmpty)
  #expect(model.submittedInput == nil)
  let after = try fixture.transaction.snapshot(journal)
  #expect(after == before, "Confirmed local Discard must leave B's journal unchanged")
  #expect(after[parkedCurrent.path]?.bytes == parkedBytes)
  let remaining = await model.workspace.refresh()
  #expect(remaining.draftRecoveries.isEmpty)
  #expect(
    try remaining.drafts.first { $0.draftID == parked.draftID }.map(memoryBatchDigest)
      == parkedDigest)
  #expect(try fixture.transaction.main() == published)
  try await model.shutdown()
}

@Test(arguments: [false, true])
@MainActor func nativePostSaveCandidateReloadKeepsTheConsumedOwnerClosed(isDecisionOnly: Bool)
  async throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = try await nativeReviewModel(fixture)
  let candidate = try #require(model.actionableCandidates.first)
  let reviewedCount = model.reviewedCandidates.count
  let base = try fixture.transaction.main()
  if isDecisionOnly {
    await model.disposition(candidate, isRejected: true)
  } else {
    await model.selectMemory(.candidate(candidate.change.id.rawValue))
    await model.stageShown()
  }
  let consumedDraftID = try #require(model.draft).draftID
  await model.save()
  switch model.saveOutcome {
  case .decisionsSaved: #expect(isDecisionOnly)
  case .saved: #expect(!isDecisionOnly)
  default: throw MemoryError("Expected a consuming Save outcome")
  }
  #expect(model.message == (isDecisionOnly ? "Decisions saved" : "Saved changes in one commit"))
  #expect(model.failure == nil)
  #expect(model.reviewFailure == nil)
  #expect(model.actionableCandidates.count == 7)
  #expect(model.reviewedCandidates.count == reviewedCount + 1)
  #expect(
    model.reviewedCandidates.first { $0.change.id == candidate.change.id }?.disposition
      == (isDecisionOnly ? .rejected : .approved))
  #expect(model.batchProjection == nil)
  #expect(model.presentation == nil)
  #expect(model.nativeDraftOwner == nil)
  #expect(model.stagedItems.isEmpty)
  #expect(!model.isWorkspaceLoaded)
  #expect(!model.isSaveEnabled)
  #expect(await !model.workspace.isNativeBatchOpen)
  #expect(await model.workspace.currentDraft == nil)
  #expect(await model.workspace.pendingPersistence == nil)
  let savedMain = try fixture.transaction.main()
  #expect(isDecisionOnly ? savedMain == base : savedMain != base)
  await model.stageShown()
  #expect(model.stagedItems.isEmpty)
  #expect(await !model.workspace.isNativeBatchOpen)
  let remaining = try #require(model.actionableCandidates.first)
  await model.selectMemory(.candidate(remaining.change.id.rawValue))
  #expect(model.draft?.draftID != consumedDraftID)
  #expect(model.nativeDraftOwner != nil)
  #expect(model.postSaveCandidates.isEmpty)
  #expect(model.presentation != nil)
  #expect(model.stagedItems.isEmpty)
  await model.stageShown()
  #expect(model.stagedItems.count == 1)
  #expect(try fixture.transaction.main() == savedMain)
  try await model.shutdown()
}

@Test(arguments: ["project", "deviceProject"])
@MainActor func nativeAbsentUnboundSuggestionTargetsRemainDiscoverable(scope: String) async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let project = fixture.root.appendingPathComponent("Yoink")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
  _ = try Git(repo: project, environment: [:]).data(["init", "--template="])
  let key = try #require(try MemoryStore.projectKey(cwd: project))
  let device = String(repeating: "a", count: 64)
  try fixture.populate(cwd: project.path)
  let sources = try DreamRunStore(
    stateRoot: fixture.state, sessionsRoot: fixture.sessions, memoryRepository: fixture.memory,
    strippingRoots: [fixture.snippets], deviceKey: device)
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        let context = try transactionObject(request)
        let evidence = try #require((context["primaryEvidence"] as? [[String: Any]])?.first)
        var target = ["kind": scope, "key": key]
        if scope == "deviceProject" { target["deviceKey"] = device }
        return try transactionResponse(
          request,
          decisions: [
            [
              "kind": "add", "scope": target, "text": "Retain this project preference.",
              "sources": [evidence["source"]!], "contradictions": [], "reason": "Explicit scope",
            ]
          ])
      }))
  var configuration = queueConfiguration(fixture)
  configuration.deviceKey = device
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let base = try fixture.main()
  let model = AppModel(configURL: url, autosaveDelay: .seconds(3600))
  model.section = "Memories"
  await model.load()
  await model.pauseQueue()
  try #require(model.failure == nil)
  #expect(model.configuration.projectBindings.isEmpty)
  let expectedPath =
    scope == "project" ? "projects/\(key).md" : "devices/\(device)/projects/\(key).md"
  #expect(model.batchProjection?.candidateCount == 1)
  let candidate = try #require(model.actionableCandidates.first)
  #expect(candidate.change.path == expectedPath)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.memory.appendingPathComponent(expectedPath).path))
  let label = scope == "project" ? "Yoink" : "Yoink · This device"
  #expect(model.scopeLabel(path: expectedPath) == label)
  #expect(model.scopeLabel(path: "MEMORY.md") == "Global")
  let commands = MemoryBatchInteractionCount()
  await Git.$memoryBatchCommandObserver.withValue(
    { commands.increment() },
    operation: {
      await model.selectMemory(.candidate(candidate.change.id.rawValue))
      #expect(model.selectedMemoryPath == expectedPath)
      await model.stageShown()
    })
  #expect(commands.count == 0)
  let item = try #require(model.stagedItems.first)
  #expect(model.memoryPath(for: item) == expectedPath)
  #expect(model.scopeLabel(path: try #require(model.memoryPath(for: item))) == label)
  #expect(model.stagedItems.count == 1)
  #expect(try fixture.main() == base)
  try await model.shutdown()
}

@Test @MainActor func nativeNewSuggestionPathsPreserveRestoredStagedIntent() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let project = fixture.root.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
  _ = try Git(repo: project, environment: [:]).data(["init", "--template="])
  try fixture.populate(texts: ["Initial preference."], cwd: project.path)
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try queueConfiguration(fixture).save(to: url)
  let model = AppModel(configURL: url)
  model.section = "Memories"
  await model.load()
  let candidate = try #require(model.actionableCandidates.first)
  await model.selectMemory(.candidate(candidate.change.id.rawValue))
  await model.stageShown()
  try await model.flushInputAndPersistence()
  let staged = try #require(model.stagedItems.first)
  try await model.shutdown()
  try fixture.populate(
    texts: ["Initial preference.", "New project preference."], cwd: project.path)
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0, isProject: true) }))
  let reopened = AppModel(configURL: url)
  reopened.section = "Memories"
  await reopened.load()
  #expect(reopened.failure == nil)
  #expect(reopened.stagedItems.map(\.itemID) == [staged.itemID])
  #expect(reopened.batchProjection?.needsReview == [staged.itemID])
  #expect(reopened.actionableCandidates.contains { $0.change.path.hasPrefix("projects/") })
  await reopened.refresh()
  #expect(reopened.failure == nil)
  #expect(reopened.stagedItems.map(\.itemID) == [staged.itemID])
  #expect(reopened.actionableCandidates.contains { $0.change.path.hasPrefix("projects/") })
  try await reopened.shutdown()
}

@Test @MainActor func nativeMixedChoicesPublishOnlyThroughOneFinalSave() async throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = try await nativeReviewModel(fixture)
  let candidates = model.actionableCandidates
  #expect(candidates.count == 8)
  let base = try fixture.transaction.main()
  await model.selectMemory(.candidate(candidates[0].change.id.rawValue))
  await model.stageShown()
  await model.selectMemory(.candidate(candidates[1].change.id.rawValue))
  await model.editSuggestion()
  model.editorText = model.editorText.replacingOccurrences(of: "Synthetic", with: "Amended")
  model.editorReason = "Explicit native correction"
  model.editorChanged()
  #expect(model.presentation == nil)
  #expect(!model.isSaveEnabled)
  try await model.flushInputAndPersistence()
  #expect(model.batchProjection?.needsReview.count == 1)
  #expect(model.presentation != nil)
  await model.stageShown()
  await model.disposition(candidates[2], isRejected: true)
  await model.disposition(candidates[3], isRejected: false)
  let reviewed = try #require(model.visibleEntries.first)
  await model.confirmReviewed(reviewed)
  await model.stageShown()
  let updatedEntry = model.visibleEntries[1]
  await model.selectMemory(.entry(updatedEntry.path, updatedEntry.locator.start))
  model.editorText = model.editorText.replacingOccurrences(of: "green", with: "blue")
  model.editorReason = "Explicit manual update"
  model.editorChanged()
  let deletedEntry = model.visibleEntries[2]
  await model.selectMemory(.entry(deletedEntry.path, deletedEntry.locator.start))
  model.editorReason = "Explicit manual deletion"
  await model.deleteEntry()
  await model.add(path: "projects/" + String(repeating: "a", count: 64) + ".md")
  model.editorText = fact("Manual project memory.")
  model.editorReason = "Explicit manual addition"
  model.editorChanged()
  #expect(try fixture.transaction.main() == base)
  await model.save()
  #expect(model.failure == nil)
  #expect(model.message == "Saved changes in one commit")
  let main = try fixture.transaction.main()
  #expect(main != base)
  #expect(
    try Git(repo: fixture.transaction.memory, environment: [:]).text([
      "rev-list", "--count", base + ".." + main,
    ]) == "1")
  let manifest = try MemoryBatchReplay.read(
    main, git: Git(repo: fixture.transaction.memory, environment: [:]))
  #expect(manifest.draft.batch?.items.count == 8)
  #expect(
    manifest.draft.batch?.items.contains {
      if case .candidate(let intent) = $0.intent { return intent.amendment != nil }
      return false
    } == true)
  #expect(model.stagedItems.isEmpty)
  await model.undoStaging()
  #expect(model.message == "No staged change to undo")
  #expect(try fixture.transaction.main() == main)
  try await model.shutdown()
}

@Test @MainActor func nativeRestoredPublishingRowsRequireFreshPerEntryStaging() async throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = try await nativeReviewModel(fixture)
  let candidate = try #require(model.actionableCandidates.first)
  await model.selectMemory(.candidate(candidate.change.id.rawValue))
  await model.stageShown()
  await model.confirmReviewed(try #require(model.visibleEntries.first))
  await model.stageShown()
  let ids = Set(model.stagedItems.map(\.itemID))
  try await model.shutdown()
  let restored = AppModel(configURL: fixture.configurationURL, autosaveDelay: .seconds(3600))
  restored.section = "Memories"
  await restored.load()
  #expect(restored.batchProjection?.needsReview == ids)
  #expect(!restored.isSaveEnabled)
  for id in ids {
    await restored.selectMemory(.staged(id))
    #expect(restored.batchProjection?.needsReview.contains(id) == true)
    await restored.stageShown()
    #expect(restored.batchProjection?.needsReview.contains(id) == false)
  }
  #expect(restored.isSaveEnabled)
  await restored.save()
  #expect(restored.failure == nil)
  try await restored.shutdown()
}

@Test @MainActor func nativeDirtyAmendmentNeverBecomesManualApprovalAndKeepsRequiredSources()
  async throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = try await nativeReviewModel(fixture)
  let candidate = try #require(model.actionableCandidates.first)
  await model.selectMemory(.candidate(candidate.change.id.rawValue))
  await model.stageShown()
  await model.selectMemory(.staged(try #require(model.stagedItems.first).itemID))
  await model.editSuggestion()
  let originalText = model.editorText
  model.editorText = fact("Missing the original exact sources.")
  model.editorReason = "Explicit correction"
  model.editorChanged()
  await model.save()
  #expect(model.isInputDirty)
  #expect(!model.isSaveEnabled)
  await model.selectMemory(.entry("MEMORY.md", 0))
  #expect(model.isInputDirty)
  #expect(model.editorText == fact("Missing the original exact sources."))
  model.editorText = originalText.replacingOccurrences(of: "Synthetic", with: "Corrected")
  model.editorChanged()
  try await model.flushInputAndPersistence()
  let item = try #require(model.stagedItems.first)
  guard case .candidate(let intent) = item.intent else {
    Issue.record("Suggestion became manual CRUD")
    return
  }
  #expect(intent.amendment?.replacement == model.editorText)
  #expect(model.batchProjection?.needsReview.contains(item.itemID) == true)
  #expect(
    MemoryDocument.sourceAnnotations(in: Data(model.editorText.utf8))
      == MemoryDocument.sourceAnnotations(in: candidate.change.after))
  await model.stageShown()
  #expect(model.batchProjection?.needsReview.isEmpty == true)
  try await model.shutdown()
}

@Test @MainActor func nativeFlushDrainsNewerAutosaveAdmittedWhileAwaitingPredecessor() async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let control = NativePersistenceControl()
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try queueConfiguration(fixture).save(to: url)
  let model = AppModel(
    configURL: url, autosaveDelay: .zero,
    persistence: NativeBatchPersistence(write: control.write))
  await model.load()
  await model.pauseQueue()
  await model.add()
  await control.pauseWrites()
  let owner = try #require(model.editorOwner)
  model.setEditorText(fact("First autosave held while the flush starts."), owner: owner)
  model.setEditorReason("First reason", owner: owner)
  let previous = try #require(model.autosaveTask)
  let deadline = ContinuousClock.now + .seconds(5)
  while await control.requests.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
  if await control.requests.isEmpty { await control.resumeWrites() }
  try #require(await control.requests.count == 1)
  let flush = Task { try await model.flushInputAndPersistence() }
  while !previous.isCancelled && ContinuousClock.now < deadline { await Task.yield() }
  if !previous.isCancelled { await control.resumeWrites() }
  try #require(previous.isCancelled)
  let latestText = fact("Latest exact input admitted while the flush awaits its predecessor.")
  model.setEditorText(latestText, owner: owner)
  model.setEditorReason("Latest exact reason", owner: owner)
  await control.resumeWrites()
  try await flush.value
  #expect(!model.isDraftDirty)
  #expect(model.autosaveTask == nil)
  #expect(model.autosaveID == nil)
  #expect(await control.maximumInFlight == 1)
  let requests = await control.requests
  try #require(requests.count == 2)
  #expect(requests[1].revision > requests[0].revision)
  guard case .manual(let intent) = requests[1].batch?.items.first?.intent else {
    throw MemoryError("Expected the latest drained manual input")
  }
  #expect(intent.request.replacement == latestText)
  #expect(intent.request.reason == "Latest exact reason")
  #expect(await model.workspace.pendingPersistence == nil)
  try await model.shutdown()
}

@Test @MainActor func nativePersistenceAcknowledgesOlderWritesWithoutClearingNewerInput()
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let control = NativePersistenceControl()
  await control.pauseWrites()
  let model = try await pendingNativeModel(
    fixture, persistence: NativeBatchPersistence(write: control.write))
  try await model.flushEditor()
  let firstRevision = try #require(model.draft).revision
  let writing = Task { try await model.persistIntent() }
  let deadline = ContinuousClock.now + .seconds(5)
  while await control.requests.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
  try #require(await !control.requests.isEmpty)
  model.editorText = fact("Newer input must survive an old receipt.")
  model.editorReason = "Newer reason"
  model.editorChanged()
  await control.resumeWrites()
  try await writing.value
  #expect(model.editorText == fact("Newer input must survive an old receipt."))
  #expect(model.editorReason == "Newer reason")
  #expect(model.isInputDirty)
  #expect(model.isDraftDirty)
  #expect(model.persistedBatchRevision == firstRevision)
  try await model.shutdown()
  #expect(!model.isDraftDirty)
  #expect(await control.maximumInFlight == 1)
  #expect(await control.requests.count == 2)
  let reopened = AppModel(configURL: model.configURL)
  await reopened.load()
  guard case .manual(let intent) = reopened.stagedItems.first?.intent else {
    Issue.record("Newer input was lost")
    return
  }
  #expect(intent.request.replacement == model.editorText)
  #expect(intent.request.reason == "Newer reason")
  try await reopened.shutdown()
}

@Test @MainActor func nativeFailedInstalledRequestRetriesExactlyBeforePersistingNewerIntent()
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let attempts = NativePersistenceControl()
  await attempts.failInstalledWrite()
  let model = try await pendingNativeModel(
    fixture, persistence: NativeBatchPersistence(write: attempts.write))
  do {
    try await model.flushInputAndPersistence()
    Issue.record("Expected failed write")
  } catch {}
  let failed = try #require(await attempts.requests.first)
  model.editorText = fact("Latest text after a failed write.")
  model.editorChanged()
  await attempts.resumeWrites()
  try await model.shutdown()
  let requests = await attempts.requests
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  #expect(requests.count == 3)
  #expect(try encoder.encode(requests[0]) == encoder.encode(requests[1]))
  #expect(requests[2].revision > failed.revision)
  #expect(await attempts.maximumInFlight == 1)
  #expect(!model.isDraftDirty)
}

@Test @MainActor func nativeDecisionOnlyFeedbackAndRecoveryDoNotPermitDuplicatePublication()
  async throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = try await nativeReviewModel(fixture)
  let base = try fixture.transaction.main()
  await model.disposition(try #require(model.actionableCandidates.first), isRejected: true)
  await model.save()
  #expect(model.message == "Decisions saved")
  #expect(try fixture.transaction.main() == base)
  await model.add()
  model.editorText = fact("One recoverable publication.")
  model.editorReason = "Explicit change"
  model.editorChanged()
  await model.workspace.failNativePublicationBookkeeping(isFailing: true)
  await model.save()
  #expect(model.isSaveUnresolved)
  #expect(!model.isSaveEnabled)
  let published = try fixture.transaction.main()
  #expect(published != base)
  await model.save()
  #expect(try fixture.transaction.main() == published)
  let delegate = ApplicationDelegate()
  delegate.model = model
  #expect(await delegate.isTerminationReady() == false)
  await model.workspace.failNativePublicationBookkeeping(isFailing: false)
  await model.recoverSave()
  #expect(!model.isSaveUnresolved)
  #expect(model.stagedItems.isEmpty)
  #expect(try fixture.transaction.main() == published)
  await model.handleSave(.outcomeUnknown(saveID: "synthetic", details: "Synthetic unknown outcome"))
  #expect(!model.isSaveEnabled)
  await model.save()
  #expect(try fixture.transaction.main() == published)
  model.saveOutcome = nil
  try await model.shutdown()
}

@Test @MainActor func nativeRelaunchRecoversPublishedRetainedDraftWithoutReopeningAuthority()
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let model = try await pendingNativeModel(fixture)
  await model.prepareCheckout()
  await model.detach()
  await model.workspace.failNativePublicationBookkeeping(isFailing: true)
  await model.save()
  #expect(model.isSaveUnresolved)
  let published = try fixture.main()
  _ = await model.workspace.closeBatch()
  let reopened = AppModel(configURL: model.configURL, autosaveDelay: .seconds(3600))
  await reopened.load()
  await reopened.loadCandidates()
  #expect(reopened.batchProjection == nil)
  #expect(reopened.isRetainedSaveRecoverable)
  #expect(!reopened.isSaveEnabled)
  await reopened.recoverSave()
  #expect(!reopened.isSaveUnresolved)
  #expect(reopened.stagedItems.isEmpty)
  #expect(try fixture.main() == published)
  try await reopened.shutdown()
}

@Test @MainActor func nativePagingAndExplicitPathsRetainOneSessionAndStagedAuthority() async throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = AppModel(configURL: fixture.configurationURL, autosaveDelay: .seconds(3600))
  await model.load()
  await model.pauseQueue()
  model.applyBatch(try await model.workspace.openBatch(catalogLimit: 1))
  let candidate = try #require(model.actionableCandidates.first)
  await model.selectMemory(.candidate(candidate.change.id.rawValue))
  await model.stageShown()
  let original = try #require(model.stagedItems.first)
  let draftID = model.draft?.draftID
  await model.loadPage(offset: 1)
  #expect(model.failure == nil)
  #expect(model.draft?.draftID == draftID)
  #expect(
    model.batchProjection?.retainedCandidates.contains { $0.change.id == candidate.change.id }
      == true)
  #expect(model.batchProjection?.needsReview.isEmpty == true)
  await model.selectMemory(
    .candidate(try #require(model.actionableCandidates.first).change.id.rawValue))
  await model.stageShown()
  let before = model.stagedItems.map(\.itemID)
  await model.add(
    path: "devices/" + String(repeating: "a", count: 64) + "/projects/"
      + String(repeating: "b", count: 64) + ".md")
  #expect(model.draft?.draftID == draftID)
  #expect(model.stagedItems.map(\.itemID) == before)
  #expect(model.batchProjection?.needsReview.isEmpty == true)
  await model.selectMemory(.staged(original.itemID))
  #expect(model.presentation != nil)
  await model.save()
  #expect(model.failure == nil)
  #expect(model.stagedItems.isEmpty)
  try await model.shutdown()
}

@Test @MainActor func nativeConcurrentFlushesCoalesceOnlyAfterAcknowledgingTheirOwnReceipt()
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let control = NativePersistenceControl()
  await control.pauseWrites()
  let model = try await pendingNativeModel(
    fixture, persistence: NativeBatchPersistence(write: control.write))
  try await model.flushEditor()
  let first = Task { try await model.persistIntent() }
  let deadline = ContinuousClock.now + .seconds(5)
  while await control.requests.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
  try #require(await !control.requests.isEmpty)
  let second = Task { try await model.persistIntent() }
  model.editorText = fact("Newer staged intent while persistence is suspended.")
  model.editorReason = "Latest staged reason"
  model.editorChanged()
  try await model.flushEditor()
  await control.resumeWrites()
  try await first.value
  try await second.value
  #expect(await control.maximumInFlight == 1)
  let requests = await control.requests
  #expect(requests.count == 2)
  #expect(requests[0].revision < requests[1].revision)
  #expect(!model.isDraftDirty)
  #expect(model.failure == nil)
  try await model.shutdown()
}

private func nativeMilliseconds(_ duration: Duration) -> Double {
  Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PI_NATIVE_PREPARED_TARGET"] == "1"))
@MainActor func nativeThirtySuggestionPreparedActionTarget() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: (0..<30).map { "Synthetic preference \($0)." })
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection,
      prepare: { try fixture.prepare($0) }, call: { try transactionAdd($0) }))
  let manager = try MemoryManagement(repository: fixture.memory)
  try manager.confirmDetach(manager.checkoutPreview())
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let model = AppModel(configURL: url, autosaveDelay: .seconds(3600))
  await model.load()
  await model.pauseQueue()
  let preparationStart = ContinuousClock.now
  await model.loadCandidates()
  let preparation = nativeMilliseconds(preparationStart.duration(to: .now))
  #expect(model.actionableCandidates.count == 30)
  let candidates = model.actionableCandidates
  let commands = MemoryBatchInteractionCount()
  let history = MemoryBatchInteractionCount()
  await model.workspace.observeNativeHistory(history)
  let scans = model.queueScanCount
  var repetitions: [Double] = []
  var actionTimes: [Double] = []
  for iteration in 0..<6 {
    let start = ContinuousClock.now
    await Git.$memoryBatchCommandObserver.withValue(
      { commands.increment() },
      operation: {
        for candidate in candidates {
          let selecting = ContinuousClock.now
          await model.selectMemory(.candidate(candidate.change.id.rawValue))
          if iteration > 0 { actionTimes.append(nativeMilliseconds(selecting.duration(to: .now))) }
          let staging = ContinuousClock.now
          await model.stageShown()
          if iteration > 0 { actionTimes.append(nativeMilliseconds(staging.duration(to: .now))) }
        }
      })
    #expect(model.failure == nil)
    #expect(model.stagedItems.count == 30)
    if iteration > 0 { repetitions.append(nativeMilliseconds(start.duration(to: .now))) }
    if iteration < 5 {
      for item in model.stagedItems { await model.removeItem(item.itemID) }
    }
  }
  #expect(commands.count == 0)
  #expect(history.count == 0)
  #expect(model.queueScanCount == scans)
  #expect(actionTimes.max() ?? .infinity < 100)
  let preparedScans = model.queueScanCount - scans
  let preparedHistory = history.count
  let durabilityStart = ContinuousClock.now
  try await model.flushInputAndPersistence()
  let durability = nativeMilliseconds(durabilityStart.duration(to: .now))
  let saveStart = ContinuousClock.now
  await model.save()
  let save = nativeMilliseconds(saveStart.duration(to: .now))
  #expect(model.failure == nil)
  #expect(model.stagedItems.isEmpty)
  let result: [String: Any] = [
    "preparationMS": preparation, "selectionAndStage30MS": repetitions,
    "actionMedianMS": actionTimes.sorted()[actionTimes.count / 2],
    "actionMaxMS": actionTimes.max() ?? 0,
    "durabilityMS": durability, "saveAndReconcileMS": save,
    "composedFinalWorkflowMS": preparation + (repetitions.last ?? 0) + durability + save,
    "gitDuringPreparedActions": commands.count, "historyDuringPreparedActions": preparedHistory,
    "queueScansDuringPreparedActions": preparedScans,
  ]
  print(
    "NATIVE_PREPARED_TARGET "
      + String(
        decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
        as: UTF8.self))
  try await model.shutdown()
}

@Test @MainActor func nativePreparedNavigationStagesAndUndoAvoidGitHistoryAndQueueReloads()
  async throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = try await nativeReviewModel(fixture)
  let commands = MemoryBatchInteractionCount()
  let history = MemoryBatchInteractionCount()
  await model.workspace.observeNativeHistory(history)
  await model.pauseQueue()
  let queue = model.queueScanCount
  let candidate = try #require(model.actionableCandidates.first)
  try await Git.$memoryBatchCommandObserver.withValue(
    { commands.increment() },
    operation: {
      await model.selectMemory(.candidate(candidate.change.id.rawValue))
      await model.stageShown()
      await model.removeItem(try #require(model.stagedItems.first).itemID)
      await model.undoStaging()
    })
  #expect(commands.count == 0)
  #expect(history.count == 0)
  #expect(model.queueScanCount == queue)
  #expect(model.stagedItems.count == 1)
  try await model.shutdown()
}
