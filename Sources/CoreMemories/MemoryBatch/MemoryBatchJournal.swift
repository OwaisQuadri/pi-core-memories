import Foundation

extension MemoryDraftStore {
  func saveBatch(
    _ draft: MemoryDraft, expectedDigest: String, review: MemoryReviewController?,
    checkout: ReviewCheckoutWitness, authorized: Set<UUID>, didPersist: ((String) -> Void)? = nil
  ) throws -> MemoryBatchSaveResult {
    do {
      return try performBatchSave(
        draft, expectedDigest: expectedDigest, review: review, checkout: checkout,
        authorized: authorized, didPersist: didPersist)
    } catch {
      let saveID = try memoryBatchDigest(draft)
      let isKnownUnpublished: Bool
      do {
        let audit = try MemoryBatchReplay.directCommit(
          "refs/memory-batches/\(saveID)", git: store.reviewGit)
        let isReceiptPresent = try root.isPresent("batch-receipt-\(saveID).json")
        let isDecisionPresent =
          try review?.root.isPresent("batch-decisions-\(saveID).json") ?? false
        let isAttemptPresent = try root.isPresent("batch-attempt-\(saveID).json")
        let main = try store.approvedCommit()
        isKnownUnpublished =
          audit == nil && !isReceiptPresent && !isDecisionPresent
          && (!isAttemptPresent || main == draft.baseCommit)
      } catch {
        return .outcomeUnknown(
          saveID: saveID, details: "Save outcome could not be inspected: \(error)")
      }
      if isKnownUnpublished { throw error }
      return .outcomeUnknown(
        saveID: saveID, details: "Save requires exact outcome recovery: \(error)")
    }
  }

  private func performBatchSave(
    _ draft: MemoryDraft, expectedDigest: String, review: MemoryReviewController?,
    checkout: ReviewCheckoutWitness, authorized: Set<UUID>, didPersist: ((String) -> Void)?
  ) throws -> MemoryBatchSaveResult {
    try withBatchJournal(review) { state in
      let publisher = batchPublisher(review)
      do {
        if let recovered = try publisher.recover(draft) { return recovered }
      } catch {
        return .outcomeUnknown(saveID: try memoryBatchDigest(draft), details: "\(error)")
      }
      try flushBatch(
        draft, expectedDigest: expectedDigest, review: review, didPersist: didPersist)
      try root.installReviewFile(
        DreamRunEncoding.encode(draft), name: "\(draft.draftID)-\(draft.revision).json")
      return try publisher.save(
        draft, checkout: checkout, authorized: authorized, leaseState: state)
    }
  }

  package func persistBatch(_ request: MemoryBatchPersistenceRequest) throws
    -> MemoryBatchPersistenceReceipt
  {
    try locked {
      try flushBatch(request.draft, expectedDigest: request.expectedDigest)
      return MemoryBatchPersistenceReceipt(
        revision: request.draft.revision, sessionID: request.sessionID,
        expectedDigest: request.expectedDigest, digest: try memoryBatchDigest(request.draft))
    }
  }

  private func flushBatch(
    _ draft: MemoryDraft, expectedDigest: String, review: MemoryReviewController? = nil,
    didPersist: ((String) -> Void)? = nil
  ) throws {
    let bytes = try MemoryReviewEncoding.encode(draft)
    let digest = SourceDigest(bytes: bytes).rawValue
    guard let durable = try drafts(only: draft.draftID, review: review).first,
      durable.repositoryBinding == draft.repositoryBinding, durable.baseCommit == draft.baseCommit,
      durable.created == draft.created
    else { throw MemoryError("draft changed or was discarded before persistence") }
    let durableDigest = try memoryBatchDigest(durable)
    guard durableDigest == expectedDigest || durableDigest == digest else {
      throw MemoryError("durable draft changed; preserve and reconcile local intent")
    }
    if durableDigest != digest {
      if durable.schemaVersion == 1 {
        try root.installReviewFile(
          DreamRunEncoding.encode(durable), name: "\(durable.draftID)-\(durable.revision).json")
      }
      do {
        try persist(draft)
      } catch {
        if (try? root.read(
          "\(draft.draftID)-current.json", maximum: MemoryReviewEncoding.maximumFileBytes)) == bytes
        {
          didPersist?(digest)
        }
        throw error
      }
    }
    didPersist?(digest)
  }

  package func recoverBatch(
    draftID: UUID, revision: UInt64, review: MemoryReviewController? = nil
  ) throws -> MemoryBatchSaveResult? {
    let draft = try locked { try read(draftID, revision: revision) }
    guard draft.batch != nil else {
      throw MemoryError("legacy draft recovery uses its original receipt")
    }
    do {
      return try withBatchJournal(review) { _ in try batchPublisher(review).recover(draft) }
    } catch {
      return .outcomeUnknown(saveID: try memoryBatchDigest(draft), details: "\(error)")
    }
  }

  private func batchPublisher(_ review: MemoryReviewController?) -> MemoryBatchPublisher {
    MemoryBatchPublisher(root: root, store: store, review: review) { event in
      try self.batchPersistenceFault?(event)
      try review?.persistenceFault?(event)
      if event == .beforePublication { try self.beforePublication?() }
      if event == .afterPublication { try self.afterPublication?() }
    }
  }

  func verifyBatchConsumption(
    _ draft: MemoryDraft, receipt: MemoryBatchReceipt, review: MemoryReviewController?
  ) throws {
    let outcome: MemoryBatchSaveResult?
    do {
      outcome = try MemoryBatchPublisher(root: root, store: store, review: review).recover(draft)
    } catch {
      throw MemoryBatchRecoveryRequired(saveID: receipt.saveID, details: "\(error)")
    }
    switch outcome {
    case .saved(let actual), .decisionsSaved(let actual):
      guard try memoryBatchDigest(actual) == memoryBatchDigest(receipt) else {
        throw MemoryBatchRecoveryRequired(
          saveID: receipt.saveID, details: "receipt differs from the verified Save")
      }
    case .savedNeedsRecovery(_, let details), .outcomeUnknown(_, let details):
      throw MemoryBatchRecoveryRequired(saveID: receipt.saveID, details: details)
    case nil:
      throw MemoryBatchRecoveryRequired(
        saveID: receipt.saveID,
        details: "receipt lacks a verified publication or committed decision manifest")
    }
  }

  func withBatchJournal<T>(
    _ review: MemoryReviewController?, operation: (DreamStateDirectory) throws -> T
  ) throws -> T {
    try verifyMemoryBatchRepository(store, review: review)
    func acquireJournal() throws -> T {
      try locked {
        try store.reviewGit.reviewCheckout().withLeaseState { state in
          if let review {
            return try review.withBatchSources(state: state) { try operation(state) }
          }
          return try operation(state)
        }
      }
    }
    if let review { return try review.withBatchOwnership(acquireJournal) }
    return try acquireJournal()
  }
}
