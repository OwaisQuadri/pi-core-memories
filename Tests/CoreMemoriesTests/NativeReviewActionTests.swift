import AppKit
import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

@Test func nativeReviewEventAdmissionRejectsRepeatsWithoutReadingNonKeyEvents() {
  let cases: [(NSEvent.EventType?, Bool, Bool)] = [
    (.keyDown, false, true), (.keyDown, true, false), (.keyUp, false, true),
    (.keyUp, true, false), (.keyDown, false, true), (nil, true, true),
    (.leftMouseDown, true, true), (.flagsChanged, true, true), (.applicationDefined, true, true),
  ]
  for (type, isRepeat, isExpected) in cases {
    var reads = 0
    let isAdmitted = isNativeReviewEventAdmitted(type: type) {
      reads += 1
      return isRepeat
    }
    #expect(isAdmitted == isExpected)
    #expect(reads == (type == .keyDown || type == .keyUp ? 1 : 0))
  }
}

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

@Test @MainActor func nativeReviewRequestsDeclineChangedSelectionOwnerAndAmendmentInput()
  async throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = AppModel(configURL: fixture.configurationURL, autosaveDelay: .seconds(3600))
  model.section = "Memories"
  await model.load()
  await model.pauseQueue()
  let candidates = model.actionableCandidates
  let first = NativeMemorySelection.candidate(candidates[0].change.id.rawValue)
  let second = NativeMemorySelection.candidate(candidates[1].change.id.rawValue)
  let base = try fixture.transaction.main()
  await model.selectMemory(first)
  let selectionRequest = try #require(model.captureReviewAction(.accept))
  await model.selectMemory(second)
  await model.executeReviewAction(selectionRequest)
  #expect(model.selection == second)
  #expect(model.stagedItems.isEmpty)
  let ownerRequest = try #require(model.captureReviewAction(.dismiss))
  await model.refresh()
  await model.pauseQueue()
  await model.selectMemory(second)
  #expect(model.nativeDraftOwner != ownerRequest.owner)
  await model.executeReviewAction(ownerRequest)
  #expect(model.stagedItems.isEmpty)
  for section in ["Dreams", "Settings"] {
    model.section = section
    #expect(model.captureReviewAction(.accept) == nil)
    #expect(model.captureReviewAction(.decideLater) == nil)
    #expect(model.captureReviewAction(.dismiss) == nil)
  }
  model.section = "Memories"
  model.isBusy = true
  #expect(model.captureReviewAction(.accept) == nil)
  model.isBusy = false
  model.isDreamRunning = true
  #expect(model.captureReviewAction(.dismiss) == nil)
  model.isDreamRunning = false
  model.isSubmittingSave = true
  #expect(model.captureReviewAction(.decideLater) == nil)
  model.isSubmittingSave = false
  model.saveOutcome = .outcomeUnknown(saveID: "synthetic", details: "Synthetic unresolved Save")
  #expect(model.captureReviewAction(.accept) == nil)
  model.saveOutcome = nil
  await model.editSuggestion()
  model.setEditorReason("First explicit correction", owner: model.editorOwner)
  await model.stageEditor()
  let amendmentRequest = try #require(model.captureReviewAction(.accept))
  #expect(model.captureReviewAction(.decideLater) == nil)
  #expect(model.captureReviewAction(.dismiss) == nil)
  model.setEditorReason("Retain this newer correction", owner: model.editorOwner)
  await model.executeReviewAction(amendmentRequest)
  #expect(model.selection == second)
  #expect(model.editorReason == "Retain this newer correction")
  #expect(model.isInputDirty)
  #expect(model.presentation == nil)
  #expect(model.batchProjection?.needsReview.count == 1)
  #expect(model.captureReviewAction(.accept) == nil)
  #expect(try fixture.transaction.main() == base)
  try await model.shutdown()
}
