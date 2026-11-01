import AppKit
import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

@Test(arguments: [NativeReviewAction.accept, .decideLater, .dismiss])
@MainActor func nativeReviewActionStagesOnlyCapturedItemAndNeverRetargetsRepeat(
  action: NativeReviewAction
) async throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = AppModel(configURL: fixture.configurationURL, autosaveDelay: .seconds(3600))
  model.section = "Memories"
  await model.load()
  await model.pauseQueue()
  let candidates = model.actionableCandidates
  let base = try fixture.transaction.main()
  let preserved = try fixture.preservedFiles()
  let recovery = try fixture.transaction.snapshot(fixture.reviewState)
  await model.selectMemory(.candidate(candidates[0].change.id.rawValue))
  let request = try #require(model.captureReviewAction(action))
  #expect(request.candidateID == candidates[0].change.id.rawValue)
  #expect(request.owner == model.nativeDraftOwner)
  #expect((request.presentation != nil) == (action == .accept))
  await model.executeReviewAction(request)
  #expect(model.failure == nil)
  #expect(model.selection == .candidate(candidates[1].change.id.rawValue))
  #expect(model.presentation != nil)
  let item = try #require(model.stagedItems.first)
  guard case .candidate(let intent) = item.intent else {
    throw MemoryError("Expected the captured candidate's decision")
  }
  #expect(intent.candidateID == candidates[0].change.id.rawValue)
  #expect(
    intent.choice == (action == .accept ? .accept : action == .dismiss ? .reject : .deferCandidate))
  if isNativeReviewEventAdmitted(type: .keyDown, isRepeat: { true }) {
    Issue.record("A repeat must not capture the automatically selected suggestion")
    model.submitReviewAction(action)
  }
  await model.executeReviewAction(request)
  #expect(model.stagedItems.map(\.itemID) == [item.itemID])
  #expect(model.selection == .candidate(candidates[1].change.id.rawValue))
  #expect(try fixture.transaction.main() == base)
  #expect(try fixture.preservedFiles() == preserved)
  #expect(try fixture.transaction.snapshot(fixture.reviewState) == recovery)
  try await model.shutdown()
}
