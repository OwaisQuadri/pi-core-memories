import Foundation

extension MemoryDraftStore {
  func saveBatch(
    _ draft: MemoryDraft, review: MemoryReviewController?, checkout: ReviewCheckoutWitness,
    authorized: Set<UUID>
  ) throws -> MemoryBatchSaveResult {
    do {
      return try performBatchSave(draft, review: review, checkout: checkout, authorized: authorized)
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
    _ draft: MemoryDraft, review: MemoryReviewController?, checkout: ReviewCheckoutWitness,
    authorized: Set<UUID>
  ) throws -> MemoryBatchSaveResult {
    try withBatchJournal(review) { state in
      let publisher = batchPublisher(review)
      do {
        if let recovered = try publisher.recover(draft) { return recovered }
      } catch {
        return .outcomeUnknown(saveID: try memoryBatchDigest(draft), details: "\(error)")
      }
      guard let durable = try drafts(only: draft.draftID, review: review).first,
        durable.revision <= draft.revision, durable.repositoryBinding == draft.repositoryBinding,
        durable.baseCommit == draft.baseCommit, durable.created == draft.created
      else {
        throw MemoryError("draft changed or was discarded before final Save")
      }
      if durable.revision == draft.revision {
        guard try memoryBatchDigest(durable) == memoryBatchDigest(draft) else {
          throw MemoryError("draft revision contains different intent")
        }
      }
      if durable.schemaVersion == 1 {
        try root.installReviewFile(
          DreamRunEncoding.encode(durable), name: "\(durable.draftID)-\(durable.revision).json")
      }
      try persist(draft)
      try root.installReviewFile(
        DreamRunEncoding.encode(draft), name: "\(draft.draftID)-\(draft.revision).json")
      return try publisher.save(
        draft, checkout: checkout, authorized: authorized, leaseState: state)
    }
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

extension MemoryBatchSession {
  package func save() throws -> MemoryBatchSaveResult {
    try drafts.saveBatch(
      persistenceSnapshot, review: review, checkout: checkout,
      authorized: Set(items.filter(isAuthorized).map(\.itemID)))
  }
}
