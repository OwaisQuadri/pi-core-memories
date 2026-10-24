import Foundation

public struct DreamFindingSuccessor: Codable, Equatable, Sendable {
  public struct Evidence: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
      public let session: String
      public let entry: String
      public let part: Int
    }
    public let source: Source
    public let contentDigest: String
  }
  public let version: Int
  public let predecessorRevision: String
  public let priorClaim: String
  public let newEvidence: [Evidence]
  public let explanation: String
}

extension MemoryQueue {
  static func isRepeatedSuccessor(_ finding: MemoryQueueFinding, origin: MemoryQueueFinding) -> Bool
  {
    guard let successor = origin.successor, finding.claimDigest == origin.claimDigest,
      finding.path == origin.path
    else { return false }
    if let hint = finding.successor {
      guard hint.version == successor.version,
        hint.predecessorRevision == successor.predecessorRevision,
        Data(hint.priorClaim.utf8) == Data(successor.priorClaim.utf8)
      else { return false }
    }
    return successor.newEvidence.allSatisfy { source in
      finding.evidence.contains { evidence in
        evidence.session == source.source.session && evidence.entry == source.source.entry
          && evidence.part == String(source.source.part)
          && evidence.contentDigest == source.contentDigest
      }
    }
  }

  static func successorPredecessor(
    _ finding: MemoryQueueFinding, rejected: Set<String>, state: QueueLedger
  ) -> String? {
    guard let successor = finding.successor, successor.version == 1,
      let predecessor = state.findings.first(where: { $0.revision == successor.predecessorRevision }
      ),
      rejected.contains(predecessor.revision), predecessor.path == finding.path,
      Data(successor.priorClaim.utf8) == predecessor.proposed,
      predecessor.claimDigest != finding.claimDigest,
      !successor.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      successor.explanation.utf8.count <= 16_384,
      !successor.newEvidence.isEmpty
    else { return nil }
    let lineage = relatedRevisions(predecessor, state: state)
    let ancestors = Set(
      state.findings.first(where: { $0.revision == predecessor.suppressionEpoch })?
        .successorRejections ?? [])
    guard rejected.isSubset(of: lineage.union(ancestors)) else { return nil }
    let history = relatedRevisions(predecessor, state: state, isAcrossEpochs: true)
    let old = state.findings.filter {
      history.contains($0.revision) && $0.revision != finding.revision
    }
    let oldEvidence = old.flatMap { $0.evidence + $0.contradictions.compactMap(\.evidence) }
    let oldIDs = Set(oldEvidence.map(\.identity))
    let oldDigests = Set(oldEvidence.map(\.contentDigest))
    var selected: Set<String> = []
    for source in successor.newEvidence {
      guard
        let evidence = finding.evidence.first(where: {
          $0.session == source.source.session && $0.entry == source.source.entry
            && $0.part == String(source.source.part)
        }), evidence.contentDigest == source.contentDigest,
        !oldIDs.contains(evidence.identity), !oldDigests.contains(evidence.contentDigest),
        selected.insert(evidence.identity).inserted
      else { return nil }
    }
    return predecessor.revision
  }
}
