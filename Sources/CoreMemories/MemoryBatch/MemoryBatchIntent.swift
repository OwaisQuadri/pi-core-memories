import Foundation

package enum MemoryBatchChoice: String, Codable, Sendable {
  case accept, deferCandidate, reject
}

package struct MemoryBatchAmendment: Codable, Sendable {
  package let replacement: String
  package let reason: String

  package init(replacement: String, reason: String) {
    self.replacement = replacement
    self.reason = reason
  }
}

package struct MemoryBatchManualIntent: Codable, Sendable {
  package let request: MemoryManagementRequest
  package let identity: UUID
  package let date: Date
}

package struct MemoryBatchCandidateIntent: Codable, Sendable {
  package let candidateID: String
  package let admissionHash: String
  package let choice: MemoryBatchChoice
  package let identity: UUID
  package let instant: MemoryDocument.ReviewInstant
  package let amendment: MemoryBatchAmendment?
}

package struct MemoryBatchReviewIntent: Codable, Sendable {
  package let entry: ManagedMemoryEntry
  package let identity: UUID
  package let instant: MemoryDocument.ReviewInstant
}

package enum MemoryBatchIntent: Codable, Sendable {
  case manual(MemoryBatchManualIntent)
  case candidate(MemoryBatchCandidateIntent)
  case confirmReviewed(MemoryBatchReviewIntent)
}

package struct MemoryBatchItem: Codable, Sendable {
  package let itemID: UUID
  package let generation: UInt64
  package let intent: MemoryBatchIntent
}

package struct MemoryBatchBinding: Codable, Sendable {
  package let configurationPath: String?
  package let configurationDigest: String?
  package let allowedPaths: [String]
  package let reviewBinding: String?
  package let preparedPaths: [String]?

  package init(
    configurationPath: String?, configurationDigest: String?, allowedPaths: [String],
    reviewBinding: String?, preparedPaths: [String]? = nil
  ) {
    self.configurationPath = configurationPath
    self.configurationDigest = configurationDigest
    self.allowedPaths = allowedPaths
    self.reviewBinding = reviewBinding
    self.preparedPaths = preparedPaths
  }
}

package struct MemoryBatchContents: Codable, Sendable {
  package let binding: MemoryBatchBinding
  package let items: [MemoryBatchItem]
}

package struct MemoryBatchPresentation: Sendable {
  package let itemID: UUID
  package let path: String
  package let before: Data
  package let after: Data
  package let digest: SourceDigest
  let reference: UUID
  let intent: MemoryBatchIntent
}

package struct MemoryBatchProjection: Sendable {
  package let draft: MemoryDraft
  package let entries: [ManagedMemoryEntry]
  package let candidates: [MemoryReviewCandidate]
  package let retainedEntries: [ManagedMemoryEntry]
  package let retainedCandidates: [MemoryReviewCandidate]
  package let selectedItemID: UUID?
  package let catalogOffset: Int
  package let entryCount: Int
  package let candidateCount: Int
  package let needsReview: Set<UUID>
}

func memoryBatchIdentity(_ value: String) -> UUID {
  let hex = SourceDigest(bytes: Data(value.utf8)).rawValue
  let parts = [
    hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
    hex.dropFirst(16).prefix(4), hex.dropFirst(20).prefix(12),
  ]
  return UUID(uuidString: parts.map(String.init).joined(separator: "-"))!
}

func memoryBatchDigest(_ value: some Encodable) throws -> String {
  SourceDigest(bytes: try MemoryReviewEncoding.encode(value)).rawValue
}

extension MemoryBatchItem {
  var isReviewRequired: Bool {
    switch intent {
    case .manual: false
    case .confirmReviewed: true
    case .candidate(let candidate): candidate.choice == .accept
    }
  }
}
