import Foundation

public struct DreamPriorNote: Codable, Equatable, Sendable {
  public let generation: UInt64
  public let kind: String
  public let reasonCode: String?
  public let explanation: String
  public let sessions: [String]

  public init(
    generation: UInt64, kind: String, reasonCode: String?, explanation: String, sessions: [String]
  ) {
    self.generation = generation
    self.kind = kind
    self.reasonCode = reasonCode
    self.explanation = DreamPriorContext.clipped(explanation)
    self.sessions = Set(sessions).sorted()
  }
}

public struct DreamOpenFinding: Codable, Equatable, Sendable {
  public let revision: String
  public let status: String
  public let path: String
  public let claim: String
  public let reason: String
  public let sessions: [String]

  public init(
    revision: String, status: String, path: String, claim: String, reason: String,
    sessions: [String]
  ) {
    self.revision = revision
    self.status = status
    self.path = path
    self.claim = DreamPriorContext.clipped(claim)
    self.reason = DreamPriorContext.clipped(reason)
    self.sessions = Set(sessions).sorted()
  }
}

public struct DreamPriorOmissions: Codable, Equatable, Sendable {
  public var overBudget = 0
  public var liveSession = 0
  public var unverifiedSource = 0

  var counts: [Int] { [overBudget, liveSession, unverifiedSource] }
}

struct DreamPriorCandidate<Item: Encodable> {
  let item: Item
  let sessions: [String]
  let sourcePaths: Set<String>
}

public struct DreamPriorContext: Codable, Equatable, Sendable {
  public static let maximumNotes = 40
  public static let maximumNoteBytes = 12_288
  public static let maximumFindings = 24
  public static let maximumFindingBytes = 16_384
  public static let maximumTextBytes = 1_024
  static let openStatuses: Set<String> = ["pending", "deferred", "rejected"]

  public let notes: [DreamPriorNote]
  public let omittedNotes: DreamPriorOmissions
  public let findings: [DreamOpenFinding]
  public let omittedFindings: DreamPriorOmissions

  init?(
    newestNotes: [DreamPriorCandidate<DreamPriorNote>], olderNoteCount: Int,
    olderLiveNoteCount: Int = 0, newestFindings: [DreamPriorCandidate<DreamOpenFinding>],
    excludedSessionIDs: Set<String>,
    isVerified: (Set<String>) throws -> Bool
  ) throws {
    var omittedNotes = DreamPriorOmissions(
      overBudget: olderNoteCount - olderLiveNoteCount, liveSession: olderLiveNoteCount)
    var omittedFindings = DreamPriorOmissions()
    let notes = try Self.select(
      newestNotes, maximumCount: Self.maximumNotes, maximumBytes: Self.maximumNoteBytes,
      excludedSessionIDs: excludedSessionIDs, omissions: &omittedNotes, isVerified: isVerified)
    let findings = try Self.select(
      newestFindings, maximumCount: Self.maximumFindings, maximumBytes: Self.maximumFindingBytes,
      excludedSessionIDs: excludedSessionIDs, omissions: &omittedFindings,
      isVerified: isVerified)
    guard
      !notes.isEmpty || !findings.isEmpty
        || (omittedNotes.counts + omittedFindings.counts).contains(where: { $0 > 0 })
    else { return nil }
    self.notes = notes
    self.omittedNotes = omittedNotes
    self.findings = findings
    self.omittedFindings = omittedFindings
  }

  var isWithinBudget: Bool {
    let counts = omittedNotes.counts + omittedFindings.counts
    guard counts.allSatisfy({ $0 >= 0 }),
      !notes.isEmpty || !findings.isEmpty || counts.contains(where: { $0 > 0 }),
      notes.count <= Self.maximumNotes, findings.count <= Self.maximumFindings,
      let noteBytes = try? DreamRunEncoding.encode(notes).count,
      let findingBytes = try? DreamRunEncoding.encode(findings).count,
      noteBytes <= Self.maximumNoteBytes, findingBytes <= Self.maximumFindingBytes
    else { return false }
    return notes.allSatisfy {
      $0.explanation.utf8.count <= Self.maximumTextBytes
        && $0.sessions.allSatisfy(MemoryQueueRequest.isIdentifier)
    }
      && findings.allSatisfy {
        Self.openStatuses.contains($0.status)
          && MemoryDocument.isMatch(#"\A[0-9a-f]{64}\z"#, $0.revision)
          && $0.claim.utf8.count <= Self.maximumTextBytes
          && $0.reason.utf8.count <= Self.maximumTextBytes
          && $0.sessions.allSatisfy(MemoryQueueRequest.isIdentifier)
      }
  }

  var sessions: Set<String> { Set(notes.flatMap(\.sessions) + findings.flatMap(\.sessions)) }

  var protectedPieces: [String] {
    notes.map(\.explanation) + findings.flatMap { [$0.path, $0.claim, $0.reason] }
  }

  static func clipped(_ text: String) -> String {
    guard text.utf8.count > maximumTextBytes else { return text }
    let marker = "…"
    var kept = String.UnicodeScalarView()
    var count = marker.utf8.count
    for scalar in text.unicodeScalars {
      count += String(scalar).utf8.count
      guard count <= maximumTextBytes else { break }
      kept.append(scalar)
    }
    return String(kept) + marker
  }

  private static func select<Item: Encodable>(
    _ candidates: [DreamPriorCandidate<Item>], maximumCount: Int, maximumBytes: Int,
    excludedSessionIDs: Set<String>, omissions: inout DreamPriorOmissions,
    isVerified: (Set<String>) throws -> Bool
  ) throws -> [Item] {
    var chosen: [DreamPriorCandidate<Item>] = []
    for candidate in candidates {
      if !excludedSessionIDs.isDisjoint(with: candidate.sessions) {
        omissions.liveSession += 1
      } else if chosen.count < maximumCount,
        try DreamRunEncoding.encode((chosen + [candidate]).map(\.item)).count <= maximumBytes
      {
        chosen.append(candidate)
      } else {
        omissions.overBudget += 1
      }
    }
    var verified: [Item] = []
    for candidate in chosen {
      if !candidate.sourcePaths.isEmpty, try isVerified(candidate.sourcePaths) {
        verified.append(candidate.item)
      } else {
        omissions.unverifiedSource += 1
      }
    }
    return verified
  }
}
