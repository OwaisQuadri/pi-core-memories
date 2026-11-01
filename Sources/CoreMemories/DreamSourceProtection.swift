import Foundation

package enum DreamSourceProtectionError: Error, Equatable, Sendable {
  case unavailable, blocked, changed, limitExceeded, requestLimit, timeout, cancelled, invalidReply
}

package enum DreamSourceProtection {
  package static let maximumPieces = 1_000
  package static let maximumPieceBytes = 1_048_576
  package static let maximumInputBytes = 4_194_304
  package static let maximumOutputBytes = 8_388_608
  static let maximumContextBytes = maximumPieceBytes

  static func checkedRecords(
    _ records: [(bytes: Data, stub: Data)], admit: ([String]) throws -> [String]
  ) throws -> [(bytes: Data, isStub: Bool)] {
    let requests = records.map { record in
      (bytes: record.bytes.count > maximumPieceBytes ? record.stub : record.bytes,
        isStub: record.bytes.count > maximumPieceBytes)
    }
    let pending = try requests.map { try text($0.bytes) }
    let checked = pending.isEmpty ? [] : try admit(pending)
    guard checked.count == pending.count else { throw DreamSourceProtectionError.invalidReply }
    return zip(checked, requests).map { (Data($0.0.utf8), $0.1.isStub) }
  }

  package static func digest(_ pieces: [String]) -> SourceDigest {
    var bytes = Data()
    for piece in pieces {
      bytes.append(Data("\(piece.utf8.count):".utf8))
      bytes.append(Data(piece.utf8))
    }
    return SourceDigest(bytes: bytes)
  }

  package static func validate(_ pieces: [String], maximumBytes: Int) throws {
    guard pieces.count <= maximumPieces else { throw DreamSourceProtectionError.limitExceeded }
    var total = 0
    for piece in pieces {
      let count = piece.utf8.count
      guard count <= maximumPieceBytes, count <= maximumBytes - total else {
        throw DreamSourceProtectionError.limitExceeded
      }
      total += count
    }
  }

  package static func requireUnchanged(_ original: [String], _ checked: [String]) throws {
    guard original.count == checked.count,
      zip(original, checked).allSatisfy({ Data($0.utf8) == Data($1.utf8) })
    else { throw DreamSourceProtectionError.changed }
  }

  static func isProtectedPath(_ path: String) -> Bool {
    path.lowercased().split(separator: "/").contains {
      $0 == ".env" || $0.hasPrefix(".env.") || $0.contains("credential")
        || $0.contains("auth") || $0 == ".ssh" || $0 == ".aws"
        || $0 == ".netrc" || $0 == ".npmrc" || $0.hasSuffix(".pem")
        || $0.hasSuffix(".key")
    }
  }

  static func omittedReadResults(_ records: [[String: Any]]) throws -> Set<Int> {
    var calls: [String: (name: String, isProtected: Bool)] = [:]
    var omitted: Set<Int> = []
    for (index, record) in records.enumerated() {
      guard let message = record["message"] as? [String: Any] else { continue }
      if message["role"] as? String == "assistant" {
        for block in message["content"] as? [[String: Any]] ?? []
        where block["type"] as? String == "toolCall" {
          guard let id = block["id"] as? String, calls[id] == nil,
            let name = block["name"] as? String
          else { throw DreamSourceProtectionError.blocked }
          if name == "read" {
            guard let arguments = block["arguments"] as? [String: Any],
              let path = arguments["path"] as? String
            else { throw DreamSourceProtectionError.blocked }
            calls[id] = (name, isProtectedPath(path))
          } else {
            calls[id] = (name, false)
          }
        }
      }
      if message["role"] as? String == "toolResult" {
        let call = (message["toolCallId"] as? String).flatMap { calls[$0] }
        if call?.isProtected == true
          || (message["toolName"] as? String == "read" && call?.name != "read")
        {
          omitted.insert(index)
        }
      }
    }
    return omitted
  }

  static func requireAdmissibleReadProvenance(_ records: [[String: Any]]) throws {
    guard try omittedReadResults(records).isEmpty else { throw DreamSourceProtectionError.blocked }
  }

  static func text(_ bytes: Data) throws -> String {
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw DreamSourceProtectionError.blocked
    }
    return text
  }

  static func pieces(_ view: DreamAdmittedView) throws -> [String] {
    try view.records.map {
      let bytes = view.bytes.subdata(in: Int($0.admittedStart)..<Int($0.admittedEnd))
      guard bytes.count <= maximumPieceBytes else { throw DreamSourceProtectionError.limitExceeded }
      return try text(bytes)
    }
  }

  static func pieces(_ batch: PreparedSessionBatch) throws -> [String] {
    if batch.admittedViews.isEmpty {
      try requireAdmissibleReadProvenance(
        try batch.exactSourceRecords.compactMap {
          guard let bytes = $0.bytes else { return nil }
          return try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        })
    }
    var pieces: [String] = try batch.admittedViews.flatMap { try Self.pieces($0) }
    for position in batch.positionsAfter { pieces.append(position.relativePath.rawValue) }
    for record in batch.exactSourceRecords {
      if let bytes = record.bytes { pieces.append(try text(bytes)) }
    }
    for evidence in batch.evidence {
      pieces.append(evidence.exactText)
      if let scope = evidence.projectScope { pieces.append(scope) }
      if let context = evidence.agentContext { pieces.append(context) }
    }
    for selection in batch.selections {
      pieces.append(selection.question)
      pieces += selection.agentWrittenSelectedLabels
    }
    guard let provenance = batch.provenance else { throw DreamSourceProtectionError.blocked }
    for input in provenance.stripping {
      pieces += [input.name, try text(input.bytes)]
    }
    for session in provenance.sessions {
      for record in session.records { pieces.append(try text(record.bytes)) }
    }
    return pieces
  }

  static func rejectedPredecessors(_ predecessors: [DreamRejectedPredecessor]) -> [String] {
    predecessors.flatMap { [$0.revision, $0.path, $0.priorClaim] + $0.sourceSessions }
  }

  static func authority(_ snapshot: ApprovedDecisionSnapshot, owners: [PinnedOwnerInput]) throws
    -> [String]
  {
    var pieces = snapshot.layoutEntries.map(\.path)
    for document in snapshot.documents {
      pieces.append(document.path)
      if let bytes = document.bytes { pieces.append(try text(bytes)) }
    }
    for owner in owners { pieces += [owner.reference, try text(owner.bytes)] }
    return pieces
  }
}
