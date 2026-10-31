import Foundation

package struct MemoryQueueRequest: Codable, Equatable {
  package let sessionID: String
  package let requestID: String

  package init(sessionID: String, requestID: String) throws {
    guard [sessionID, requestID].allSatisfy(Self.isIdentifier) else {
      throw MemoryError("invalid queue request identity")
    }
    self.sessionID = sessionID
    self.requestID = requestID
  }

  static func isIdentifier(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.count <= 256
      && text.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 46, 58, 95].contains($0)
      }
  }
}

package struct MemoryQueueEvidence: Codable, Equatable {
  package let identity: String
  package let contentDigest: String
  package let session: String
  package let entry: String
  package let part: String
  package let kind: String
  package let timestamp: String
  package let projectScope: String?
  package let exactText: String
  package let relativePath: String
  package let start: String
  package let end: String
  package let recordDigest: String
  package let agentContext: String?
  package let admittedStart: String?
  package let admittedEnd: String?
  package let admittedRecordDigest: String?

  init(_ source: PrimaryTextEvidence) throws {
    session = source.id.citation.session
    entry = source.id.citation.entry
    part = String(source.id.part)
    identity =
      SourceDigest(bytes: try MemoryReviewEncoding.encode([session, entry, part])).rawValue
    contentDigest = SourceDigest(bytes: Data(source.exactText.utf8)).rawValue
    kind = source.kind.rawValue
    timestamp = source.timestamp.ISO8601Format()
    projectScope = source.projectScope
    exactText = source.exactText
    let original = source.originalWitness ?? source.witness
    relativePath = original.relativePath.rawValue
    start = String(original.byteRange.lowerBound)
    end = String(original.byteRange.upperBound)
    recordDigest = original.rawRecordHash.rawValue
    admittedStart = source.originalWitness.map { _ in String(source.witness.byteRange.lowerBound) }
    admittedEnd = source.originalWitness.map { _ in String(source.witness.byteRange.upperBound) }
    admittedRecordDigest = source.originalWitness.map { _ in source.witness.rawRecordHash.rawValue }
    agentContext = source.agentContext
  }
}

package struct MemoryQueueConflict: Codable, Equatable {
  package let kind: String
  package let evidence: MemoryQueueEvidence?
  package let anchor: Data?
  package let explanation: String

  init(_ conflict: AtomicMemoryContradiction) throws {
    switch conflict {
    case .primary(let source, let explanation):
      kind = "primary"
      evidence = try MemoryQueueEvidence(source)
      anchor = nil
      self.explanation = explanation
    case .memory(let anchor, let explanation):
      kind = "memory"
      evidence = nil
      self.anchor = try MemoryReviewEncoding.encode([
        anchor.scope.path, anchor.documentHash.rawValue, String(anchor.start), String(anchor.end),
        anchor.before,
      ])
      self.explanation = explanation
    case .owner(let anchor, let reference, let scope, let explanation):
      kind = "owner"
      evidence = nil
      self.anchor = try MemoryReviewEncoding.encode([
        anchor.key, anchor.ownerHash.rawValue, String(anchor.start), String(anchor.end),
        anchor.before, reference, scope.path,
      ])
      self.explanation = explanation
    }
  }
}

package struct MemoryQueueFinding: Codable, Equatable {
  package let findingID: String
  package let revision: String
  package let candidateID: String
  package let relatedRevisions: [String]
  package let path: String
  package let operation: String
  package let frozenBase: String
  package let before: Data
  package let proposed: Data
  package let claimDigest: String
  package let reason: String
  package let evidence: [MemoryQueueEvidence]
  package let contradictions: [MemoryQueueConflict]
  package let limitations: [String]
  package let inputDigest: String
  package let contextDigest: String
  package let responseDigest: String
  package var successor: DreamFindingSuccessor?
  package var suppressionEpoch: String?
  package var successorRejections: [String]?
}

package struct MemoryQueueRow: Codable {
  package let finding: MemoryQueueFinding
  package let disposition: String
  package let blockReason: String?
}

package struct MemoryQueuePresentation: Codable, Equatable {
  package let claimID: String
  package let sequence: String
  package let request: MemoryQueueRequest
  package let finding: MemoryQueueFinding
  package let previewDigest: String
  package let currentBase: String
  package let before: Data
  package let after: Data
  package let replacement: Data
  package let isDetachRequired: Bool
  package let checkoutCommit: String
  package let checkoutDigest: String
  package var amendmentReason: String? = nil
}

package struct MemoryQueueDisplay: Codable, Equatable {
  package let presentation: MemoryQueuePresentation
  package let displayDigest: String
}

struct QueueShown: Codable, Equatable {
  let findingID: String
  let revision: String
  let request: MemoryQueueRequest
  let displayDigest: String
  let messageReference: String?
}

struct QueueDecisionIntent: Codable, Equatable {
  let decisionID: String
  let display: MemoryQueueDisplay
  let action: String
  let responseReference: String
  var queuedClock: Double? = nil

  func with(queuedClock: Double) -> Self {
    var copy = self
    copy.queuedClock = queuedClock
    return copy
  }
}

package struct MemoryQueueReceipt: Codable, Equatable {
  package let decisionID: String
  package let findingID: String
  package let revision: String
  package let displayDigest: String
  package let action: String
  package let status: String
  package let commit: String?
  package let auditRef: String?
}

struct QueueAmendment: Codable {
  let revision: String
  let amendment: MemoryBatchAmendment
}

struct QueueLedger: Codable {
  let schemaVersion: Int
  let binding: String
  var findings: [MemoryQueueFinding] = []
  var shown: [QueueShown] = []
  var intents: [QueueDecisionIntent] = []
  var receipts: [MemoryQueueReceipt] = []
  var amendments: [QueueAmendment]? = nil
}
