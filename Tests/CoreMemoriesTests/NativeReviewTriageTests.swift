import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

@Test(arguments: [MemoryBatchChoice.accept, .deferCandidate, .reject])
@MainActor func nativeTriageRemovesStagedSuggestionAndPresentsNext(choice: MemoryBatchChoice)
  async throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = AppModel(configURL: fixture.configurationURL, autosaveDelay: .seconds(3600))
  model.section = "Memories"
  await model.load()
  await model.pauseQueue()
  let candidates = model.actionableCandidates
  try #require(candidates.count == 8)
  let base = try fixture.transaction.main()
  let preserved = try fixture.preservedFiles()
  await model.selectMemory(.candidate(candidates[0].change.id.rawValue))
  if choice == .accept {
    await model.stageShown()
  } else {
    await model.disposition(candidates[0], isRejected: choice == .reject)
  }
  #expect(model.failure == nil)
  #expect(model.actionableCandidates.map(\.change.id) == candidates.dropFirst().map(\.change.id))
  #expect(model.selection == .candidate(candidates[1].change.id.rawValue))
  let shown = try #require(model.presentation)
  guard case .candidate(let intent) = shown.intent else {
    throw MemoryError("Expected the next suggestion's review presentation")
  }
  #expect(intent.candidateID == candidates[1].change.id.rawValue)
  #expect(model.stagedItems.count == 1)
  #expect(try fixture.transaction.main() == base)
  #expect(try fixture.preservedFiles() == preserved)
  let itemID = try #require(model.stagedItems.first).itemID
  await model.removeItem(itemID)
  #expect(model.actionableCandidates.map(\.change.id) == candidates.map(\.change.id))
  #expect(model.selection == .candidate(candidates[1].change.id.rawValue))
  await model.undoStaging()
  #expect(model.stagedItems.map(\.itemID) == [itemID])
  #expect(model.actionableCandidates.map(\.change.id) == candidates.dropFirst().map(\.change.id))
  try await model.shutdown()
  let restored = AppModel(configURL: fixture.configurationURL, autosaveDelay: .seconds(3600))
  restored.section = "Memories"
  await restored.load()
  #expect(restored.failure == nil)
  #expect(restored.stagedItems.map(\.itemID) == [itemID])
  #expect(restored.actionableCandidates.map(\.change.id) == candidates.dropFirst().map(\.change.id))
  if choice == .accept {
    #expect(restored.batchProjection?.needsReview == [itemID])
    await restored.selectMemory(.staged(itemID))
    await restored.stageShown()
    #expect(restored.selection == .staged(itemID))
    #expect(restored.batchProjection?.needsReview.isEmpty == true)
  }
  #expect(try fixture.transaction.main() == base)
  #expect(try fixture.preservedFiles() == preserved)
  try await restored.shutdown()
}

@Test @MainActor func nativeAmendedTriageWrapsRemainingQueueAndEndsWithEmptySelection() async throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = AppModel(configURL: fixture.configurationURL, autosaveDelay: .seconds(3600))
  model.section = "Memories"
  await model.load()
  await model.pauseQueue()
  let original = model.actionableCandidates
  let last = try #require(original.last)
  let base = try fixture.transaction.main()
  await model.add()
  model.setEditorText(fact("An unrelated manual preference."), owner: model.editorOwner)
  model.setEditorReason("Explicit addition", owner: model.editorOwner)
  await model.stageEditor()
  #expect(model.actionableCandidates.map(\.change.id) == original.map(\.change.id))
  await model.selectMemory(.candidate(last.change.id.rawValue))
  await model.editSuggestion()
  model.setEditorReason("Explicit amendment", owner: model.editorOwner)
  #expect(!model.isStageAcceptanceEnabled)
  #expect(!model.isSelectedDecisionEnabled)
  await model.stageEditor()
  #expect(!model.actionableCandidates.contains { $0.change.id == last.change.id })
  #expect(model.isStageAcceptanceEnabled)
  #expect(!model.isSelectedDecisionEnabled)
  await model.stageShown()
  #expect(model.selection == .candidate(original[0].change.id.rawValue))
  #expect(model.presentation != nil)
  for candidate in original.dropLast() {
    #expect(model.selection == .candidate(candidate.change.id.rawValue))
    await model.disposition(candidate, isRejected: false)
  }
  #expect(model.failure == nil)
  #expect(model.actionableCandidates.isEmpty)
  #expect(model.selection == nil)
  #expect(model.presentation == nil)
  #expect(model.stagedItems.count == 9)
  #expect(model.isSaveEnabled)
  #expect(try fixture.transaction.main() == base)
  try await model.shutdown()
}

