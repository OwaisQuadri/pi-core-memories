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
}

extension AppModel {
  var draft: MemoryDraft? { batchProjection?.draft ?? retainedDraft }
  var stagedItems: [MemoryBatchItem] { draft?.batch?.items ?? [] }
  var candidates: [MemoryReviewCandidate] { batchProjection?.candidates ?? [] }
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
  var isReviewTransitionEnabled: Bool { draftRecoveries.isEmpty && !isSaveUnresolved }
  var isIndependentManualEnabled: Bool {
    isLoaded && !isBusy && !isDreamRunning && !isSaveUnresolved
      && !isInputDirty && stagedItems.isEmpty
      && !(drafts.contains { $0.batch?.isManualOnly == false })
  }
  func isDraftRestorationEnabled(_ value: MemoryDraft) -> Bool {
    guard !isBusy, !isSaveUnresolved else { return false }
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
    batchProjection = projection
    retainedDraft = nil
    isWorkspaceLoaded = true
  }

  @discardableResult
  func perform(_ command: NativeBatchCommand) async throws -> NativeBatchUpdate {
    let generation = workspaceGeneration
    let update = try await workspace.batch(command)
    guard generation == workspaceGeneration else { throw CancellationError() }
    applyBatch(update.projection)
    reviewFailure = await workspace.reviewPreparationFailure
    return update
  }

  func loadCandidates() async {
    guard isLoaded, !isBusy, !isDreamRunning, !isSaveUnresolved else { return }
    isReviewLoading = true
    isBusy = true
    defer {
      isReviewLoading = false
      isBusy = false
    }
    do {
      await pauseQueue()
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

  func editorChanged() {
    guard isLoaded, editorTarget != nil, !isSaveUnresolved else { return }
    inputRevision &+= 1
    isInputDirty = true
    if isAmendingSuggestion { presentation = nil }
    queueAutosave()
  }

  func queueAutosave() {
    let previous = autosaveTask
    previous?.cancel()
    message = "Draft not yet persisted"
    autosaveTask = Task {
      await previous?.value
      do {
        try Task.checkCancellation()
        try await Task.sleep(for: autosaveDelay)
        try Task.checkCancellation()
        try await flushEditor()
        try await persistIntent()
      } catch is CancellationError {} catch {
        draftFailure = String(describing: error)
        message = "Draft not yet persisted"
      }
    }
  }

  func flushEditor() async throws {
    guard isInputDirty, let target = editorTarget else { return }
    let revision = inputRevision
    let retainedSelection = selection
    let text = editorText
    let reason = editorReason
    switch target {
    case .manual(let entry, let id):
      guard let base = draft?.baseCommit else {
        throw WorkspaceError("Open the memory workspace first")
      }
      let update = try await perform(
        .manual(
          MemoryManagementRequest(
            operation: entry == nil ? .add : .update, base: base,
            path: editorPath, locator: entry?.locator, expected: entry?.expected,
            replacement: text, reason: reason), id))
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
          MemoryBatchAmendment(replacement: text, reason: reason)))
      if revision == inputRevision, selection == retainedSelection {
        presentation = update.presentation
      }
    }
    stagedInputRevision = max(stagedInputRevision, revision)
    isInputDirty = inputRevision != stagedInputRevision
  }

  func persistIntent() async throws {
    guard batchProjection != nil, isDraftDirty else { return }
    let generation = workspaceGeneration
    let persisted = try await workspace.persistBatch()
    guard generation == workspaceGeneration,
      batchProjection?.draft.draftID == persisted.draft.draftID
    else { return }
    persistedBatchRevision = max(persistedBatchRevision ?? 0, persisted.draft.revision)
    applyBatch(persisted)
    if !isDraftDirty {
      draftFailure = nil
      message = "Draft saved locally"
    }
  }

  func flushInputAndPersistence() async throws {
    let previous = autosaveTask
    previous?.cancel()
    await previous?.value
    autosaveTask = nil
    while isInputDirty { try await flushEditor() }
    try await persistIntent()
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
    defer { isBusy = false }
    do {
      await pauseQueue()
      try await flushInputAndPersistence()
      guard batchProjection?.needsReview.isEmpty == true else {
        throw WorkspaceError("Review and stage every publishing suggestion again before Save")
      }
      await handleSave(try await workspace.saveBatch())
    } catch { failure = String(describing: error) }
  }

  func handleSave(_ result: MemoryBatchSaveResult) async {
    saveOutcome = result
    switch result {
    case .saved, .decisionsSaved:
      workspaceGeneration &+= 1
      message = {
        if case .saved = result { return "Saved changes in one commit" }
        return "Decisions saved"
      }()
      clearEditor()
      batchProjection = nil
      retainedDraft = nil
      persistedBatchRevision = nil
      await refreshSnapshot()
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
