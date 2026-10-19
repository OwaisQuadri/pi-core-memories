import Foundation

final class MemoryBatchPublisher {
  private enum VerifiedOutcome {
    case completed(MemoryBatchReceipt)
    case missingAudit(MemoryBatchAttempt, main: String)
    case unknown(saveID: String, details: String)
  }

  let root: DreamStateDirectory
  let store: MemoryStore
  let review: MemoryReviewController?
  let fault: ((MemoryReviewPersistenceEvent) throws -> Void)?

  init(
    root: DreamStateDirectory, store: MemoryStore, review: MemoryReviewController?,
    fault: ((MemoryReviewPersistenceEvent) throws -> Void)? = nil
  ) {
    self.root = root
    self.store = store
    self.review = review
    self.fault = fault
  }

  func composition(_ draft: MemoryDraft) throws -> MemoryBatchComposition {
    try verifyMemoryBatchRepository(store, review: review)
    let snapshot = try store.reviewSnapshot(base: draft.baseCommit)
    let manager = try MemoryManagement(repository: store.reviewGit.repo)
    return try MemoryBatchComposition.prepare(draft, snapshot: snapshot, manager: manager) {
      item, candidate in
      guard let review,
        draft.batch?.binding.reviewBinding == (try memoryBatchDigest(review.binding))
      else {
        throw MemoryError("candidate-bearing batch requires its original verified review binding")
      }
      return try review.batchEffect(item: item, intent: candidate, snapshot: snapshot)
    }
  }

  func inspect(_ draft: MemoryDraft) throws -> MemoryBatchSaveResult? {
    switch try verifiedOutcome(draft) {
    case .completed(let receipt):
      return receipt.commit == nil ? .decisionsSaved(receipt) : .saved(receipt)
    case .missingAudit(let attempt, _):
      return .savedNeedsRecovery(
        MemoryBatchReplay.receipt(attempt.manifest, commit: attempt.commit),
        details: "saved attempt needs explicit audit-ref recovery")
    case .unknown(let saveID, let details):
      return .outcomeUnknown(saveID: saveID, details: details)
    case nil: return nil
    }
  }

  func recover(_ draft: MemoryDraft) throws -> MemoryBatchSaveResult? {
    switch try verifiedOutcome(draft) {
    case .completed(let receipt): return finishRecovered(receipt)
    case .missingAudit(let attempt, let main):
      let git = store.reviewGit
      let auditRef = "refs/memory-batches/\(attempt.manifest.saveID)"
      let result = try git.directRefTransaction(
        "verify refs/heads/main \(main)\ncreate \(auditRef) \(attempt.commit)\n",
        refs: ["refs/heads/main", auditRef], isolatedHead: main)
      guard result.status == 0 else { throw DreamRunError.persistenceFailure }
      return finishRecovered(MemoryBatchReplay.receipt(attempt.manifest, commit: attempt.commit))
    case .unknown(let saveID, let details):
      return .outcomeUnknown(saveID: saveID, details: details)
    case nil: return nil
    }
  }

  private func verifiedOutcome(_ draft: MemoryDraft) throws -> VerifiedOutcome? {
    try verifyMemoryBatchRepository(store, review: review)
    let saveID = try memoryBatchDigest(draft)
    let git = store.reviewGit
    let auditRef = "refs/memory-batches/\(saveID)"
    let attemptName = "batch-attempt-\(saveID).json"
    let attempt = try root.isPresent(attemptName) ? readAttempt(attemptName) : nil
    if let attempt {
      guard try memoryBatchDigest(attempt.manifest.draft) == saveID else {
        throw DreamRunError.corruption
      }
    }
    if let commit = try MemoryBatchReplay.directCommit(auditRef, git: git) {
      guard attempt == nil || attempt?.commit == commit,
        try MemoryBatchReplay.isAncestor(commit, of: store.approvedCommit(), git: git)
      else {
        throw DreamRunError.corruption
      }
      let manifest = try MemoryBatchReplay.read(commit, git: git)
      guard manifest.saveID == saveID,
        try memoryBatchDigest(manifest.draft) == saveID
      else { throw DreamRunError.corruption }
      let composed = try composition(draft)
      try MemoryBatchReplay.validate(manifest, composition: composed, commit: commit, store: store)
      return .completed(MemoryBatchReplay.receipt(manifest, commit: commit))
    }
    let decisionsName = "batch-decisions-\(saveID).json"
    if let review, try review.root.isPresent(decisionsName) {
      let manifest = try MemoryReviewEncoding.decode(
        MemoryBatchManifest.self,
        bytes: review.root.read(decisionsName, maximum: MemoryReviewEncoding.maximumFileBytes))
      guard manifest.saveID == saveID, try memoryBatchDigest(manifest.draft) == saveID else {
        throw DreamRunError.corruption
      }
      try MemoryBatchReplay.validate(
        manifest, composition: composition(draft), commit: nil, store: store)
      return .completed(MemoryBatchReplay.receipt(manifest, commit: nil))
    }
    if let attempt {
      let main = try store.approvedCommit()
      if try MemoryBatchReplay.isAncestor(attempt.commit, of: main, git: git) {
        let composed = try composition(draft)
        try MemoryBatchReplay.validate(
          attempt.manifest, composition: composed, commit: attempt.commit, store: store)
        return .missingAudit(attempt, main: main)
      }
      if main != draft.baseCommit {
        return .unknown(
          saveID: saveID,
          details: "saved attempt is absent from current approved ancestry; recovery is required")
      }
    }
    let receiptName = "batch-receipt-\(saveID).json"
    guard try !root.isPresent(receiptName) else { throw DreamRunError.corruption }
    return nil
  }

