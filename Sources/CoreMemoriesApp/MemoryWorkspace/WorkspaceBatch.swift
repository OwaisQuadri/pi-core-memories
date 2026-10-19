import CoreMemories
import Foundation

actor NativeBatchPersistence {
  private let write:
    @Sendable (MemoryBatchPersistenceRequest, URL, URL) async throws ->
      MemoryBatchPersistenceReceipt

  init(
    write:
      @escaping @Sendable (MemoryBatchPersistenceRequest, URL, URL) async throws ->
      MemoryBatchPersistenceReceipt = {
        try MemoryDraftStore(repository: $1, journal: $2).persistBatch($0)
      }
  ) { self.write = write }

  func persist(
    _ request: MemoryBatchPersistenceRequest, repository: URL, journal: URL
  ) async throws -> MemoryBatchPersistenceReceipt {
    try await write(request, repository, journal)
  }
}

struct NativePendingPersistence {
  let id: UUID
  let request: MemoryBatchPersistenceRequest
  var task: Task<MemoryBatchPersistenceReceipt, Error>?
  var attemptID: UUID?
}

enum NativeBatchLifecycleError: Error {
  case draftOwnerChanged
  case inputOwnerUnavailable
  case retainedInputRequiresDiscard
}

extension NativeBatchLifecycleError: CustomStringConvertible {
  var description: String {
    switch self {
    case .draftOwnerChanged: "The native draft owner is no longer active"
    case .inputOwnerUnavailable: "Open a native draft before staging input"
    case .retainedInputRequiresDiscard: "Discard retained unsaved input before continuing"
    }
  }
}

enum NativeBatchCommand: Sendable {
  case select(UUID?)
  case manual(MemoryManagementRequest, UUID?)
  case acceptance(SourceDigest)
  case amendment(SourceDigest, MemoryBatchAmendment)
  case stage(MemoryBatchPresentation)
  case decision(SourceDigest, MemoryBatchChoice)
  case reviewed(ManagedMemoryEntry)
  case remove(UUID)
  case undo
  case page(Int)
  case path(String)
}

struct NativeBatchUpdate: Sendable {
  let projection: MemoryBatchProjection
  let presentation: MemoryBatchPresentation?
}

extension Workspace {
  func availableReviewController() throws -> MemoryReviewController? {
    guard
      FileManager.default.fileExists(
        atPath: configuration.stateURL.appendingPathComponent("root.json").path)
    else { return nil }
    return try reviewController()
  }

  func optionalReviewCatalog() -> (
    controller: MemoryReviewController?, candidates: [MemoryReviewCandidate]
  ) {
    do {
      let controller = try availableReviewController()
      let candidates = try controller?.list() ?? []
      reviewPreparationFailure = nil
      return (controller, candidates)
    } catch {
      review = nil
      reviewPreparationFailure = String(describing: error)
      return (nil, [])
    }
  }

  func reviewCandidatePage() -> (candidates: [MemoryReviewCandidate], failure: String?) {
    let catalog = optionalReviewCatalog()
    let page = catalog.candidates.sorted { left, right in
      let leftOrder = left.disposition == .approved || left.disposition == .rejected ? 1 : 0
      let rightOrder = right.disposition == .approved || right.disposition == .rejected ? 1 : 0
      return leftOrder == rightOrder
        ? left.change.id.rawValue < right.change.id.rawValue : leftOrder < rightOrder
    }.prefix(64).sorted { $0.change.id.rawValue < $1.change.id.rawValue }
    return (page, reviewPreparationFailure)
  }

