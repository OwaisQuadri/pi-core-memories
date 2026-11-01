import Foundation

package enum DreamSourceProtectionError: Error, Equatable, Sendable {
  case unavailable, blocked, changed, limitExceeded, requestLimit, timeout, cancelled, invalidReply
}

package enum DreamSourceProtection {
  package static let maximumPieces = 1_000
  package static let maximumPieceBytes = 1_048_576
  package static let maximumInputBytes = 4_194_304
  package static let maximumOutputBytes = 8_388_608
  static let maximumSplitRecordBytes = 2 * maximumPieceBytes
  static let maximumContextBytes = maximumPieceBytes
  static let splitBoundaryBytes = 4_096

  struct SplitText {
    let parts: [String]
    let boundaries: [String]

    var pieces: [String] { parts + boundaries }
  }

  static func split(_ text: String) -> SplitText {
    let bytes = Array(text.utf8)
    guard bytes.count > maximumPieceBytes else { return SplitText(parts: [text], boundaries: []) }
    func aligned(_ offset: Int, isForward: Bool) -> Int {
      var offset = offset
      while offset > 0, offset < bytes.count, bytes[offset] & 0xC0 == 0x80 {
        offset += isForward ? 1 : -1
      }
      return offset
    }
    let count = (bytes.count + maximumPieceBytes - 5) / (maximumPieceBytes - 4)
    let cuts = (1..<count).map { aligned(bytes.count * $0 / count, isForward: true) }
    let edges = [0] + cuts + [bytes.count]
    let windows = cuts.map {
      aligned(max(0, $0 - splitBoundaryBytes), isForward: false)..<aligned(
        min(bytes.count, $0 + splitBoundaryBytes), isForward: true)
    }
    return SplitText(
      parts: zip(edges, edges.dropFirst()).map {
        String(decoding: bytes[$0..<$1], as: UTF8.self)
      },
      boundaries: windows.map { String(decoding: bytes[$0], as: UTF8.self) })
  }

  static func isJoinChecked(left: String, right: String, boundary: String) -> Bool {
    let left = Array(left.utf8)
    let right = Array(right.utf8)
    let boundary = Array(boundary.utf8)
    return (0...boundary.count).contains { split in
      split <= left.count && boundary.count - split <= right.count
        && left.suffix(split).elementsEqual(boundary.prefix(split))
        && right.prefix(boundary.count - split).elementsEqual(boundary.suffix(
          boundary.count - split))
    }
  }

  static func checkedRecords(
    _ records: [(bytes: Data, stub: Data)], admit: ([String]) throws -> [String]
  ) throws -> [(bytes: Data, isStub: Bool)] {
    let requests = try records.map { record in
      let split = split(try text(record.bytes))
      return (split: split, stub: split.boundaries.isEmpty ? [] : [try text(record.stub)])
    }
    let pending = requests.flatMap { $0.split.pieces + $0.stub }
    let checked = pending.isEmpty ? [] : try admit(pending)
    guard checked.count == pending.count else { throw DreamSourceProtectionError.invalidReply }
    var offset = 0
    func take(_ count: Int) -> ArraySlice<String> {
      defer { offset += count }
      return checked[offset..<offset + count]
    }
    return requests.map { request in
      let parts = Array(take(request.split.parts.count))
      let boundaries = Array(take(request.split.boundaries.count))
      let stub = take(request.stub.count)
      let isJoined = boundaries.indices.allSatisfy {
        isJoinChecked(left: parts[$0], right: parts[$0 + 1], boundary: boundaries[$0])
      }
      guard !isJoined, let stub = stub.first else { return (Data(parts.joined().utf8), false) }
      return (Data(stub.utf8), true)
    }
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
    try view.records.flatMap {
      split(try text(view.bytes.subdata(in: Int($0.admittedStart)..<Int($0.admittedEnd))))
        .pieces
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