  func save(
    _ draft: MemoryDraft, checkout expected: ReviewCheckoutWitness,
    authorized: Set<UUID>, leaseState: DreamStateDirectory? = nil
  ) throws -> MemoryBatchSaveResult {
    try verifyMemoryBatchRepository(store, review: review)
    let saveID = try memoryBatchDigest(draft)
    do {
      if let result = try recover(draft) { return result }
      for name in try root.names() where name.hasPrefix("batch-attempt-") {
        let attempt = try readAttempt(name)
        if attempt.manifest.saveID == saveID { continue }
        let audit = try MemoryBatchReplay.directCommit(
          "refs/memory-batches/\(attempt.manifest.saveID)", git: store.reviewGit)
        let main = try store.approvedCommit()
        if let audit {
          guard audit == attempt.commit,
            try MemoryBatchReplay.isAncestor(audit, of: main, git: store.reviewGit)
          else { throw DreamRunError.corruption }
          continue
        }
        if main == attempt.manifest.draft.baseCommit { continue }
        if let result = try recover(attempt.manifest.draft), case .outcomeUnknown = result {
          return result
        }
      }
    } catch {
      return .outcomeUnknown(
        saveID: saveID, details: "exact saved outcome could not be verified: \(error)")
    }
    guard let batch = draft.batch,
      batch.items.allSatisfy({ !$0.isReviewRequired || authorized.contains($0.itemID) })
    else {
      throw MemoryError("staged publishing review items need fresh current-session review")
    }
    try verifyConfiguration(batch.binding)
    guard try store.approvedCommit() == draft.baseCommit else {
      throw MemoryError("approved base changed; preserve the batch and review current context")
    }
    try review?.validateBatchChoices(draft)
    let composed = try composition(draft)
    let manifest = try MemoryBatchReplay.manifest(draft, composition: composed)
    try root.installReviewFile(
      MemoryReviewEncoding.encode(draft),
      name: "batch-draft-\(draft.draftID)-\(draft.revision).json", fault: fault)
    if composed.effects.isEmpty {
      try MemoryBatchReplay.validate(manifest, composition: composed, commit: nil, store: store)
      guard let review else { throw MemoryError("decision Save requires verified review state") }
      do {
        try review.installBatchDecisions(manifest)
      } catch {
        if (try? review.root.read(
          "batch-decisions-\(saveID).json", maximum: MemoryReviewEncoding.maximumFileBytes))
          == (try? MemoryReviewEncoding.encode(manifest))
        {
          return .savedNeedsRecovery(
            MemoryBatchReplay.receipt(manifest, commit: nil), details: "\(error)")
        }
        throw error
      }
      let receipt = MemoryBatchReplay.receipt(manifest, commit: nil)
      do { try finish(receipt) } catch { return .savedNeedsRecovery(receipt, details: "\(error)") }
      return .decisionsSaved(receipt)
    }
    let commit: String
    do {
      commit = try publishMemory(
        draft, composed: composed, expected: expected, leaseState: leaseState)
    } catch {
      let publicationError = error
      do {
        if let recovered = try recover(draft) { return recovered }
      } catch {
        return .outcomeUnknown(
          saveID: saveID, details: "publication response is unresolved: \(error)")
      }
      throw publicationError
    }
    let receipt = MemoryBatchReplay.receipt(manifest, commit: commit)
    do {
      try fault?(.afterPublication)
      try finish(receipt)
    } catch {
      return .savedNeedsRecovery(receipt, details: "\(error)")
    }
    return .saved(receipt)
  }

