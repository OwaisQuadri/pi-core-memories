import AppKit
import CoreMemories
import Foundation

enum NativeMemorySelection: Hashable {
  case staged(UUID)
  case candidate(String)
  case entry(String, Int)
  case newMemory(UUID)
  case recovery(String)
}

struct NativeManualTarget {
  let path: String
  let locator: MemoryDocument.EntryLocator
  let expected: String
}

enum NativeEditorTarget {
  case manual(entry: NativeManualTarget?, itemID: UUID?)
  case amendment(MemoryReviewCandidate)

  var identity: NativeEditorIdentity {
    switch self {
    case .manual(_, let itemID): .manual(itemID)
    case .amendment(let candidate): .amendment(candidate.change.id)
    }
  }
}

enum NativeEditorIdentity: Equatable {
  case manual(UUID?)
  case amendment(SourceDigest)
}

struct NativeDraftOwner: Equatable {
  let generation: UInt64
  let draftID: UUID
}

struct NativeEditorOwner: Equatable {
  let draft: NativeDraftOwner
  let target: NativeEditorIdentity
  let path: String
}

struct NativeSubmittedInput {
  let owner: NativeDraftOwner
  let revision: UInt64
  let target: NativeEditorTarget?
  let path: String
  let text: String
  let reason: String

  var editorOwner: NativeEditorOwner? {
    target.map { NativeEditorOwner(draft: owner, target: $0.identity, path: path) }
  }
}

extension AppModel {
  var draft: MemoryDraft? { batchProjection?.draft ?? retainedDraft }
  var stagedItems: [MemoryBatchItem] { draft?.batch?.items ?? [] }
  var candidates: [MemoryReviewCandidate] { batchProjection?.candidates ?? postSaveCandidates }
  var actionableCandidates: [MemoryReviewCandidate] {
    candidates.filter { [.pending, .deferred].contains($0.disposition) }
  }
  var blockedCandidates: [MemoryReviewCandidate] {
    candidates.filter { $0.disposition == .blocked }
  }
  var reviewedCandidates: [MemoryReviewCandidate] {
    candidates.filter { [.approved, .rejected].contains($0.disposition) }
  }
  var selectedCandidate: MemoryReviewCandidate? {
    switch selection {
    case .candidate(let id):
      return (candidates + (batchProjection?.retainedCandidates ?? [])).first {
        $0.change.id.rawValue == id
      }
    case .staged(let id):
      guard case .candidate(let intent) = stagedItems.first(where: { $0.itemID == id })?.intent
      else { return nil }
      return (candidates + (batchProjection?.retainedCandidates ?? [])).first {
        $0.change.id.rawValue == intent.candidateID
      }
    default: return nil
    }
  }
  func summary(for item: MemoryBatchItem) -> String {
    switch item.intent {
    case .manual(let intent):
      return MemoryDocument.reviewText(
        Data((intent.request.replacement ?? intent.request.expected ?? "").utf8))
    case .confirmReviewed(let intent):
      return MemoryDocument.reviewText(Data(intent.entry.expected.utf8))
    case .candidate(let intent):
      if let amendment = intent.amendment {
        return MemoryDocument.reviewText(Data(amendment.replacement.utf8))
      }
      return (candidates + (batchProjection?.retainedCandidates ?? [])).first {
        $0.change.id.rawValue == intent.candidateID
      }.map { MemoryDocument.reviewText($0.change.after) } ?? "Needs Review"
    }
  }