@Test @MainActor func nativeFailedTriageAndExplicitOtherCandidateKeepCurrentReview() async throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = AppModel(configURL: fixture.configurationURL, autosaveDelay: .seconds(3600))
  model.section = "Memories"
  await model.load()
  await model.pauseQueue()
  let candidates = model.actionableCandidates
  let base = try fixture.transaction.main()
  await model.selectMemory(.candidate(candidates[0].change.id.rawValue))
  let shown = try #require(model.presentation)
  _ = try await model.perform(.page(0))
  await model.stageShown()
  #expect(model.failure == "presentation is stale or belongs to another session")
  #expect(model.selection == .candidate(candidates[0].change.id.rawValue))
  #expect(model.presentation?.digest == shown.digest)
  #expect(model.actionableCandidates.map(\.change.id) == candidates.map(\.change.id))
  #expect(model.stagedItems.isEmpty)
  model.failure = nil
  await model.disposition(candidates[1], isRejected: true)
  #expect(model.failure == nil)
  #expect(model.selection == .candidate(candidates[0].change.id.rawValue))
  #expect(model.presentation?.digest == shown.digest)
  #expect(
    model.actionableCandidates.map(\.change.id)
      == candidates.filter {
        $0.change.id != candidates[1].change.id
      }.map(\.change.id))
  #expect(try fixture.transaction.main() == base)
  try await model.shutdown()
}

@Test @MainActor func nativeTriageCrossesCatalogBoundaryWithoutSkippingEarlierSuggestions()
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: (0..<66).map { "Synthetic preference \($0)." })
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try queueConfiguration(fixture).save(to: url)
  let model = AppModel(configURL: url, autosaveDelay: .seconds(3600))
  model.section = "Memories"
  await model.load()
  await model.pauseQueue()
  try #require(model.batchProjection?.candidateCount == 66)
  try #require(model.candidates.count == 64)
  let first = try #require(model.actionableCandidates.first)
  let last = try #require(model.actionableCandidates.last)
  let base = try fixture.main()
  await model.selectMemory(.candidate(last.change.id.rawValue))
  await model.disposition(last, isRejected: false)
  #expect(model.batchProjection?.catalogOffset == 64)
  let tail = model.actionableCandidates
  try #require(tail.count == 2)
  for candidate in tail {
    #expect(model.selection == .candidate(candidate.change.id.rawValue))
    #expect(model.presentation != nil)
    await model.disposition(candidate, isRejected: true)
  }
  #expect(model.failure == nil)
  #expect(model.batchProjection?.catalogOffset == 0)
  #expect(model.selection == .candidate(first.change.id.rawValue))
  #expect(model.presentation != nil)
  #expect(model.actionableCandidates.count == 63)
  #expect(model.stagedItems.count == 3)
  #expect(try fixture.main() == base)
  try await model.shutdown()
}

@Test func nativeScopeLabelsUseConfiguredNamesAndHonestFallbacks() {
  let project = String(repeating: "a", count: 64)
  let missing = String(repeating: "b", count: 64)
  let device = String(repeating: "c", count: 64)
  let otherDevice = String(repeating: "d", count: 64)
  var configuration = MemoryConfiguration.defaults
  configuration.projectBindings = ["/synthetic/Pillars/.git": project]
  let names = NativeMemoryScopeNames.prepare(configuration: configuration, candidates: [])
  #expect(names.label(path: "MEMORY.md", deviceKey: device) == "Global")
  #expect(names.label(path: "projects/\(project).md", deviceKey: device) == "Pillars")
  #expect(
    names.label(path: "projects/\(missing).md", deviceKey: device) == "Project (name unavailable)")
  #expect(names.label(path: "devices/\(device)/MEMORY.md", deviceKey: device) == "This device")
  #expect(
    names.label(path: "devices/\(otherDevice)/MEMORY.md", deviceKey: device) == "Another device")
  #expect(
    names.label(path: "devices/\(device)/projects/\(project).md", deviceKey: device)
      == "Pillars · This device")
  #expect(
    names.label(path: "devices/\(otherDevice)/projects/\(project).md", deviceKey: device)
      == "Pillars · Another device")
  configuration.projectBindings["/synthetic/Yoink/.git"] = project
  let ambiguous = NativeMemoryScopeNames.prepare(configuration: configuration, candidates: [])
  #expect(
    ambiguous.label(path: "projects/\(project).md", deviceKey: device) == "Project (ambiguous name)"
  )
}