  func publishMemory(
    _ draft: MemoryDraft, composed: MemoryBatchComposition, expected: ReviewCheckoutWitness,
    leaseState: DreamStateDirectory?, legacy: ReviewPreviewPayload? = nil
  ) throws -> String {
    try verifyMemoryBatchRepository(store, review: review)
    let manifest = try MemoryBatchReplay.manifest(draft, composition: composed)
    let checkout = try store.reviewGit.reviewCheckout()
    func publish(_ state: DreamStateDirectory) throws -> String {
      guard expected.head == Data((expected.commit + "\n").utf8), expected.main == draft.baseCommit,
        try checkout.witness() == expected
      else { throw MemoryError("explicit checkout preparation or fresh review is required") }
      try checkout.lock(state: state, detachedHead: expected.head)
      try fault?(.afterCheckoutLocks)
      guard try checkout.witness(isLocked: true) == expected else {
        throw MemoryError("checkout changed during final Save")
      }
      try verifyConfiguration(draft.batch!.binding)
      let commit: String
      let auditRef: String
      if let legacy {
        guard composed.effects.count == 1,
          composed.replacements == [legacy.path: legacy.replacement]
        else { throw DreamRunError.corruption }
        try review!.validatePayload(legacy)
        commit = try store.reviewCommit(
          base: draft.baseCommit, replacements: composed.replacements,
          message: MemoryReviewController.approvalMessage(legacy))
        let digest = try memoryBatchDigest(legacy)
        auditRef = "refs/memory-review/approvals/\(digest)"
        let attempt = ReviewAttempt(
          schemaVersion: 1, preview: legacy, previewHash: digest, resultCommit: commit,
          resultTree: try store.reviewGit.text(["rev-parse", "\(commit)^{tree}"]),
          auditRef: auditRef)
        try root.installReviewFile(
          MemoryReviewEncoding.encode(attempt), name: "attempt-\(digest).json", fault: fault,
          io: review!.fileIO)
      } else {
        let attemptName = "batch-attempt-\(manifest.saveID).json"
        let attempt: MemoryBatchAttempt
        if try root.isPresent(attemptName) {
          attempt = try readAttempt(attemptName)
          guard try memoryBatchDigest(attempt.manifest) == memoryBatchDigest(manifest) else {
            throw DreamRunError.corruption
          }
          try MemoryBatchReplay.validate(
            manifest, composition: composed, commit: attempt.commit, store: store)
        } else {
          let result = try store.reviewCommit(
            base: draft.baseCommit, replacements: composed.replacements,
            message: MemoryBatchReplay.message(manifest))
          try MemoryBatchReplay.validate(
            manifest, composition: composed, commit: result, store: store)
          attempt = MemoryBatchAttempt(
            manifest: manifest, commit: result,
            tree: try store.reviewGit.text(["rev-parse", "\(result)^{tree}"]))
          try root.installReviewFile(
            MemoryReviewEncoding.encode(attempt), name: attemptName, fault: fault)
        }
        if let review {
          try review.root.installReviewFile(
            Data("memory-batch-v1\n".utf8), name: "batch-format.json",
            fault: review.persistenceFault, io: review.fileIO)
        }
        commit = attempt.commit
        auditRef = "refs/memory-batches/\(manifest.saveID)"
      }
      try fault?(.beforePublication)
      guard review?.isCancelled() != true else {
        throw MemoryError("review cancelled before publication")
      }
      try verifyConfiguration(draft.batch!.binding)
      guard try checkout.witness(isLocked: true) == expected else {
        throw MemoryError("checkout changed immediately before publication")
      }
      try store.publishCheckedMemoryCommit(
        commit: commit, base: draft.baseCommit, auditRef: auditRef, checkout: expected)
      return commit
    }
    if let leaseState { return try publish(leaseState) }
    return try checkout.withLeaseState(publish)
  }

