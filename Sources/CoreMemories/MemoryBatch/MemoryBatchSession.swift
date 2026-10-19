import Foundation

package final class MemoryBatchSession {
  let repository: URL
  let drafts: MemoryDraftStore
  let manager: MemoryManagement
  let snapshot: ApprovedDecisionSnapshot
  let checkout: ReviewCheckoutWitness
  let date: Date
  let catalogLimit: Int
  private(set) var catalogOffset: Int
  private(set) var entryCount: Int
  private(set) var candidateCount: Int
  let review: MemoryReviewController?
  private(set) var preparedCandidates: [String: PreparedMemoryBatchCandidate]
  private var catalogCandidateIDs: Set<String>
  private(set) var draft: MemoryDraft
  private let persistenceID = UUID()
  private var expectedDurableDigest: String
  private var selectedItemID: UUID?
  private var undoItems:
    [(
      reviewBinding: String?, items: [MemoryBatchItem],
      candidates: [String: PreparedMemoryBatchCandidate], bytes: Int
    )] = []
  private var undoBytes = 0
  private var presentations: [UUID: MemoryBatchPresentation] = [:]
  private var authority: [UUID: String] = [:]
  private(set) var entries: [ManagedMemoryEntry]

  package init(
    repository: URL, drafts: MemoryDraftStore, review: MemoryReviewController? = nil,
    restoring: MemoryDraft? = nil, configurationURL: URL? = nil, allowedPaths: [String]? = nil,
    date: Date = Date(), catalogLimit: Int = 64, catalogOffset: Int = 0
  ) throws {
    guard date.timeIntervalSince1970.isFinite, (1...256).contains(catalogLimit),
      catalogOffset >= 0
    else {
      throw DreamRunError.limitExceeded
    }
    let store = try MemoryStore(repo: repository, environment: ProcessInfo.processInfo.environment)
    guard store.reviewGit.repo.path == drafts.store.reviewGit.repo.path else {
      throw MemoryError("draft store belongs to another memory repository")
    }
    try verifyMemoryBatchRepository(store, review: review)
    let original = try restoring ?? drafts.prepareDraft()
    self.expectedDurableDigest = try memoryBatchDigest(original)
    let snapshot = try store.reviewSnapshot(base: original.baseCommit)
    guard snapshot.documents.reduce(0, { $0 + ($1.bytes?.count ?? 0) }) <= 16 * 1024 * 1024 else {
      throw DreamRunError.limitExceeded
    }
    guard try store.approvedCommit() == snapshot.base else {
      throw MemoryError("draft base changed; preserve and reconcile the draft")
    }
    let configuration = try configurationURL.map { try MemoryConfiguration.load(from: $0) }
    if let configuration {
      guard configuration.memoryURL.path == repository.path,
        configuration.journal == drafts.journal.path
      else {
        throw MemoryError(
          "selected configuration belongs to another memory repository or draft journal")
      }
      if let review {
        guard configuration.reviewState == review.binding.state,
          try configuration.reviewSources().reviewSourceBinding().rawValue
            == review.binding.sourceBinding
        else {
          throw MemoryError("selected configuration belongs to different review sources")
        }
      }
    }
    let preparedPaths = original.batch?.binding.preparedPaths
    let scopePaths = allowedPaths ?? snapshot.documents.map(\.path)
    let paths = Array(Set(scopePaths + (preparedPaths ?? []))).sorted()
    guard scopePaths.count <= MemoryBatchBinding.maximumAllowedPaths,
      paths.count <= MemoryBatchBinding.maximumAllowedPaths,
      paths.allSatisfy(MemoryDocument.isAllowedPath),
      preparedPaths == nil || preparedPaths == Array(Set(preparedPaths!)).sorted()
    else {
      throw MemoryError("invalid prepared memory scope")
    }
    let binding = MemoryBatchBinding(
      configurationPath: configurationURL?.path,
      configurationDigest: try configuration.map { try memoryBatchDigest($0) },
      allowedPaths: paths,
      reviewBinding: try original.batch?.isManualOnly == true
        ? original.batch?.binding.reviewBinding
        : review.map { try memoryBatchDigest($0.binding) },
      preparedPaths: preparedPaths)
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
    guard items.count <= 256, original.revision < UInt64.max else {
      throw DreamRunError.limitExceeded
    }
    self.draft = MemoryDraft(
      schemaVersion: 2, draftID: original.draftID,
      revision: original.revision + (original.batch == nil ? 1 : 0),
      repositoryBinding: original.repositoryBinding, baseCommit: original.baseCommit,
      created: original.created, operations: [],
      batch: MemoryBatchContents(binding: binding, items: items))
    self.review = review
    let catalog = try review?.preparedBatchCandidates(
      snapshot: snapshot, date: date, limit: catalogLimit, offset: catalogOffset,
      paths: binding.allowedPaths, retaining: Self.candidateIntents(items))
    let prepared = catalog?.rows ?? []
    self.candidateCount = catalog?.count ?? 0
    self.catalogCandidateIDs = catalog?.catalogIDs ?? []
    guard Self.preparedBytes(prepared) <= 16 * 1024 * 1024 else {
      throw DreamRunError.limitExceeded
    }
    self.preparedCandidates = Dictionary(
      uniqueKeysWithValues: prepared.map { ($0.intent.candidateID, $0) })
    self.repository = repository
    self.drafts = drafts
    self.manager = try MemoryManagement(repository: repository)
    self.snapshot = snapshot
    self.checkout = try store.reviewGit.reviewCheckout().witness()
    self.date = date
    self.catalogLimit = catalogLimit
    self.catalogOffset = catalogOffset
    let entryCatalog = Self.entryCatalog(
      snapshot: snapshot, paths: binding.allowedPaths, offset: catalogOffset, limit: catalogLimit)
    guard catalogOffset <= max(entryCatalog.count, catalog?.count ?? 0) else {
      throw DreamRunError.limitExceeded
    }
    self.entryCount = entryCatalog.count
    self.entries = entryCatalog.rows
    if restoring == nil {
      _ = try MemoryReviewEncoding.encode(self.draft)
      try drafts.persistPreparedDraft(original)
    }
  }

  package var projection: MemoryBatchProjection {
    MemoryBatchProjection(
      draft: draft, entries: entries,
      candidates: preparedCandidates.filter { catalogCandidateIDs.contains($0.key) }
        .values.map(\.candidate).sorted { $0.change.id.rawValue < $1.change.id.rawValue },
      retainedEntries: retainedEntries,
      retainedCandidates: preparedCandidates.filter { !catalogCandidateIDs.contains($0.key) }
        .values.map(\.candidate).sorted { $0.change.id.rawValue < $1.change.id.rawValue },
      selectedItemID: selectedItemID, catalogOffset: catalogOffset,
      entryCount: entryCount, candidateCount: candidateCount,
      needsReview: Set(items.filter { $0.isReviewRequired && !isAuthorized($0) }.map(\.itemID)))
  }

  package var persistenceSnapshot: MemoryDraft { draft }

  package var persistenceRequest: MemoryBatchPersistenceRequest {
    MemoryBatchPersistenceRequest(
      draft: draft, sessionID: persistenceID, expectedDigest: expectedDurableDigest)
  }

  package func acknowledgePersistence(_ receipt: MemoryBatchPersistenceReceipt) throws {
    guard receipt.sessionID == persistenceID, receipt.revision <= draft.revision,
      receipt.expectedDigest == expectedDurableDigest || receipt.digest == expectedDurableDigest
    else { throw MemoryError("persistence acknowledgment is stale or belongs to another session") }
    expectedDurableDigest = receipt.digest
  }

  package func save() throws -> MemoryBatchSaveResult {
    try drafts.saveBatch(
      persistenceSnapshot, expectedDigest: expectedDurableDigest,
      review: draft.batch!.isManualOnly ? nil : review,
      checkout: checkout,
      authorized: Set(items.filter(isAuthorized).map(\.itemID)),
      didPersist: { self.expectedDurableDigest = $0 })
  }

  var items: [MemoryBatchItem] { draft.batch!.items }

  private var retainedEntries: [ManagedMemoryEntry] {
    items.compactMap { item in
      guard case .confirmReviewed(let intent) = item.intent,
        !entries.contains(where: {
          $0.path == intent.entry.path && $0.locator == intent.entry.locator
        })
      else { return nil }
      return intent.entry
    }
  }

  @discardableResult
  package func prepareCatalog(offset: Int) throws -> MemoryBatchProjection {
    try prepareCatalog(offset: offset, draft: draft)
  }

  @discardableResult
  package func preparePath(_ path: String) throws -> MemoryBatchProjection {
    guard MemoryDocument.isAllowedPath(path) else { throw MemoryError("invalid memory path") }
    let binding = draft.batch!.binding
    if binding.allowedPaths.contains(path) {
      return try prepareCatalog(offset: catalogOffset)
    }
    guard binding.allowedPaths.count < MemoryBatchBinding.maximumAllowedPaths,
      draft.revision < UInt64.max
    else {
      throw DreamRunError.limitExceeded
    }
    let extended = MemoryBatchBinding(
      configurationPath: binding.configurationPath,
      configurationDigest: binding.configurationDigest,
      allowedPaths: (binding.allowedPaths + [path]).sorted(), reviewBinding: binding.reviewBinding,
      preparedPaths: ((binding.preparedPaths ?? []) + [path]).sorted())
    let next = MemoryDraft(
      schemaVersion: 2, draftID: draft.draftID, revision: draft.revision + 1,
      repositoryBinding: draft.repositoryBinding, baseCommit: draft.baseCommit,
      created: draft.created, operations: [],
      batch: MemoryBatchContents(binding: extended, items: items))
    _ = try MemoryReviewEncoding.encode(next)
    return try prepareCatalog(offset: catalogOffset, draft: next)
  }

  private func prepareCatalog(offset: Int, draft next: MemoryDraft) throws -> MemoryBatchProjection
  {
    guard offset >= 0 else { throw DreamRunError.limitExceeded }
    let store = try MemoryStore(repo: repository, environment: ProcessInfo.processInfo.environment)
    try verifyCatalogContext(store)
    let catalog = try review?.preparedBatchCandidates(
      snapshot: snapshot, date: date, limit: catalogLimit, offset: offset,
      paths: next.batch!.binding.allowedPaths, retaining: Self.candidateIntents(items))
    let prepared = catalog?.rows ?? []
    guard Self.preparedBytes(prepared) <= 16 * 1024 * 1024 else {
      throw DreamRunError.limitExceeded
    }
    let entryCatalog = Self.entryCatalog(
      snapshot: snapshot, paths: next.batch!.binding.allowedPaths, offset: offset,
      limit: catalogLimit)
    guard offset <= max(entryCatalog.count, catalog?.count ?? 0) else {
      throw DreamRunError.limitExceeded
    }
    try verifyCatalogContext(store)
    draft = next
    preparedCandidates = Dictionary(
      uniqueKeysWithValues: prepared.map { ($0.intent.candidateID, $0) })
    catalogCandidateIDs = catalog?.catalogIDs ?? []
    candidateCount = catalog?.count ?? 0
    entryCount = entryCatalog.count
    entries = entryCatalog.rows
    catalogOffset = offset
    presentations = presentations.filter { id, _ in items.contains { $0.itemID == id } }
    return projection
  }

  private func verifyCatalogContext(_ store: MemoryStore) throws {
    try verifyMemoryBatchRepository(store, review: review)
    guard store.reviewGit.repo.path == drafts.store.reviewGit.repo.path else {
      throw MemoryError("draft store belongs to another memory repository")
    }
    let binding = draft.batch!.binding
    if let path = binding.configurationPath {
      let configuration = try MemoryConfiguration.load(from: URL(fileURLWithPath: path))
      guard try memoryBatchDigest(configuration) == binding.configurationDigest else {
        throw MemoryError("selected configuration changed on disk; preserve the batch")
      }
    }
    guard try store.approvedCommit() == snapshot.base,
      try store.reviewGit.reviewCheckout().witness() == checkout,
      try
        (draft.batch!.isManualOnly
        || review.map { try memoryBatchDigest($0.binding) } == binding.reviewBinding)
    else { throw MemoryError("prepared context changed; preserve and reconcile the batch") }
  }

  private static func candidateIntents(_ items: [MemoryBatchItem]) -> [MemoryBatchCandidateIntent] {
    items.compactMap {
      if case .candidate(let intent) = $0.intent { return intent }
      return nil
    }
  }

  private static func preparedBytes(
    _ candidates: some Sequence<PreparedMemoryBatchCandidate>
  ) -> Int {
    candidates.reduce(0) {
      $0 + $1.candidate.change.after.count + ($1.effect?.before.count ?? 0)
        + ($1.effect?.after.count ?? 0)
    }
  }

  private static func entryCatalog(
    snapshot: ApprovedDecisionSnapshot, paths: [String], offset: Int, limit: Int
  ) -> (rows: [ManagedMemoryEntry], count: Int) {
    let scoped = snapshot.reviewEntries().filter {
      paths.contains($0.path) && MemoryDocument.isMemoryContent($0.entry.bytes)
    }
    return (
      scoped.dropFirst(offset).prefix(limit).map { row in
        ManagedMemoryEntry(
          path: row.path, locator: row.entry.locator,
          expected: String(decoding: row.entry.bytes, as: UTF8.self), identity: row.entry.identity,
          reviewed: row.entry.lastReview?.rawValue, revised: row.entry.lastRevision?.rawValue,
          isMutable: row.entry.isMutable, limitation: row.entry.limitation)
      }, scoped.count
    )
  }

  package func presentAcceptance(
    candidateID: SourceDigest, amendment: MemoryBatchAmendment? = nil
  ) throws -> MemoryBatchPresentation {
    guard let prepared = preparedCandidates[candidateID.rawValue], let effect = prepared.effect
    else {
      throw MemoryError("candidate is outside the selectable prepared catalog")
    }
    let staged = Self.candidateIntents(items).first { $0.candidateID == candidateID.rawValue }
    let intent = MemoryBatchCandidateIntent(
      candidateID: prepared.intent.candidateID, admissionHash: prepared.intent.admissionHash,
      choice: .accept, identity: prepared.intent.identity, instant: prepared.intent.instant,
      amendment: amendment ?? staged?.amendment)
    let after = try MemoryReviewController.amendedBatchBytes(
      intent, proposal: effect.originalReviewedProposal!, before: effect.before)
    return try present(
      id: effect.itemID, path: effect.path, before: effect.before, after: after,
      intent: .candidate(intent))
  }

  package func prepareAmendment(
    candidateID: SourceDigest, amendment: MemoryBatchAmendment
  ) throws -> MemoryBatchPresentation {
    let presentation = try presentAcceptance(candidateID: candidateID, amendment: amendment)
    try replace(presentation.itemID, intent: presentation.intent)
    return presentation
  }

  package func stageDecision(candidateID: SourceDigest, choice: MemoryBatchChoice) throws {
    guard choice != .accept, let prepared = preparedCandidates[candidateID.rawValue],
      prepared.candidate.disposition != .approved, prepared.candidate.disposition != .rejected
    else { throw MemoryError("candidate decision is not selectable") }
    let intent = MemoryBatchCandidateIntent(
      candidateID: prepared.intent.candidateID, admissionHash: prepared.intent.admissionHash,
      choice: choice, identity: prepared.intent.identity, instant: prepared.intent.instant,
      amendment: nil)
    let id = memoryBatchIdentity("candidate:\(candidateID.rawValue)")
    try replace(id, intent: .candidate(intent))
    presentations.removeValue(forKey: id)
  }

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
      (entries + retainedEntries).contains(where: {
        $0.path == entry.path && $0.locator == entry.locator && $0.expected == entry.expected
      }), entry.isMutable,
      snapshot.reviewEntries().contains(where: {
        $0.path == entry.path && $0.entry.locator == entry.locator
          && $0.entry.bytes == Data(entry.expected.utf8) && $0.entry.isMutable
          && $0.entry.identity == entry.identity
      })
    else { throw MemoryError("entry is outside the prepared catalog") }
    let id = memoryBatchIdentity("review:\(snapshot.base):\(entry.path):\(entry.locator.start)")
    let staged = items.first { $0.itemID == id }
    let intent: MemoryBatchReviewIntent
    if case .confirmReviewed(let existing) = staged?.intent {
      intent = existing
    } else {
      intent = MemoryBatchReviewIntent(
        entry: entry, identity: entry.identity ?? memoryBatchIdentity("review-entry:\(id)"),
        instant: try MemoryDocument.ReviewInstant(ISO8601DateFormatter().string(from: date)))
    }
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
    guard let previous = undoItems.last else { return }
    let prepared = preparedCandidates.filter { catalogCandidateIDs.contains($0.key) }
      .merging(previous.candidates) { _, retained in retained }
    guard Self.preparedBytes(prepared.values) <= 16 * 1024 * 1024 else {
      throw DreamRunError.limitExceeded
    }
    try update(
      previous.items, restoringReviewBinding: previous.reviewBinding, isRecordingUndo: false)
    preparedCandidates = prepared
    undoItems.removeLast()
    undoBytes -= previous.bytes
    authority = authority.filter { id, digest in
      previous.items.contains { $0.itemID == id && (try? memoryBatchDigest($0)) == digest }
    }
    presentations.removeAll()
  }

  func isAuthorized(_ item: MemoryBatchItem) -> Bool {
    !item.isReviewRequired || authority[item.itemID] == (try? memoryBatchDigest(item))
  }

  func present(
    id: UUID, path: String, before: Data, after: Data, intent: MemoryBatchIntent
  ) throws -> MemoryBatchPresentation {
    let bytes = presentations.values.reduce(0) { $0 + $1.before.count + $1.after.count }
    if presentations[id] == nil && presentations.count >= catalogLimit
      || bytes + before.count + after.count > 16 * 1024 * 1024
    {
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

  private func update(
    _ items: [MemoryBatchItem], restoringReviewBinding: String? = nil,
    isRecordingUndo: Bool = true
  ) throws {
    guard items.count <= 256, draft.revision < UInt64.max else { throw DreamRunError.limitExceeded }
    let current = draft.batch!.binding
    let reviewBinding: String?
    if !isRecordingUndo {
      reviewBinding = restoringReviewBinding
    } else if draft.batch!.isManualOnly,
      !MemoryBatchContents(binding: current, items: items).isManualOnly
    {
      reviewBinding = try review.map { try memoryBatchDigest($0.binding) }
    } else {
      reviewBinding = current.reviewBinding
    }
    let binding = MemoryBatchBinding(
      configurationPath: current.configurationPath,
      configurationDigest: current.configurationDigest, allowedPaths: current.allowedPaths,
      reviewBinding: reviewBinding, preparedPaths: current.preparedPaths)
    let next = MemoryDraft(
      schemaVersion: 2, draftID: draft.draftID, revision: draft.revision + 1,
      repositoryBinding: draft.repositoryBinding, baseCommit: draft.baseCommit,
      created: draft.created, operations: [],
      batch: MemoryBatchContents(binding: binding, items: items))
    _ = try MemoryReviewEncoding.encode(next)
    if isRecordingUndo {
      let retainedIDs = Set(Self.candidateIntents(self.items).map(\.candidateID))
      let retained = preparedCandidates.filter { retainedIDs.contains($0.key) }
      let bytes =
        try MemoryReviewEncoding.encode(self.items).count
        + MemoryReviewEncoding.encode(current.reviewBinding).count
        + Self.preparedBytes(retained.values)
      guard bytes <= 16 * 1024 * 1024 else { throw DreamRunError.limitExceeded }
      while !undoItems.isEmpty, undoItems.count >= 32 || undoBytes + bytes > 16 * 1024 * 1024 {
        undoBytes -= undoItems.removeFirst().bytes
      }
      undoItems.append((current.reviewBinding, self.items, retained, bytes))
      undoBytes += bytes
    }
    draft = next
    let retainedIDs = Set(Self.candidateIntents(items).map(\.candidateID))
      .union(catalogCandidateIDs)
    preparedCandidates = preparedCandidates.filter { retainedIDs.contains($0.key) }
  }
}
