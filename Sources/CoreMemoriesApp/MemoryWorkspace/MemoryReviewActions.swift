import AppKit
import CoreMemories

enum NativeReviewAction {
  case accept, decideLater, dismiss
}

struct NativeReviewRequest {
  let action: NativeReviewAction
  let candidateID: String?
  let selection: NativeMemorySelection?
  let section: String
  let owner: NativeDraftOwner
  let inputRevision: UInt64
  let editorOwner: NativeEditorOwner?
  let presentation: MemoryBatchPresentation?
}

func isNativeReviewEventAdmitted(type: NSEvent.EventType?, isRepeat: () -> Bool) -> Bool {
  switch type {
  case .keyDown, .keyUp: !isRepeat()
  default: true
  }
}

extension AppModel {
  func isReviewActionEnabled(_ action: NativeReviewAction) -> Bool {
    guard section == "Memories", nativeDraftOwner != nil else { return false }
    switch action {
    case .accept: return isStageAcceptanceEnabled
    case .decideLater, .dismiss: return isSelectedDecisionEnabled
    }
  }

  func submitReviewAction(_ action: NativeReviewAction) {
    let event = NSApp.currentEvent
    guard isNativeReviewEventAdmitted(type: event?.type, isRepeat: { event?.isARepeat ?? false }),
      let request = captureReviewAction(action)
    else { return }
    Task { await executeReviewAction(request) }
  }

  func captureReviewAction(_ action: NativeReviewAction) -> NativeReviewRequest? {
    guard isReviewActionEnabled(action), let candidate = selectedCandidate else { return nil }
    return reviewRequest(
      action: action, candidateID: candidate.change.id.rawValue,
      presentation: action == .accept ? presentation : nil)
  }

  func reviewRequest(
    action: NativeReviewAction, candidateID: String?, presentation: MemoryBatchPresentation? = nil
  ) -> NativeReviewRequest? {
    guard let owner = nativeDraftOwner else { return nil }
    return NativeReviewRequest(
      action: action, candidateID: candidateID, selection: selection, section: section,
      owner: owner, inputRevision: inputRevision, editorOwner: editorOwner,
      presentation: presentation)
  }

  func isReviewRequestCurrent(_ request: NativeReviewRequest) -> Bool {
    guard isLoaded, !isSubmittingSave, isReviewTransitionEnabled, !isInputDirty,
      request.owner == nativeDraftOwner, request.selection == selection,
      request.section == section, request.inputRevision == inputRevision,
      request.editorOwner == editorOwner
    else { return false }
    if let shown = request.presentation {
      return presentation?.itemID == shown.itemID && presentation?.digest == shown.digest
        && presentation?.path == shown.path && presentation?.before == shown.before
        && presentation?.after == shown.after
    }
    return true
  }

  func executeReviewAction(_ request: NativeReviewRequest) async {
    guard isReviewActionEnabled(request.action), isReviewRequestCurrent(request),
      selectedCandidate?.change.id.rawValue == request.candidateID
    else { return }
    switch request.action {
    case .accept: await stageShown(request: request)
    case .decideLater, .dismiss:
      guard let candidate = selectedCandidate else { return }
      await disposition(candidate, isRejected: request.action == .dismiss, request: request)
    }
  }
}