  var selectedItem: MemoryBatchItem? {
    guard case .staged(let id) = selection else { return nil }
    return stagedItems.first { $0.itemID == id }
  }
  var visibleEntries: [ManagedMemoryEntry] {
    (batchProjection?.entries ?? catalog?.entries ?? []).filter { row in
      MemoryDocument.isMemoryContent(Data(row.expected.utf8))
        && (isShowingAllDevices || !row.path.hasPrefix("devices/")
          || configuration.deviceKey.map { row.path.hasPrefix("devices/\($0)/") } == true)
    }
  }
  var isEditing: Bool { editorTarget != nil }
  var isExistingEntry: Bool {
    if case .manual(let entry, _) = editorTarget { return entry != nil }
    return false
  }
  var isAmendingSuggestion: Bool {
    if case .amendment = editorTarget { return true }
    return false
  }
  var isSaveUnresolved: Bool {
    switch saveOutcome {
    case .savedNeedsRecovery, .outcomeUnknown: true
    default: false
    }
  }
  var isDraftDirty: Bool {
    isInputDirty || (batchProjection.map { $0.draft.revision != persistedBatchRevision } ?? false)
  }
  var isRetainedSaveRecoverable: Bool { batchProjection == nil && draft?.batch != nil }
  var isReviewTransitionEnabled: Bool {
    draftRecoveries.isEmpty && !isSaveUnresolved && !isRetainingConsumedInput
  }
  var nativeDraftOwner: NativeDraftOwner? {
    batchProjection.map {
      NativeDraftOwner(generation: workspaceGeneration, draftID: $0.draft.draftID)
    }
  }
  var isSubmittedOwnerConsumed: Bool {
    submittedInput.map { $0.owner.generation != workspaceGeneration } ?? false
  }
  var isRetainingConsumedInput: Bool { isSubmittedOwnerConsumed && isInputDirty }
  var isDiscardEnabled: Bool { !isSaveUnresolved && (draft != nil || isRetainingConsumedInput) }
  var editorOwner: NativeEditorOwner? {
    guard let target = editorTarget,
      let owner = nativeDraftOwner ?? (isSubmittedOwnerConsumed ? submittedInput?.owner : nil)
    else { return nil }
    return NativeEditorOwner(draft: owner, target: target.identity, path: editorPath)
  }

  func requireNativeOwner(_ owner: NativeDraftOwner?) throws -> NativeDraftOwner {
    if isRetainingConsumedInput { throw NativeBatchLifecycleError.retainedInputRequiresDiscard }
    guard let owner else { throw NativeBatchLifecycleError.inputOwnerUnavailable }
    guard owner == nativeDraftOwner else { throw NativeBatchLifecycleError.draftOwnerChanged }
    return owner
  }

  func submittedBoundary(owner: NativeDraftOwner) -> NativeSubmittedInput {
    NativeSubmittedInput(
      owner: owner, revision: inputRevision, target: editorTarget, path: editorPath,
      text: editorText, reason: editorReason)
  }
  var isWaitingForIndependentManualWork: Bool {
    !draftRecoveries.isEmpty && batchProjection == nil
  }
  var isIndependentManualEnabled: Bool {
    isLoaded && !isBusy && !isDreamRunning && !isSaveUnresolved
      && !isInputDirty && stagedItems.isEmpty
      && !(drafts.contains { $0.batch?.isManualOnly == false })
  }
  func isDraftRestorationEnabled(_ value: MemoryDraft) -> Bool {
    guard !isBusy, !isSaveUnresolved, !isRetainingConsumedInput else { return false }
    if draftRecoveries.isEmpty { return true }
    return value.batch?.isManualOnly != false
      && (draft?.draftID == value.draftID || (stagedItems.isEmpty && !isInputDirty))
      && !drafts.contains { $0.draftID != value.draftID && $0.batch?.isManualOnly == false }
  }
  var isSaveEnabled: Bool {
    isLoaded && batchProjection != nil && !isBusy && !isDreamRunning && !isSaveUnresolved
      && (!stagedItems.isEmpty || isInputDirty)
      && (batchProjection?.needsReview.isEmpty ?? true)
      && !(isAmendingSuggestion && isInputDirty)
      && (draftRecoveries.isEmpty || draft?.batch?.isManualOnly == true)
  }
  var reviewActionTitle: String {
    isWorkspaceLoaded && reviewFailure == nil
      ? "Review Suggestions (\(actionableCandidates.count))" : "Review Suggestions"
  }
  var reviewEmptyMessage: String {
    isReviewLoading
      ? "Loading suggestions…"
      : reviewFailure == nil ? "Select a memory or suggestion" : "Suggestions unavailable"
  }

