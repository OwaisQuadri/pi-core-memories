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
