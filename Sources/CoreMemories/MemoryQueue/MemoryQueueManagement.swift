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

package final class MemoryQueueManagement {
  private let queue: MemoryQueue
  private let configurationURL: URL
  private let configuration: MemoryConfiguration
  private var active:
    (
      MemoryReviewController, MemoryBatchSession, MemoryReviewCheckoutPreview,
      MemoryManagementDisplay
    )?
  private var messageReference: String?
  private var sequence: UInt64 = 0

  package init(queue: MemoryQueue, configurationURL: URL, configuration: MemoryConfiguration) {
    self.queue = queue
    self.configurationURL = configurationURL
    self.configuration = configuration
  }

  package func inspect(_ request: MemoryManagementRequest) throws -> MemoryManagementResult {
    guard [.list, .get].contains(request.operation) else { throw DreamRunError.unsafeState }
    return try MemoryManagement(repository: configuration.memoryURL).execute(request)
  }

  package func preview(
    _ request: MemoryManagementRequest, identity: MemoryQueueRequest,
    isConfirmReviewed: Bool = false
  ) throws -> MemoryManagementDisplay {
    guard active == nil, sequence < UInt64.max else { throw DreamRunError.busy }
    let review = try queue.controller()
    let drafts = try MemoryDraftStore(
      repository: configuration.memoryURL, journal: URL(fileURLWithPath: configuration.journal))
    let session = try MemoryBatchSession(
      repository: configuration.memoryURL, drafts: drafts, review: review,
      configurationURL: configurationURL)
    guard let path = request.path else { throw DreamRunError.unsafeState }
    _ = try session.preparePath(path)
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
    let composition = try compose(session)
    guard composition.effects.count == 1, let effect = composition.effects.first,
      let replacement = composition.replacements[path]
    else { throw DreamRunError.unsafeState }
    let checkout = try review.checkoutPreview()
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
    display.displayDigest = SourceDigest(bytes: try display.publicationBytes()).rawValue
    active = (review, session, checkout, display)
    messageReference = nil
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
    guard let (review, session, checkout, current) = active, current == display,
      let messageReference, responseReference != messageReference,
      MemoryQueueRequest.isIdentifier(responseReference),
      MemoryQueueRequest.isIdentifier(decisionID),
      ["approve", "detach"].contains(action), action != "approve" || !checkout.isDetachRequired
    else { throw DreamRunError.unsafeState }
    defer { release() }
    guard try memoryBatchDigest(session.persistenceSnapshot) == display.previewDigest,
      try compose(session).replacements[display.path] == display.replacement
    else { throw DreamRunError.unsafeState }
    let intent = ManagementIntent(
      decisionID: decisionID, display: display, draft: session.persistenceSnapshot, action: action,
      responseReference: responseReference)
    let name = "management-\(decisionID).json"
    guard try !queue.directory.isPresent(name) else {
      throw MemoryError("decision key already used; recover its receipt")
    }
    try queue.directory.installReviewFile(MemoryReviewEncoding.encode(intent), name: name)
    if action == "detach" {
      guard checkout.isDetachRequired else { throw DreamRunError.unsafeState }
      try review.confirmDetach(checkout)
    } else {
      _ = try session.save()
    }
    return try recover(decisionID: decisionID, review: review)
  }

  package func recover(decisionID: String) throws -> MemoryManagementReceipt {
    try recover(decisionID: decisionID, review: queue.controller())
  }

  private func recover(decisionID: String, review: MemoryReviewController) throws
    -> MemoryManagementReceipt
  {
    guard MemoryQueueRequest.isIdentifier(decisionID) else { throw DreamRunError.unsafeState }
    let intent = try MemoryReviewEncoding.decode(
      ManagementIntent.self,
      bytes: queue.directory.read(
        "management-\(decisionID).json", maximum: MemoryReviewEncoding.maximumFileBytes))
    guard intent.decisionID == decisionID else { throw DreamRunError.corruption }
    var status = "outcome-unresolved"
    var commit: String?
    var auditRef: String?
    if intent.action == "approve" {
      let drafts = try MemoryDraftStore(
        repository: configuration.memoryURL, journal: URL(fileURLWithPath: configuration.journal))
      if let result = try drafts.recoverBatch(
        draftID: intent.draft.draftID, revision: intent.draft.revision, review: review)
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
      _ = try review.list()
      let name = "detach-outcome-\(intent.display.checkoutDigest).json"
      if try review.root.isPresent(name) {
        let attempt = try MemoryReviewEncoding.decode(
          ReviewDetachAttempt.self,
          bytes: review.root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
        guard attempt.digest == intent.display.checkoutDigest,
          attempt.witness.commit == intent.display.checkoutCommit
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
