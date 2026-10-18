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

  func openBatch(catalogLimit: Int = 64) throws -> MemoryBatchProjection {
    if let session { return session.projection }
    guard unresolvedSave == nil else { throw WorkspaceError("Resolve the previous Save first") }
    let store = try editorStore()
    let controller = try availableReviewController()
    let restored = try currentDraft ?? store.list(review: controller).last
    let catalog = try MemoryManagement(repository: configuration.memoryURL).execute(
      .init(operation: .list))
    var paths = Set(catalog.entries.map(\.path) + ["MEMORY.md"])
    for candidate in try controller?.list() ?? [] { paths.insert(candidate.change.path) }
    for key in configuration.projectBindings.values { paths.insert("projects/\(key).md") }
    if let device = configuration.deviceKey {
      paths.insert("devices/\(device)/MEMORY.md")
      for key in configuration.projectBindings.values {
        paths.insert("devices/\(device)/projects/\(key).md")
      }
    }
    let opened = try MemoryBatchSession(
      repository: configuration.memoryURL, drafts: store, review: controller,
      restoring: restored, configurationURL: configURL,
      allowedPaths: restored?.batch?.binding.allowedPaths ?? paths.sorted(),
      catalogLimit: catalogLimit)
    for path in paths.sorted()
    where !opened.projection.draft.batch!.binding.allowedPaths.contains(path) {
      try opened.preparePath(path)
    }
    session = opened
    currentDraft = opened.projection.draft
    durableRevision = restored?.revision ?? 0
    return opened.projection
  }

  func batch(_ command: NativeBatchCommand) throws -> NativeBatchUpdate {
    guard unresolvedSave == nil else { throw WorkspaceError("Resolve the previous Save first") }
    _ = try openBatch()
    let session = session!
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

  func persistBatch() async throws -> MemoryBatchProjection {
    _ = try openBatch()
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

  func saveBatch() async throws -> MemoryBatchSaveResult {
    guard unresolvedSave == nil else { throw WorkspaceError("Resolve the previous Save first") }
    _ = try await persistBatch()
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
      draftID: draft.draftID, revision: draft.revision, review: availableReviewController())
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
    guard
      let latest = try editorStore().list(review: availableReviewController()).first(where: {
        $0.draftID == draft.draftID && $0.revision == draft.revision
      })
    else { throw WorkspaceError("Draft changed; refresh recovery") }
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
    if session != nil { _ = try await persistBatch() }
    let previous = session
    session = nil
    do { return try openBatch() } catch {
      session = previous
      throw error
    }
  }
}