  static func applyLegacy(_ preview: MemoryReviewPreview, review: MemoryReviewController) throws
    -> MemoryReviewApproval
  {
    let payload = preview.payload
    let intent = MemoryBatchCandidateIntent(
      candidateID: payload.candidateID, admissionHash: payload.admissionHash, choice: .accept,
      identity: payload.identity, instant: payload.instant, amendment: nil)
    let item = MemoryBatchItem(
      itemID: memoryBatchIdentity("candidate:\(payload.candidateID)"), generation: 0,
      intent: .candidate(intent))
    let binding = MemoryBatchBinding(
      configurationPath: nil, configurationDigest: nil, allowedPaths: [payload.path],
      reviewBinding: try memoryBatchDigest(review.binding))
    let draft = MemoryDraft(
      schemaVersion: 2, draftID: memoryBatchIdentity("one-item:\(preview.digest.rawValue)"),
      revision: 0,
      repositoryBinding: try memoryBatchDigest(review.binding), baseCommit: payload.currentBase,
      created: ISO8601DateFormatter().date(from: payload.instant.rawValue)!, operations: [],
      batch: MemoryBatchContents(binding: binding, items: [item]))
    let publisher = MemoryBatchPublisher(
      root: review.root, store: review.store, review: review, fault: review.persistenceFault)
    let composed = try publisher.composition(draft)
    let auditRef = "refs/memory-review/approvals/\(preview.digest.rawValue)"
    let commit: String
    do {
      commit = try publisher.publishMemory(
        draft, composed: composed, expected: payload.checkout, leaseState: review.checkoutState,
        legacy: payload)
    } catch {
      let publicationError = error
      let published: String?
      do {
        published = try MemoryBatchReplay.directCommit(auditRef, git: review.store.reviewGit)
      } catch {
        throw MemoryBatchRecoveryRequired(saveID: preview.digest.rawValue, details: "\(error)")
      }
      if let published {
        do {
          try review.recoverApprovals()
          guard review.approvals[payload.candidateID]?.resultCommit == published else {
            throw DreamRunError.corruption
          }
        } catch {
          throw MemoryBatchRecoveryRequired(saveID: preview.digest.rawValue, details: "\(error)")
        }
        throw MemoryReviewMutationFailure(
          mutation: .approved, commit: published, auditRef: auditRef,
          followUpFailure: "\(publicationError)")
      }
      if (try? review.store.approvedCommit()) == payload.currentBase { throw publicationError }
      throw MemoryBatchRecoveryRequired(
        saveID: preview.digest.rawValue, details: "\(publicationError)")
    }
    review.previews.removeAll()
    do {
      try review.persistenceFault?(.afterPublication)
      try review.recoverApprovals()
    } catch {
      throw MemoryReviewMutationFailure(
        mutation: .approved, commit: commit, auditRef: auditRef, followUpFailure: "\(error)")
    }
    return MemoryReviewApproval(
      candidateID: preview.change.id, previewHash: preview.digest, commit: commit,
      auditRef: auditRef)
  }

  private func finishRecovered(_ receipt: MemoryBatchReceipt) -> MemoryBatchSaveResult {
    do { try finish(receipt) } catch { return .savedNeedsRecovery(receipt, details: "\(error)") }
    return receipt.commit == nil ? .decisionsSaved(receipt) : .saved(receipt)
  }

  func finish(_ receipt: MemoryBatchReceipt) throws {
    try root.installReviewFile(
      MemoryReviewEncoding.encode(receipt), name: "batch-receipt-\(receipt.saveID).json",
      fault: fault)
  }

  func readAttempt(_ name: String) throws -> MemoryBatchAttempt {
    let attempt = try MemoryReviewEncoding.decode(
      MemoryBatchAttempt.self,
      bytes: root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
    guard name == "batch-attempt-\(attempt.manifest.saveID).json",
      attempt.manifest.saveID == (try memoryBatchDigest(attempt.manifest.draft)),
      MemoryStore.isFullOID(attempt.commit), MemoryStore.isFullOID(attempt.tree),
      try store.reviewGit.text(["rev-parse", "\(attempt.commit)^{tree}"]) == attempt.tree
    else { throw DreamRunError.corruption }
    return attempt
  }

  private func verifyConfiguration(_ binding: MemoryBatchBinding) throws {
    guard let path = binding.configurationPath else {
      guard binding.configurationDigest == nil else { throw DreamRunError.corruption }
      return
    }
    let configuration = try MemoryConfiguration.load(from: URL(fileURLWithPath: path))
    guard try memoryBatchDigest(configuration) == binding.configurationDigest else {
      throw MemoryError("selected configuration changed on disk; reopen the workspace")
    }
  }
}