  func openBatch(catalogLimit: Int = 64) throws -> MemoryBatchProjection {
    if let session { return session.projection }
    guard unresolvedSave == nil else { throw WorkspaceError("Resolve the previous Save first") }
    let store = try editorStore()
    let suggestions = optionalReviewCatalog()
    let inspection = try store.inspectDrafts(review: suggestions.controller)
    draftRecoveries = inspection.recoveryRequired
    var restored = currentDraft
    if restored == nil {
      guard inspection.recoveryRequired.isEmpty else {
        throw WorkspaceError(
          "Choose or start independent manual work explicitly; Save recovery remains pending")
      }
      restored = inspection.drafts.last
    }
    if let legacy = restored, legacy.batch == nil, !legacy.operations.isEmpty,
      try store.recoverSave(
        draftID: legacy.draftID, expectedRevision: legacy.revision,
        idempotencyKey: "native-save-\(legacy.revision)") != nil
    {
      try store.discard(draftID: legacy.draftID, expectedRevision: legacy.revision)
      restored = nil
      currentDraft = nil
    }
    let opened = try prepareBatch(
      restoring: restored, suggestions: suggestions, catalogLimit: catalogLimit)
    session = opened
    currentDraft = opened.projection.draft
    durableRevision = restored?.revision ?? 0
    return opened.projection
  }

  private func prepareBatch(
    restoring: MemoryDraft?,
    suggestions: (controller: MemoryReviewController?, candidates: [MemoryReviewCandidate]),
    catalogLimit: Int = 64
  ) throws -> MemoryBatchSession {
    let store = try editorStore()
    let controller = suggestions.controller
    let catalog = try MemoryManagement(repository: configuration.memoryURL).execute(
      .init(operation: .list))
    var paths = Set(catalog.entries.map(\.path) + ["MEMORY.md"])
    for candidate in suggestions.candidates { paths.insert(candidate.change.path) }
    for key in configuration.projectBindings.values { paths.insert("projects/\(key).md") }
    if let device = configuration.deviceKey {
      paths.insert("devices/\(device)/MEMORY.md")
      for key in configuration.projectBindings.values {
        paths.insert("devices/\(device)/projects/\(key).md")
      }
    }
    var created: MemoryBatchSession?
    do {
      let opened = try MemoryBatchSession(
        repository: configuration.memoryURL, drafts: store, review: controller,
        restoring: restoring, configurationURL: configURL,
        allowedPaths: restoring?.batch?.binding.allowedPaths ?? paths.sorted(),
        catalogLimit: catalogLimit)
      if restoring == nil { created = opened }
      for path in paths.sorted()
      where !opened.projection.draft.batch!.binding.allowedPaths.contains(path) {
        try opened.preparePath(path)
      }
      return opened
    } catch {
      if let created {
        try store.discard(draftID: created.projection.draft.draftID, expectedRevision: 0)
      }
      throw error
    }
  }

  private func admitBatch(expectedDraftID: UUID?) throws {
    guard unresolvedSave == nil else { throw WorkspaceError("Resolve the previous Save first") }
    if let expectedDraftID {
      guard session?.projection.draft.draftID == expectedDraftID else {
        throw NativeBatchLifecycleError.draftOwnerChanged
      }
    } else {
      _ = try openBatch()
    }
  }

  func batch(_ command: NativeBatchCommand, expectedDraftID: UUID? = nil) throws
    -> NativeBatchUpdate
  {
    try admitBatch(expectedDraftID: expectedDraftID)
    let session = session!
    if !draftRecoveries.isEmpty {
      switch command {
      case .acceptance, .amendment, .stage, .decision, .reviewed:
        throw WorkspaceError("Resolve Save recovery before staging review-bearing changes")
      default: break
      }
    }
    var presentation: MemoryBatchPresentation?
    switch command {
    case .select(let id): session.select(id)
    case .manual(let request, let id):
      session.select(try session.stageManual(request, itemID: id))
    case .acceptance(let id): presentation = try session.presentAcceptance(candidateID: id)
    case .amendment(let id, let amendment):
      presentation = try session.prepareAmendment(candidateID: id, amendment: amendment)
    case .stage(let shown):
      try session.stage(shown)
      session.select(shown.itemID)
    case .decision(let id, let choice): try session.stageDecision(candidateID: id, choice: choice)
    case .reviewed(let entry): presentation = try session.presentConfirmReviewed(entry)
    case .remove(let id): try session.remove(id)
    case .undo: try session.undo()
    case .page(let offset): try session.prepareCatalog(offset: offset)
    case .path(let path): try session.preparePath(path)
    }
    currentDraft = session.projection.draft
    return NativeBatchUpdate(projection: session.projection, presentation: presentation)
  }