  func applyBatch(_ projection: MemoryBatchProjection) {
    if let current = batchProjection, current.draft.draftID == projection.draft.draftID,
      current.draft.revision > projection.draft.revision
    {
      return
    }
    if batchProjection?.draft.draftID != projection.draft.draftID {
      persistedBatchRevision = nil
      draftRecoveryDetails = nil
    }
    postSaveCandidates = []
    batchProjection = projection
    retainedDraft = nil
    isWorkspaceLoaded = true
  }

  @discardableResult
  func perform(_ command: NativeBatchCommand, owner: NativeDraftOwner? = nil) async throws
    -> NativeBatchUpdate
  {
    let generation = workspaceGeneration
    if let owner { _ = try requireNativeOwner(owner) }
    let update = try await workspace.batch(command, expectedDraftID: owner?.draftID)
    let preparationFailure = await workspace.reviewPreparationFailure
    guard generation == workspaceGeneration else {
      throw NativeBatchLifecycleError.draftOwnerChanged
    }
    if let owner { _ = try requireNativeOwner(owner) }
    applyBatch(update.projection)
    reviewFailure = preparationFailure
    return update
  }

  func loadCandidates() async {
    guard isLoaded, !isBusy, !isDreamRunning, !isSaveUnresolved else { return }
    if isWaitingForIndependentManualWork || isRetainingConsumedInput {
      isWorkspaceLoaded = false
      reviewFailure = await workspace.reviewPreparationFailure
      return
    }
    isReviewLoading = true
    isBusy = true
    postSaveCandidates = []
    defer {
      isReviewLoading = false
      isBusy = false
    }
    do {
      await pauseQueue()
      if isRetainingConsumedInput { throw NativeBatchLifecycleError.retainedInputRequiresDiscard }
      if isSubmittedOwnerConsumed { submittedInput = nil }
      applyBatch(try await workspace.openBatch())
      draftRecoveries = await workspace.draftRecoveries
      reviewFailure = await workspace.reviewPreparationFailure
    } catch {
      reviewFailure = String(describing: error)
      failure = reviewFailure
    }
  }

