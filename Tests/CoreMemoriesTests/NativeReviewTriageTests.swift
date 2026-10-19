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
  try await model.shutdown()
}