  func persistBatch(expectedDraftID: UUID? = nil) async throws -> MemoryBatchProjection {
    try admitBatch(expectedDraftID: expectedDraftID)
    while let session {
      if pendingPersistence == nil {
        if durableRevision == session.projection.draft.revision { return session.projection }
        pendingPersistence = NativePendingPersistence(
          id: UUID(), request: session.persistenceRequest, task: nil, attemptID: nil)
      }
      var pending = pendingPersistence!
      if pending.task == nil {
        let request = pending.request
        let repository = configuration.memoryURL
        let journal = URL(fileURLWithPath: configuration.journal)
        pending.attemptID = UUID()
        pending.task = Task {
          try await persistence.persist(request, repository: repository, journal: journal)
        }
        pendingPersistence = pending
      }
      do {
        let receipt = try await pending.task!.value
        if pendingPersistence?.id == pending.id {
          try session.acknowledgePersistence(receipt)
          durableRevision = receipt.revision
          pendingPersistence = nil
        }
      } catch {
        if pendingPersistence?.id == pending.id, pendingPersistence?.attemptID == pending.attemptID
        {
          pendingPersistence?.task = nil
        }
        throw error
      }
    }
    throw WorkspaceError("The active session changed during persistence")
  }

  func saveBatch(expectedDraftID: UUID? = nil) async throws -> MemoryBatchSaveResult {
    try admitBatch(expectedDraftID: expectedDraftID)
    _ = try await persistBatch(expectedDraftID: expectedDraftID)
    try admitBatch(expectedDraftID: expectedDraftID)
    if session!.projection.draft.batch?.isManualOnly == false {
      let inspection = try editorStore().inspectDrafts(review: availableReviewController())
      draftRecoveries = inspection.recoveryRequired
      guard inspection.recoveryRequired.isEmpty else {
        throw WorkspaceError("Resolve Save recovery before saving review-bearing changes")
      }
    }
    let result = try session!.save()
    retainBatchOutcome(result)
    return result
  }

  func recoverBatch(_ retained: MemoryDraft? = nil) throws -> MemoryBatchSaveResult? {
    guard let draft = unresolvedSave ?? retained ?? currentDraft, draft.batch != nil,
      session == nil || session?.projection.draft.draftID == draft.draftID
    else { throw WorkspaceError("Select the retained draft before recovering its Save") }
    currentDraft = draft
    let result = try editorStore().recoverBatch(
      draftID: draft.draftID, revision: draft.revision,
      review: draft.batch?.isManualOnly == true ? nil : availableReviewController())
    if let result { retainBatchOutcome(result) } else { unresolvedSave = nil }
    return result
  }

  private func retainBatchOutcome(_ result: MemoryBatchSaveResult) {
    switch result {
    case .saved, .decisionsSaved:
      session = nil
      currentDraft = nil
      durableRevision = nil
      unresolvedSave = nil
    case .savedNeedsRecovery, .outcomeUnknown:
      unresolvedSave = session?.projection.draft ?? currentDraft
    }
  }

  func restoreBatch(_ draft: MemoryDraft) async throws -> MemoryBatchProjection {
    guard unresolvedSave == nil else { throw WorkspaceError("Resolve the previous Save first") }
    if session != nil { _ = try await persistBatch() }
    let inspection = try editorStore().inspectDrafts(review: optionalReviewCatalog().controller)
    guard
      let latest = inspection.drafts.first(where: {
        $0.draftID == draft.draftID && $0.revision == draft.revision
      })
    else { throw WorkspaceError("Draft changed; refresh recovery") }
    if !inspection.recoveryRequired.isEmpty {
      guard latest.batch?.isManualOnly != false else {
        throw WorkspaceError("Review-bearing drafts require verified Save history")
      }
      try verifyIndependentManualSelection(inspection, selecting: latest.draftID)
    }
    let previousSession = session
    let previousDraft = currentDraft
    let previousRevision = durableRevision
    session = nil
    currentDraft = latest
    durableRevision = latest.revision
    do { return try openBatch() } catch {
      session = previousSession
      currentDraft = previousDraft
      durableRevision = previousRevision
      throw error
    }
  }