  func add(path: String = "MEMORY.md") async {
    guard isLoaded, !isBusy, !isDreamRunning, !isSaveUnresolved else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      await pauseQueue()
      try await flushInputAndPersistence()
      _ = try await perform(.path(path))
      submittedInput = nil
      selection = .newMemory(UUID())
      draftRecoveryDetails = nil
      editorTarget = .manual(entry: nil, itemID: UUID())
      editorPath = path
      editorText = ""
      editorReason = ""
      presentation = nil
      section = "Memories"
    } catch { failure = String(describing: error) }
  }

  func addProject(isDeviceSpecific: Bool) async {
    guard isLoaded, !isBusy, !isDreamRunning else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose Project"
    guard panel.runModal() == .OK, let directory = panel.url else { return }
    let bindings = configuration.projectBindings
    do {
      guard
        let key = try await Task.detached(operation: {
          try MemoryStore.projectKey(cwd: directory, projectBindings: bindings)
        }).value
      else { throw WorkspaceError("Choose a Git project directory") }
      if isDeviceSpecific {
        guard let device = configuration.deviceKey else {
          throw WorkspaceError("Set up this device first")
        }
        await add(path: "devices/\(device)/projects/\(key).md")
      } else {
        await add(path: "projects/\(key).md")
      }
    } catch { failure = String(describing: error) }
  }

  func selectMemory(_ requested: NativeMemorySelection?) async {
    var value = requested
    if case .entry(let path, let start) = requested,
      let existing = stagedItems.first(where: {
        if case .manual(let intent) = $0.intent {
          return intent.request.path == path && intent.request.locator?.start == start
        }
        return false
      })
    {
      value = .staged(existing.itemID)
    }
    guard !isBusy, !isDreamRunning, !isSaveUnresolved, value != selection else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await flushEditor()
      submittedInput = nil
      selection = value
      editorTarget = nil
      presentation = nil
      draftRecoveryDetails = nil
      editorText = ""
      editorReason = ""
      switch value {
      case .recovery(let saveID):
        guard let descriptor = draftRecoveries.first(where: { $0.failure.saveID == saveID }) else {
          throw WorkspaceError("Refresh Save recovery")
        }
        draftRecoveryDetails = try await workspace.draftRecoveryDetails(descriptor)
      case .staged(let id):
        _ = try await perform(.select(id))
        guard let item = stagedItems.first(where: { $0.itemID == id }) else { return }
        switch item.intent {
        case .manual(let intent):
          let request = intent.request
          editorPath = request.path ?? "MEMORY.md"
          editorText = request.replacement ?? request.expected ?? ""
          editorReason = request.reason ?? ""
          if request.operation != .delete {
            let entry = request.locator.map {
              NativeManualTarget(path: editorPath, locator: $0, expected: request.expected ?? "")
            }
            editorTarget = .manual(entry: entry, itemID: id)
          }
        case .candidate(let intent):
          if intent.choice == .accept {
            guard
              let candidate = (candidates + (batchProjection?.retainedCandidates ?? [])).first(
                where: {
                  $0.change.id.rawValue == intent.candidateID
                })
            else { throw WorkspaceError("Prepare the staged suggestion again") }
            presentation = try await perform(.acceptance(candidate.change.id)).presentation
          }
        case .confirmReviewed(let intent):
          presentation = try await perform(.reviewed(intent.entry)).presentation
        }
      case .candidate(let id):
        _ = try await perform(.select(nil))
        if let candidate = candidates.first(where: { $0.change.id.rawValue == id }),
          [.pending, .deferred].contains(candidate.disposition), isReviewTransitionEnabled
        {
          presentation = try await perform(.acceptance(candidate.change.id)).presentation
        }
      case .entry(let path, let start):
        _ = try await perform(.select(nil))
        if let entry = visibleEntries.first(where: { $0.path == path && $0.locator.start == start })
        {
          editorPath = path
          editorText = try MemoryDocument.editableEntry(Data(entry.expected.utf8))
          if entry.isMutable {
            editorTarget = .manual(
              entry: NativeManualTarget(
                path: entry.path, locator: entry.locator, expected: entry.expected), itemID: UUID())
          }
        }
      default: break
      }
    } catch { failure = String(describing: error) }
  }

  func editSuggestion() async {
    guard !isBusy, isReviewTransitionEnabled, let candidate = selectedCandidate,
      presentation != nil
    else { return }
    do {
      let amendment: MemoryBatchAmendment?
      if case .candidate(let intent) = stagedItems.first(where: {
        if case .candidate(let intent) = $0.intent {
          return intent.candidateID == candidate.change.id.rawValue
        }
        return false
      })?.intent {
        amendment = intent.amendment
      } else {
        amendment = nil
      }
      editorText =
        try amendment?.replacement ?? MemoryDocument.editableEntry(candidate.change.after)
      editorReason = amendment?.reason ?? ""
      editorPath = candidate.change.path
      editorTarget = .amendment(candidate)
      isShowingDiff = false
    } catch { failure = String(describing: error) }
  }

  func setEditorText(_ value: String, owner: NativeEditorOwner?) {
    guard value != editorText,
      isEditorDeliveryAdmitted(owner, isConsumedDuplicate: value == submittedInput?.text)
    else { return }
    editorText = value
    editorChanged()
  }

  func setEditorReason(_ value: String, owner: NativeEditorOwner?) {
    guard value != editorReason,
      isEditorDeliveryAdmitted(owner, isConsumedDuplicate: value == submittedInput?.reason)
    else { return }
    editorReason = value
    editorChanged()
  }

  private func isEditorDeliveryAdmitted(_ owner: NativeEditorOwner?, isConsumedDuplicate: Bool)
    -> Bool
  {
    guard isLoaded, let owner else { return false }
    if isSubmittedOwnerConsumed, let submittedInput, owner == submittedInput.editorOwner {
      guard nativeDraftOwner == nil, !isConsumedDuplicate else { return false }
      if !isRetainingConsumedInput {
        editorTarget = submittedInput.target
        editorPath = submittedInput.path
        editorText = submittedInput.text
        editorReason = submittedInput.reason
      }
      return owner == editorOwner
    }
    return owner == editorOwner
  }

  func editorChanged() {
    guard isLoaded, editorOwner != nil else { return }
    inputRevision &+= 1
    isInputDirty = true
    if isAmendingSuggestion { presentation = nil }
    if !isSubmittingSave, !isSaveUnresolved, !isRetainingConsumedInput { queueAutosave() }
  }

  func queueAutosave() {
    guard !isSubmittingSave, !isSaveUnresolved, let owner = nativeDraftOwner else { return }
    let previous = autosaveTask
    previous?.cancel()
    autosaveID = UUID()
    message = "Draft not yet persisted"
    autosaveTask = Task {
      await previous?.value
      guard !Task.isCancelled, owner == nativeDraftOwner else { return }
      do { try await Task.sleep(for: autosaveDelay) } catch { return }
      guard !Task.isCancelled, owner == nativeDraftOwner else { return }
      do {
        try await flushEditor(owner: owner)
        try await persistIntent(owner: owner)
      } catch {
        guard owner == nativeDraftOwner else { return }
        draftFailure = String(describing: error)
        message = "Draft not yet persisted"
      }
    }
  }

  func flushEditor(owner admittedOwner: NativeDraftOwner? = nil) async throws {
    if let admittedOwner { _ = try requireNativeOwner(admittedOwner) }
    if isRetainingConsumedInput { throw NativeBatchLifecycleError.retainedInputRequiresDiscard }
    guard isInputDirty else { return }
    let owner = try requireNativeOwner(admittedOwner ?? nativeDraftOwner)
    guard let target = editorTarget else { throw NativeBatchLifecycleError.inputOwnerUnavailable }
    let revision = inputRevision
    let retainedSelection = selection
    let text = editorText
    let reason = editorReason
    switch target {
    case .manual(let entry, let id):
      guard let base = draft?.baseCommit else {
        throw NativeBatchLifecycleError.inputOwnerUnavailable
      }
      let update = try await perform(
        .manual(
          MemoryManagementRequest(
            operation: entry == nil ? .add : .update, base: base,
            path: editorPath, locator: entry?.locator, expected: entry?.expected,
            replacement: text, reason: reason), id), owner: owner)
      if selection == retainedSelection {
        editorTarget = .manual(entry: entry, itemID: update.projection.selectedItemID)
        if case .newMemory = selection, let id = update.projection.selectedItemID {
          selection = .staged(id)
        }
      }
    case .amendment(let candidate):
      let update = try await perform(
        .amendment(
          candidate.change.id,
          MemoryBatchAmendment(replacement: text, reason: reason)), owner: owner)
      if revision == inputRevision, selection == retainedSelection {
        presentation = update.presentation
      }
    }
    stagedInputRevision = max(stagedInputRevision, revision)
    isInputDirty = inputRevision != stagedInputRevision
  }

  func persistIntent(owner admittedOwner: NativeDraftOwner? = nil) async throws {
    if let admittedOwner { _ = try requireNativeOwner(admittedOwner) }
    if isRetainingConsumedInput { throw NativeBatchLifecycleError.retainedInputRequiresDiscard }
    guard isDraftDirty else { return }
    let owner = try requireNativeOwner(admittedOwner ?? nativeDraftOwner)
    let persisted = try await workspace.persistBatch(expectedDraftID: owner.draftID)
    _ = try requireNativeOwner(owner)
    persistedBatchRevision = max(persistedBatchRevision ?? 0, persisted.draft.revision)
    applyBatch(persisted)
    if !isDraftDirty {
      draftFailure = nil
      message = "Draft saved locally"
    }
  }

  func flushInputAndPersistence() async throws {
    let owner = nativeDraftOwner
    if isInputDirty { _ = try requireNativeOwner(owner) }
    while true {
      if let previous = autosaveTask {
        let id = autosaveID
        previous.cancel()
        await previous.value
        if let owner { _ = try requireNativeOwner(owner) }
        if id == autosaveID {
          autosaveTask = nil
          autosaveID = nil
        }
        continue
      }
      if isInputDirty {
        _ = try requireNativeOwner(owner)
        try await flushEditor(owner: owner)
      }
      try await persistIntent(owner: owner)
      if autosaveTask == nil, !isDraftDirty {
        if isSubmittedOwnerConsumed { submittedInput = nil }
        return
      }
    }
  }

  func stageEditor() async {
    guard !isBusy, !isDreamRunning, !isSaveUnresolved else { return }
    isBusy = true
    defer { isBusy = false }
    do { try await flushInputAndPersistence() } catch { failure = String(describing: error) }
  }

  func stageShown() async {
    guard !isBusy, isReviewTransitionEnabled, !isInputDirty, let shown = presentation else {
      return
    }
    isBusy = true
    defer { isBusy = false }
    do {
      _ = try await perform(.stage(shown))
      selection = .staged(shown.itemID)
      queueAutosave()
      message = selectedCandidate == nil ? "Review confirmation staged" : "Acceptance staged"
    } catch { failure = String(describing: error) }
  }

  func disposition(_ candidate: MemoryReviewCandidate, isRejected: Bool) async {
    guard !isBusy, isReviewTransitionEnabled else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await flushEditor()
      _ = try await perform(.decision(candidate.change.id, isRejected ? .reject : .deferCandidate))
      editorTarget = nil
      presentation = nil
      queueAutosave()
      message = isRejected ? "Dismissal staged" : "Decide later staged"
    } catch { failure = String(describing: error) }
  }

  func confirmReviewed(_ entry: ManagedMemoryEntry) async {
    guard !isBusy, isReviewTransitionEnabled else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await flushEditor()
      editorTarget = nil
      presentation = try await perform(.reviewed(entry)).presentation
    } catch { failure = String(describing: error) }
  }

  func deleteEntry() async {
    guard !isBusy, !isSaveUnresolved, case .manual(let entry?, let id) = editorTarget,
      let base = draft?.baseCommit
    else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      _ = try await perform(
        .manual(
          MemoryManagementRequest(
            operation: .delete,
            base: base, path: entry.path, locator: entry.locator, expected: entry.expected,
            reason: editorReason), id))
      isInputDirty = false
      editorTarget = nil
      selection = batchProjection?.selectedItemID.map(NativeMemorySelection.staged)
      queueAutosave()
    } catch { failure = String(describing: error) }
  }

  func removeItem(_ id: UUID) async {
    guard !isBusy, !isSaveUnresolved else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await flushEditor()
      _ = try await perform(.remove(id))
      if selection == .staged(id) { clearEditor() }
      queueAutosave()
    } catch { failure = String(describing: error) }
  }

  func undoStaging() async {
    guard !isBusy, !isSaveUnresolved else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await flushEditor()
      guard batchProjection != nil else {
        message = "No staged change to undo"
        return
      }
      let revision = draft?.revision
      _ = try await perform(.undo)
      clearEditor()
      if draft?.revision != revision {
        queueAutosave()
        message = "Staged change undone"
      } else {
        message = "No staged change to undo"
      }
    } catch { failure = String(describing: error) }
  }

  func loadPage(offset: Int) async {
    guard !isBusy, !isSaveUnresolved else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      await pauseQueue()
      try await flushInputAndPersistence()
      _ = try await perform(.page(offset))
      if case .staged = selection {} else { clearEditor() }
    } catch { failure = String(describing: error) }
  }

  func save() async {
    guard isSaveEnabled else { return }
    isBusy = true
    isSubmittingSave = true
    defer {
      isBusy = false
      isSubmittingSave = false
    }
    do {
      await pauseQueue()
      repeat { try await flushInputAndPersistence() } while isDraftDirty || autosaveTask != nil
      guard batchProjection?.needsReview.isEmpty == true else {
        throw WorkspaceError("Review and stage every publishing suggestion again before Save")
      }
      let owner = try requireNativeOwner(nativeDraftOwner)
      submittedInput = submittedBoundary(owner: owner)
      let result = try await workspace.saveBatch(expectedDraftID: owner.draftID)
      _ = try requireNativeOwner(owner)
      await handleSave(result)
    } catch {
      submittedInput = nil
      failure = String(describing: error)
    }
  }

  func handleSave(_ result: MemoryBatchSaveResult) async {
    saveOutcome = result
    switch result {
    case .saved, .decisionsSaved:
      let submitted = submittedInput ?? nativeDraftOwner.map { submittedBoundary(owner: $0) }
      let isConsumedInput =
        submitted.map {
          $0.revision == inputRevision && $0.editorOwner == editorOwner
            && $0.path == editorPath && $0.text == editorText && $0.reason == editorReason
        } ?? !isInputDirty
      workspaceGeneration &+= 1
      message = {
        if case .saved = result { return "Saved changes in one commit" }
        return "Decisions saved"
      }()
      if isConsumedInput {
        clearEditor()
      } else {
        isInputDirty = true
        presentation = nil
        draftFailure = nil
      }
      submittedInput = submitted
      batchProjection = nil
      retainedDraft = nil
      persistedBatchRevision = nil
      isWorkspaceLoaded = false
      await refreshSnapshot(isRepreparingBatch: false)
    case .savedNeedsRecovery:
      message = "Changes saved. Recovery required."
    case .outcomeUnknown:
      message = "Save outcome unknown. Recover before continuing."
    }
  }

  func recoverSave() async {
    guard !isBusy, isSaveUnresolved || isRetainedSaveRecoverable else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      await pauseQueue()
      if let result = try await workspace.recoverBatch(draft) {
        await handleSave(result)
      } else {
        submittedInput = nil
        saveOutcome = nil
        message = "Save was not published"
      }
    } catch { failure = String(describing: error) }
  }

  func discard() async {
    guard !isBusy, !isSaveUnresolved else { return }
    isBusy = true
    defer { isBusy = false }
    autosaveTask?.cancel()
    await autosaveTask?.value
    autosaveTask = nil
    autosaveID = nil
    if isRetainingConsumedInput {
      clearEditor()
      message = "Draft discarded"
      return
    }
    do {
      try await workspace.discardBatch()
      workspaceGeneration &+= 1
      clearEditor()
      batchProjection = nil
      retainedDraft = nil
      persistedBatchRevision = nil
      message = "Draft discarded"
      await refreshSnapshot()
    } catch { failure = String(describing: error) }
  }

  func startIndependentManualBatch() async {
    guard isLoaded, !isBusy, !isDreamRunning, !isSaveUnresolved else { return }
    isConfirmingIndependentManual = false
    isBusy = true
    defer { isBusy = false }
    do {
      try await workspace.verifyIndependentManualProfile(configuration)
      await pauseQueue()
      try await flushInputAndPersistence()
      let opened = try await workspace.startIndependentManualBatch()
      workspaceGeneration &+= 1
      clearEditor()
      applyBatch(opened)
      draftRecoveries = await workspace.draftRecoveries
      message = "Manual batch started; recovery pending"
    } catch { failure = String(describing: error) }
  }

  func restore(_ value: MemoryDraft) async {
    guard !isBusy, !isSaveUnresolved else { return }
    if isRetainingConsumedInput {
      failure = String(describing: NativeBatchLifecycleError.retainedInputRequiresDiscard)
      return
    }
    isBusy = true
    defer { isBusy = false }
    do {
      try await flushInputAndPersistence()
      workspaceGeneration &+= 1
      applyBatch(try await workspace.restoreBatch(value))
      draftRecoveries = await workspace.draftRecoveries
      clearEditor()
      message = "Recovered draft. Publishing suggestions need review."
    } catch {
      retainedDraft = value
      failure = String(describing: error)
    }
  }

  func clearEditor() {
    submittedInput = nil
    selection = nil
    draftRecoveryDetails = nil
    editorTarget = nil
    presentation = nil
    isInputDirty = false
    draftFailure = nil
    editorText = ""
    editorReason = ""
  }
}
