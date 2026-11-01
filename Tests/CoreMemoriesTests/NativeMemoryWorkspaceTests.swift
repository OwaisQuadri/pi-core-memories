import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

actor NativePersistenceControl {
  private(set) var requests: [MemoryDraft] = []
  private var inFlight = 0
  private var isPaused = false
  private var release: CheckedContinuation<Void, Never>?
  private var isPauseOperationCompleted = false
  private var pauseObserver: (after: Int, continuation: CheckedContinuation<Bool, Never>)?
  func pauseWrites() {
    isPaused = true
    isPauseOperationCompleted = false
  }

  func isWritePaused(after count: Int) async -> Bool {
    if release != nil, requests.count > count { return true }
    if !isPaused || isPauseOperationCompleted { return false }
    precondition(pauseObserver == nil)
    return await withCheckedContinuation { pauseObserver = (count, $0) }
  }

  func pauseOperationCompleted() {
    isPauseOperationCompleted = true
    pauseObserver?.continuation.resume(returning: false)
    pauseObserver = nil
  }

  func resumeWrites() {
    isPaused = false
    release?.resume()
    release = nil
    pauseObserver?.continuation.resume(returning: false)
    pauseObserver = nil
  }

  func write(_ request: MemoryBatchPersistenceRequest, repository: URL, journal: URL) async throws
    -> MemoryBatchPersistenceReceipt
  {
    requests.append(request.draft)
    inFlight += 1
    defer { inFlight -= 1 }
    guard inFlight == 1 else { throw MemoryError("Concurrent native persistence") }
    if isPaused {
      await withCheckedContinuation {
        release = $0
        if let observer = pauseObserver, requests.count > observer.after {
          pauseObserver = nil
          observer.continuation.resume(returning: true)
        }
      }
    }
    return try MemoryDraftStore(repository: repository, journal: journal).persistBatch(request)
  }
}

@MainActor private func nativeReviewModel(_ fixture: ReviewFlowFixture) async throws -> AppModel {
  let model = AppModel(configURL: fixture.configurationURL, autosaveDelay: .seconds(3600))
  model.section = "Memories"
  await model.load()
  #expect(model.failure == nil)
  return model
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
