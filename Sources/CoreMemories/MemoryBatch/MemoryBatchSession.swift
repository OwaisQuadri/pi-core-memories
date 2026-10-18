import Foundation

package final class MemoryBatchSession {
  let repository: URL
  let drafts: MemoryDraftStore
  let manager: MemoryManagement
  let snapshot: ApprovedDecisionSnapshot
  let checkout: ReviewCheckoutWitness
  let date: Date
  let catalogLimit: Int
  private(set) var draft: MemoryDraft
  private var selectedItemID: UUID?
  private var undoItems: [[MemoryBatchItem]] = []
  private var presentations: [UUID: MemoryBatchPresentation] = [:]
  private var authority: [UUID: String] = [:]
  let entries: [ManagedMemoryEntry]

  package init(
    repository: URL, drafts: MemoryDraftStore, restoring: MemoryDraft? = nil,
    configurationURL: URL? = nil, allowedPaths: [String]? = nil,
    date: Date = Date(), catalogLimit: Int = 64
  ) throws {
    guard date.timeIntervalSince1970.isFinite, (1...256).contains(catalogLimit) else {
      throw DreamRunError.limitExceeded
    }
    let store = try MemoryStore(repo: repository, environment: ProcessInfo.processInfo.environment)
    let original = try restoring ?? drafts.create()
    let snapshot = try store.reviewSnapshot(base: original.baseCommit)
    guard try store.approvedCommit() == snapshot.base else {
      throw MemoryError("draft base changed; preserve and reconcile the draft")
    }
    let configuration = try configurationURL.map { try MemoryConfiguration.load(from: $0) }
    if let configuration {
      guard configuration.memoryURL.path == repository.path else {
        throw MemoryError("selected configuration belongs to another memory repository")
      }
    }
    let paths = allowedPaths ?? snapshot.documents.map(\.path)
    guard paths.count <= 256, paths.allSatisfy(MemoryDocument.isAllowedPath) else {
      throw MemoryError("invalid prepared memory scope")
    }
    let binding = MemoryBatchBinding(
      configurationPath: configurationURL?.path,
      configurationDigest: try configuration.map { try memoryBatchDigest($0) },
      allowedPaths: Array(Set(paths)).sorted(), reviewBinding: nil)
    if let previous = original.batch {
      guard try memoryBatchDigest(previous.binding) == memoryBatchDigest(binding) else {
        throw MemoryError("draft configuration changed; preserve and reconcile the draft")
      }
    }
    let items =
      original.batch?.items
      ?? original.operations.enumerated().map { index, request in
        MemoryBatchItem(
          itemID: memoryBatchIdentity("draft-item:\(original.draftID):\(index)"), generation: 0,
          intent: .manual(
            MemoryBatchManualIntent(
              request: request, identity: memoryBatchIdentity("\(original.draftID):\(index)"),
              date: original.created)))
      }
    guard original.revision < UInt64.max else { throw DreamRunError.limitExceeded }
    self.draft = MemoryDraft(
      schemaVersion: 2, draftID: original.draftID,
      revision: original.revision + (original.batch == nil ? 1 : 0),
      repositoryBinding: original.repositoryBinding, baseCommit: original.baseCommit,
      created: original.created, operations: [],
      batch: MemoryBatchContents(binding: binding, items: items))
    self.repository = repository
    self.drafts = drafts
    self.manager = try MemoryManagement(repository: repository)
    self.snapshot = snapshot
    self.checkout = try store.reviewGit.reviewCheckout().witness()
    self.date = date
    self.catalogLimit = catalogLimit
    self.entries = snapshot.reviewEntries().filter { binding.allowedPaths.contains($0.path) }
      .prefix(catalogLimit).map { row in
        ManagedMemoryEntry(
          path: row.path, locator: row.entry.locator,
          expected: String(decoding: row.entry.bytes, as: UTF8.self), identity: row.entry.identity,
          reviewed: row.entry.lastReview?.rawValue, revised: row.entry.lastRevision?.rawValue,
          isMutable: row.entry.isMutable, limitation: row.entry.limitation)
      }
  }

  package var projection: MemoryBatchProjection {
    MemoryBatchProjection(
      draft: draft, entries: entries, selectedItemID: selectedItemID,
      needsReview: Set(items.filter { $0.isReviewRequired && !isAuthorized($0) }.map(\.itemID)))
  }

  package var persistenceSnapshot: MemoryDraft { draft }

  var items: [MemoryBatchItem] { draft.batch!.items }

  package func select(_ itemID: UUID?) {
    selectedItemID = itemID
  }

  @discardableResult
  package func stageManual(_ request: MemoryManagementRequest, itemID: UUID? = nil) throws -> UUID {
    guard [.add, .update, .delete].contains(request.operation), request.base == snapshot.base,
      let path = request.path, draft.batch!.binding.allowedPaths.contains(path)
    else { throw MemoryError("manual batch item must be scoped CRUD against the prepared base") }
    let id = itemID ?? UUID()
    let previous = items.first { $0.itemID == id }
    let manual: MemoryBatchManualIntent
    if case .manual(let existing) = previous?.intent {
      manual = MemoryBatchManualIntent(
        request: request, identity: existing.identity, date: existing.date)
    } else {
      guard previous == nil else { throw MemoryError("review items cannot become ordinary CRUD") }
      manual = MemoryBatchManualIntent(request: request, identity: UUID(), date: date)
    }
    _ = try manager.prepare(
      request, snapshot: snapshot, date: manual.date, newIdentity: manual.identity)
    try replace(id, intent: .manual(manual))
    return id
  }

  package func presentConfirmReviewed(_ entry: ManagedMemoryEntry) throws -> MemoryBatchPresentation
  {
    guard
      entries.contains(where: {
        $0.path == entry.path && $0.locator == entry.locator && $0.expected == entry.expected
      }), entry.isMutable
    else { throw MemoryError("entry is outside the prepared catalog") }
    let id = memoryBatchIdentity("review:\(snapshot.base):\(entry.path):\(entry.locator.start)")
    let intent = MemoryBatchReviewIntent(
      entry: entry, identity: entry.identity ?? memoryBatchIdentity("review-entry:\(id)"),
      instant: try MemoryDocument.ReviewInstant(ISO8601DateFormatter().string(from: date)))
    let after = try MemoryDocument.reviewedBytes(
      Data(entry.expected.utf8), identity: intent.identity, instant: intent.instant)
    return try present(
      id: id, path: entry.path, before: Data(entry.expected.utf8), after: after,
      intent: .confirmReviewed(intent))
  }

  package func stage(_ presentation: MemoryBatchPresentation) throws {
    guard presentations[presentation.itemID]?.reference == presentation.reference,
      try memoryBatchDigest(presentation.intent)
        == presentations[presentation.itemID].map({ try memoryBatchDigest($0.intent) })
    else { throw MemoryError("presentation is stale or belongs to another session") }
    try replace(presentation.itemID, intent: presentation.intent)
    authority[presentation.itemID] = try memoryBatchDigest(
      items.first { $0.itemID == presentation.itemID }!)
  }

  package func remove(_ itemID: UUID) throws {
    guard items.contains(where: { $0.itemID == itemID }) else { return }
    try update(items.filter { $0.itemID != itemID })
    authority.removeValue(forKey: itemID)
    presentations.removeValue(forKey: itemID)
  }

  package func undo() throws {
    guard let previous = undoItems.popLast() else { return }
    try update(previous, isRecordingUndo: false)
    authority = authority.filter { id, digest in
      previous.contains { $0.itemID == id && (try? memoryBatchDigest($0)) == digest }
    }
    presentations.removeAll()
  }

  func isAuthorized(_ item: MemoryBatchItem) -> Bool {
    !item.isReviewRequired || authority[item.itemID] == (try? memoryBatchDigest(item))
  }

  func present(
    id: UUID, path: String, before: Data, after: Data, intent: MemoryBatchIntent
  ) throws -> MemoryBatchPresentation {
    if presentations[id] == nil, presentations.count >= catalogLimit {
      presentations.removeAll()
    }
    let presentation = MemoryBatchPresentation(
      itemID: id, path: path, before: before, after: after,
      digest: SourceDigest(bytes: try MemoryReviewEncoding.encode(intent) + before + after),
      reference: UUID(), intent: intent)
    presentations[id] = presentation
    return presentation
  }

  func replace(_ id: UUID, intent: MemoryBatchIntent) throws {
    var revised = items
    if let index = revised.firstIndex(where: { $0.itemID == id }) {
      guard revised[index].generation < UInt64.max else { throw DreamRunError.limitExceeded }
      revised[index] = MemoryBatchItem(
        itemID: id, generation: revised[index].generation + 1, intent: intent)
    } else {
      revised.append(MemoryBatchItem(itemID: id, generation: 0, intent: intent))
    }
    try update(revised)
    authority.removeValue(forKey: id)
  }

  private func update(_ items: [MemoryBatchItem], isRecordingUndo: Bool = true) throws {
    guard items.count <= 256, draft.revision < UInt64.max else { throw DreamRunError.limitExceeded }
    let next = MemoryDraft(
      schemaVersion: 2, draftID: draft.draftID, revision: draft.revision + 1,
      repositoryBinding: draft.repositoryBinding, baseCommit: draft.baseCommit,
      created: draft.created, operations: [],
      batch: MemoryBatchContents(binding: draft.batch!.binding, items: items))
    _ = try MemoryReviewEncoding.encode(next)
    if isRecordingUndo {
      if undoItems.count == 32 { undoItems.removeFirst() }
      undoItems.append(self.items)
    }
    draft = next
  }
}
