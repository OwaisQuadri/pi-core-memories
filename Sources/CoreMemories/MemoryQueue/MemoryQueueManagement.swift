import Foundation

package struct MemoryManagementDisplay: Codable, Equatable {
  package let claimID: String
  package let sequence: String
  package let request: MemoryQueueRequest
  package let operation: String
  package let reason: String
  package let path: String
  package let currentBase: String
  package let before: Data
  package let after: Data
  package let documentBefore: Data
  package let replacement: Data
  package let previewDigest: String
  package let isDetachRequired: Bool
  package let checkoutCommit: String
  package let checkoutDigest: String
  package var displayDigest: String
  package var change: MemoryChangeDescription? = nil

  package func publicationBytes() throws -> Data {
    guard
      var fields = try JSONSerialization.jsonObject(with: DreamRunEncoding.encode(self))
        as? [String: Any]
    else { throw DreamRunError.corruption }
    fields.removeValue(forKey: "displayDigest")
    return try JSONSerialization.data(
      withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
  }
}

package struct MemoryManagementReceipt: Codable {
  package let decisionID: String
  package let displayDigest: String
  package let status: String
  package let commit: String?
  package let auditRef: String?
}

private struct ManagementIntent: Codable {
  let decisionID: String
  let display: MemoryManagementDisplay
  let draft: MemoryDraft
  let action: String
  let responseReference: String
}

package enum MemoryManagementPreviewStage: String {
  case availability, controller, drafts, batchSession, path, manualRequest, composition, checkout,
    display
}

package struct MemoryManagementAuthorization {
  let repository: String
  let saveID: String

  fileprivate init(repository: URL, draft: MemoryDraft) throws {
    guard let items = draft.batch?.items, items.count == 1 else { throw DreamRunError.unsafeState }
    switch items[0].intent {
    case .manual, .confirmReviewed: break
    default: throw DreamRunError.unsafeState
    }
    self.repository = repository.path
    self.saveID = try memoryBatchDigest(draft)
  }
}

package final class MemoryQueueManagement {
  package private(set) var previewStage: MemoryManagementPreviewStage?
  private let configurationURL: URL
  private let configuration: MemoryConfiguration
  private var active:
    (
      MemoryDraftStore, MemoryBatchSession, MemoryReviewCheckoutPreview,
      MemoryManagementDisplay
    )?
  private var messageReference: String?
  private var sequence: UInt64 = 0

  package init(
    configurationURL: URL, configuration: MemoryConfiguration
  ) {
    self.configurationURL = configurationURL
    self.configuration = configuration
  }

  private func drafts() throws -> MemoryDraftStore {
    let selected = try MemoryStore(repo: configuration.memoryURL).reviewGit.repo
    guard let resolved = realpath(selected.path, nil) else { throw DreamRunError.unsafeState }
    defer { free(resolved) }
    let repository = URL(fileURLWithPath: String(cString: resolved))
    let journal = repository.deletingLastPathComponent()
      .appendingPathComponent(repository.lastPathComponent + ".management")
    return try MemoryDraftStore(repository: repository, journal: journal)
  }

  package func inspect(_ request: MemoryManagementRequest) throws -> MemoryManagementResult {
    guard [.list, .get].contains(request.operation) else { throw DreamRunError.unsafeState }
    return try MemoryManagement(repository: configuration.memoryURL).execute(request)
  }

  package func preview(
    _ request: MemoryManagementRequest, identity: MemoryQueueRequest,
    isConfirmReviewed: Bool = false
  ) throws -> MemoryManagementDisplay {
    previewStage = .availability
    guard active == nil, sequence < UInt64.max else { throw DreamRunError.busy }
    previewStage = .drafts
    let drafts = try drafts()
    previewStage = .batchSession
    let session = try MemoryBatchSession(repository: configuration.memoryURL, drafts: drafts)
    previewStage = .path
    guard let path = request.path else { throw DreamRunError.unsafeState }
    _ = try session.preparePath(path)
    previewStage = .manualRequest
    if isConfirmReviewed {
      guard request.operation == .get, request.base == session.snapshot.base,
        let entry = try inspect(request).entries.first
      else { throw DreamRunError.unsafeState }
      while !session.entries.contains(where: {
        $0.path == entry.path && $0.locator == entry.locator
      }) {
        let offset = session.catalogOffset + session.catalogLimit
        guard offset < session.entryCount else { throw DreamRunError.unsafeState }
        _ = try session.prepareCatalog(offset: offset)
      }
      try session.stage(session.presentConfirmReviewed(entry))
    } else {
      _ = try session.stageManual(request)
    }
    previewStage = .composition
    let composition = try compose(session)
    guard composition.effects.count == 1, let effect = composition.effects.first,
      let replacement = composition.replacements[path]
    else { throw DreamRunError.unsafeState }
    previewStage = .checkout
    let witness = session.checkout
    let checkout = MemoryReviewCheckoutPreview(
      commit: witness.commit, main: witness.main,
      isDetachRequired: witness.head == Data("ref: refs/heads/main\n".utf8),
      digest: SourceDigest(bytes: try MemoryReviewEncoding.encode(witness)), witness: witness)
    previewStage = .display
    sequence += 1
    let claimID = UUID().uuidString
    let previewDigest = try memoryBatchDigest(session.persistenceSnapshot)
    let documentBefore = session.snapshot.documents.first { $0.path == path }?.bytes ?? Data()
    var display = MemoryManagementDisplay(
      claimID: claimID, sequence: String(sequence), request: identity,
      operation: isConfirmReviewed ? "confirm-reviewed" : request.operation.rawValue,
      reason: request.reason ?? "confirm-reviewed", path: path, currentBase: session.snapshot.base,
      before: effect.before, after: effect.after, documentBefore: documentBefore,
      replacement: replacement,
      previewDigest: previewDigest, isDetachRequired: checkout.isDetachRequired,
      checkoutCommit: checkout.commit, checkoutDigest: checkout.digest.rawValue,
      displayDigest: "")
    display.change = try MemoryChangeDescription(before: effect.before, after: effect.after, path: path, configuration: configuration)
    display.displayDigest = SourceDigest(bytes: try display.publicationBytes()).rawValue
    active = (drafts, session, checkout, display)
    messageReference = nil
    previewStage = nil
    return display
  }

  private func compose(_ session: MemoryBatchSession) throws -> MemoryBatchComposition {
    try MemoryBatchComposition.prepare(
      session.persistenceSnapshot, snapshot: session.snapshot, manager: session.manager
    ) { _, _ in
      throw DreamRunError.unsafeState
    }
  }

  package func presented(_ display: MemoryManagementDisplay, messageReference: String) throws {
    guard active?.3 == display, MemoryQueueRequest.isIdentifier(messageReference) else {
      throw DreamRunError.unsafeState
    }
    self.messageReference = messageReference
  }

  package func decide(
    _ display: MemoryManagementDisplay, action: String, decisionID: String,
    responseReference: String
  ) throws -> MemoryManagementReceipt {
    guard let (drafts, session, checkout, current) = active, current == display,
      let messageReference, responseReference != messageReference,
      MemoryQueueRequest.isIdentifier(responseReference),
      MemoryQueueRequest.isIdentifier(decisionID),
      ["approve", "detach"].contains(action), action != "approve" || !checkout.isDetachRequired
    else { throw DreamRunError.unsafeState }
    defer { release() }
    guard try MemoryConfiguration.load(from: configurationURL).memoryURL == configuration.memoryURL,
      try memoryBatchDigest(session.persistenceSnapshot) == display.previewDigest,
      try compose(session).replacements[display.path] == display.replacement
    else { throw DreamRunError.unsafeState }
    let intent = ManagementIntent(
      decisionID: decisionID, display: display, draft: session.persistenceSnapshot, action: action,
      responseReference: responseReference)
    let name = "management-\(decisionID).json"
    guard try !drafts.root.isPresent(name) else {
      throw MemoryError("decision key already used; recover its receipt")
    }
    try drafts.root.installReviewFile(MemoryReviewEncoding.encode(intent), name: name)
    if action == "detach" {
      guard checkout.isDetachRequired else { throw DreamRunError.unsafeState }
      let gitCheckout = try drafts.store.reviewGit.reviewCheckout()
      try gitCheckout.withLeaseState { state in
        try gitCheckout.lock(state: state, detachedHead: Data((checkout.commit + "\n").utf8))
        guard try gitCheckout.witness(isLocked: true) == checkout.witness else {
          throw MemoryError("checkout confirmation is stale")
        }
        let attempt = ReviewDetachAttempt(
          schemaVersion: 1, witness: checkout.witness, digest: checkout.digest.rawValue,
          auditRef: "refs/memory-management/detach/\(checkout.digest.rawValue)")
        try drafts.root.installReviewFile(
          MemoryReviewEncoding.encode(attempt), name: "detach-attempt-\(attempt.digest).json")
        try gitCheckout.detach(checkout.witness)
      }
    } else {
      let authorization = try MemoryManagementAuthorization(
        repository: drafts.store.reviewGit.repo, draft: session.persistenceSnapshot)
      _ = try session.save(managementAuthorization: authorization)
    }
    return try recover(decisionID: decisionID)
  }

  package func recover(decisionID: String) throws -> MemoryManagementReceipt {
    guard MemoryQueueRequest.isIdentifier(decisionID) else { throw DreamRunError.unsafeState }
    let drafts = try drafts()
    let name = "management-\(decisionID).json"
    guard try drafts.root.isPresent(name) else {
      return try recoverLegacy(decisionID: decisionID)
    }
    let intent = try MemoryReviewEncoding.decode(
      ManagementIntent.self,
      bytes: drafts.root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
    guard intent.decisionID == decisionID else { throw DreamRunError.corruption }
    var status = "outcome-unresolved"
    var commit: String?
    var auditRef: String?
    if intent.action == "approve" {
      if let outcome = try drafts.recoverBatch(
        draftID: intent.draft.draftID, revision: intent.draft.revision)
      {
        switch outcome {
        case .saved(let receipt), .savedNeedsRecovery(let receipt, _):
          if receipt.commit != nil, receipt.auditRef != nil {
            status = "approved"
            commit = receipt.commit
            auditRef = receipt.auditRef
          }
        default: break
        }
      }
    } else if intent.action == "detach" {
      let digest = intent.display.checkoutDigest
      let attempt = try MemoryReviewEncoding.decode(
        ReviewDetachAttempt.self,
        bytes: drafts.root.read(
          "detach-attempt-\(digest).json", maximum: MemoryReviewEncoding.maximumFileBytes))
      guard attempt.schemaVersion == 1, attempt.digest == digest,
        attempt.witness.commit == intent.display.checkoutCommit,
        attempt.digest
          == SourceDigest(bytes: try MemoryReviewEncoding.encode(attempt.witness)).rawValue,
        attempt.witness.head == Data("ref: refs/heads/main\n".utf8),
        attempt.auditRef == "refs/memory-management/detach/\(digest)"
      else { throw DreamRunError.corruption }
      let git = drafts.store.reviewGit
      let checkout = try git.reviewCheckout()
      try checkout.withLeaseState { _ in
        if let saved = try MemoryBatchReplay.directCommit(attempt.auditRef, git: git) {
          guard saved == attempt.witness.commit else { throw DreamRunError.corruption }
        } else {
          let witness = try checkout.witness()
          guard witness.head == Data((attempt.witness.commit + "\n").utf8),
            witness.gitDevice == attempt.witness.gitDevice,
            witness.gitInode == attempt.witness.gitInode,
            witness.index == attempt.witness.index, witness.config == attempt.witness.config,
            witness.sharedIndexes == attempt.witness.sharedIndexes
          else { return }
          let result = try git.directRefTransaction(
            "create \(attempt.auditRef) \(attempt.witness.commit)\n", refs: [attempt.auditRef],
            isolatedHead: attempt.witness.commit)
          guard result.status == 0 else { throw DreamRunError.persistenceFailure }
        }
        try drafts.root.installReviewFile(
          MemoryReviewEncoding.encode(attempt), name: "detach-outcome-\(digest).json")
        status = "detached"
        commit = attempt.witness.commit
        auditRef = attempt.auditRef
      }
    }
    return MemoryManagementReceipt(
      decisionID: decisionID, displayDigest: intent.display.displayDigest, status: status,
      commit: commit, auditRef: auditRef)
  }

  private func recoverLegacy(decisionID: String) throws -> MemoryManagementReceipt {
    let directory = try DreamStateDirectory.openRoot(
      URL(fileURLWithPath: configuration.reviewState + ".queue"), isCreating: false)
    guard MemoryQueueRequest.isIdentifier(decisionID) else { throw DreamRunError.unsafeState }
    let intent = try MemoryReviewEncoding.decode(
      ManagementIntent.self,
      bytes: directory.read(
        "management-\(decisionID).json", maximum: MemoryReviewEncoding.maximumFileBytes))
    guard intent.decisionID == decisionID else { throw DreamRunError.corruption }
    var status = "outcome-unresolved"
    var commit: String?
    var auditRef: String?
    if intent.action == "approve" {
      let drafts = try MemoryDraftStore(
        repository: configuration.memoryURL, journal: URL(fileURLWithPath: configuration.journal))
      if let result = try drafts.recoverBatch(
        draftID: intent.draft.draftID, revision: intent.draft.revision)
      {
        switch result {
        case .saved(let receipt), .savedNeedsRecovery(let receipt, _):
          if receipt.commit != nil, receipt.auditRef != nil {
            status = "approved"
            commit = receipt.commit
            auditRef = receipt.auditRef
          }
        default: break
        }
      }
    } else if intent.action == "detach" {
      let root = try DreamStateDirectory.openRoot(
        URL(fileURLWithPath: configuration.reviewState), isCreating: false)
      let name = "detach-outcome-\(intent.display.checkoutDigest).json"
      if try root.isPresent(name) {
        let attempt = try MemoryReviewEncoding.decode(
          ReviewDetachAttempt.self,
          bytes: root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
        guard attempt.schemaVersion == 1,
          attempt.digest == intent.display.checkoutDigest,
          attempt.witness.commit == intent.display.checkoutCommit,
          attempt.digest
            == SourceDigest(bytes: try MemoryReviewEncoding.encode(attempt.witness)).rawValue,
          attempt.witness.head == Data("ref: refs/heads/main\n".utf8),
          MemoryDocument.isMatch(#"\A([0-9a-f]{40}|[0-9a-f]{64})\z"#, attempt.witness.commit),
          attempt.auditRef == "refs/memory-review/detach/\(attempt.digest)",
          try root.read(
            "detach-attempt-\(attempt.digest).json", maximum: MemoryReviewEncoding.maximumFileBytes)
            == MemoryReviewEncoding.encode(attempt),
          try MemoryBatchReplay.directCommit(
            attempt.auditRef, git: MemoryStore(repo: configuration.memoryURL).reviewGit)
            == attempt.witness.commit
        else { throw DreamRunError.corruption }
        status = "detached"
        commit = attempt.witness.commit
        auditRef = attempt.auditRef
      }
    }
    return MemoryManagementReceipt(
      decisionID: decisionID, displayDigest: intent.display.displayDigest, status: status,
      commit: commit, auditRef: auditRef)
  }

  package func release() {
    active = nil
    messageReference = nil
  }
}