  private func verifyIndependentManualSelection(
    _ inspection: MemoryDraftInspection, selecting draftID: UUID? = nil
  ) throws {
    guard unresolvedSave == nil else { throw WorkspaceError("Resolve the previous Save first") }
    let active = session?.projection.draft ?? currentDraft
    let isOtherActive =
      active.map {
        $0.draftID != draftID && !($0.batch?.items.isEmpty ?? $0.operations.isEmpty)
      } ?? false
    let isOtherMixed = inspection.drafts.contains {
      $0.draftID != draftID && $0.batch?.isManualOnly == false
    }
    guard !isOtherActive, !isOtherMixed else {
      throw WorkspaceError("Resolve the active draft before starting independent manual work")
    }
  }

  func verifyIndependentManualProfile(_ profile: MemoryConfiguration) throws {
    guard isLoaded, FileManager.default.fileExists(atPath: configURL.path),
      try configurationIdentity(profile) == configurationIdentity(configuration),
      try configurationIdentity(MemoryConfiguration.load(from: configURL))
        == configurationIdentity(configuration)
    else { throw WorkspaceError("Load the matching profile before starting manual work") }
  }

  func startIndependentManualBatch() async throws -> MemoryBatchProjection {
    try verifyIndependentManualProfile(configuration)
    guard unresolvedSave == nil else { throw WorkspaceError("Resolve the previous Save first") }
    if session != nil { _ = try await persistBatch() }
    let inspection = try editorStore().inspectDrafts(review: optionalReviewCatalog().controller)
    guard !inspection.recoveryRequired.isEmpty else {
      throw WorkspaceError("Refresh the workspace before starting independent manual work")
    }
    try verifyIndependentManualSelection(inspection)
    let opened = try prepareBatch(restoring: nil, suggestions: (nil, []))
    session = opened
    currentDraft = opened.projection.draft
    durableRevision = 0
    draftRecoveries = inspection.recoveryRequired
    return opened.projection
  }

  func draftRecoveryDetails(_ recovery: MemoryDraftRecovery) throws -> MemoryDraft {
    try editorStore().recoveryDetails(recovery)
  }

  func discardBatch() async throws {
    guard unresolvedSave == nil else { throw WorkspaceError("Resolve the previous Save first") }
    if session != nil { _ = try await persistBatch() }
    if let draft = currentDraft {
      try editorStore().discard(
        draftID: draft.draftID, expectedRevision: durableRevision ?? draft.revision)
    }
    session = nil
    currentDraft = nil
    durableRevision = nil
  }

  func closeBatch() -> MemoryDraft? {
    precondition(pendingPersistence == nil)
    session = nil
    review = nil
    return currentDraft
  }

  func reprepareBatch() async throws -> MemoryBatchProjection {
    guard unresolvedSave == nil else { throw WorkspaceError("Resolve the previous Save first") }
    if session != nil { _ = try await persistBatch() }
    let previous = session?.projection.draft ?? currentDraft
    let isEmpty = previous.map { $0.batch?.items.isEmpty ?? $0.operations.isEmpty } ?? false
    let suggestions = optionalReviewCatalog()
    let inspection = try editorStore().inspectDrafts(review: suggestions.controller)
    draftRecoveries = inspection.recoveryRequired
    guard previous != nil || inspection.recoveryRequired.isEmpty else {
      throw WorkspaceError("Choose or start independent manual work explicitly")
    }
    let isReplacingEmpty = isEmpty && inspection.recoveryRequired.isEmpty
    let opened = try prepareBatch(
      restoring: isReplacingEmpty ? nil : previous, suggestions: suggestions)
    if isReplacingEmpty, let previous {
      do {
        try editorStore().discard(
          draftID: previous.draftID, expectedRevision: durableRevision ?? previous.revision)
      } catch {
        try editorStore().discard(draftID: opened.projection.draft.draftID, expectedRevision: 0)
        throw error
      }
    }
    session = opened
    currentDraft = opened.projection.draft
    durableRevision = isReplacingEmpty || previous == nil ? 0 : previous?.revision
    return opened.projection
  }
}
