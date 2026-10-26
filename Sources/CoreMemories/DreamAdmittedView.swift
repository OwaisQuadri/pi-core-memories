import Foundation

package struct DreamAdmittedView: Codable, Equatable, Sendable {
  package struct Record: Codable, Equatable, Sendable {
    package let originalStart: UInt64
    package let originalEnd: UInt64
    package let originalHash: String
    package let originalPrefixHash: String
    package let admittedStart: UInt64
    package let admittedEnd: UInt64
    package let admittedHash: String
    package let identityHash: String
    package let isOmitted: Bool
  }

  package let version: Int
  package let extractionVersion: Int
  package let path: String
  package let originalCompleteBytes: UInt64
  package let originalPrefixHash: String
  package let admittedHash: String
  package let relationHash: String
  package let bytes: Data
  package let records: [Record]
  package var window: Window? = nil

  package struct Window: Codable, Equatable, Sendable {
    package let originalStart: UInt64
    package let originalPrefixHash: String
    package let admittedStart: UInt64
    package let predecessorRelationHash: String?
  }

  func validate() throws {
    guard (version == 1 && window == nil) || (version == 2 && window != nil) else {
      throw DreamSourceProtectionError.invalidReply
    }
    guard extractionVersion == SessionReader.preparationSchemaVersion,
      bytes.count <= DreamSourceProtection.maximumInputBytes,
      records.count <= DreamSourceProtection.maximumPieces,
      SourceDigest(bytes: bytes).rawValue == admittedHash, try binding() == relationHash
    else { throw DreamSourceProtectionError.invalidReply }
    _ = try SourceRelativePath(path)
    _ = try SourceDigest(originalPrefixHash)
    var original: UInt64 = 0
    var admitted: UInt64 = 0
    for record in records {
      guard window != nil || record.originalStart == original,
        record.originalEnd > record.originalStart,
        record.admittedStart == admitted, record.admittedEnd > admitted,
        record.admittedEnd <= UInt64(bytes.count)
      else { throw DreamSourceProtectionError.invalidReply }
      _ = try SourceDigest(record.originalHash)
      _ = try SourceDigest(record.originalPrefixHash)
      let piece = bytes.subdata(in: Int(admitted)..<Int(record.admittedEnd))
      guard piece.last == 10, !piece.dropLast().contains(10),
        SourceDigest(bytes: piece).rawValue == record.admittedHash,
        try Self.identity(piece) == record.identityHash
      else { throw DreamSourceProtectionError.invalidReply }
      if record.isOmitted {
        guard try Self.omitted(piece) == piece else {
          throw DreamSourceProtectionError.invalidReply
        }
      }
      original = record.originalEnd
      admitted = record.admittedEnd
    }
    if let window {
      _ = try SourceDigest(window.originalPrefixHash)
      guard window.admittedStart <= UInt64(bytes.count),
        window.originalStart < originalCompleteBytes
      else { throw DreamSourceProtectionError.invalidReply }
      var offset = window.originalStart
      for record in records.filter({
        $0.originalStart >= window.originalStart && $0.originalEnd <= originalCompleteBytes
      }).sorted(by: { $0.originalStart < $1.originalStart }) {
        guard record.originalStart == offset else { throw DreamSourceProtectionError.invalidReply }
        offset = record.originalEnd
      }
      guard offset == originalCompleteBytes else { throw DreamSourceProtectionError.invalidReply }
    }
    guard window != nil || original == originalCompleteBytes, admitted == UInt64(bytes.count),
      !records.isEmpty,
      records.last?.originalPrefixHash == originalPrefixHash
    else {
      throw DreamSourceProtectionError.invalidReply
    }
  }

  func binding() throws -> String {
    struct Binding: Encodable {
      let version: Int
      let extractionVersion: Int
      let path: String
      let originalCompleteBytes: UInt64
      let originalPrefixHash: String
      let admittedHash: String
      let records: [Record]
      let window: Window?
    }
    return SourceDigest(
      bytes: try DreamRunEncoding.encode(
        Binding(
          version: version, extractionVersion: extractionVersion, path: path,
          originalCompleteBytes: originalCompleteBytes, originalPrefixHash: originalPrefixHash,
          admittedHash: admittedHash, records: records, window: window))
    ).rawValue
  }

  func sealed() throws -> DreamAdmittedView {
    DreamAdmittedView(
      version: version, extractionVersion: extractionVersion, path: path,
      originalCompleteBytes: originalCompleteBytes, originalPrefixHash: originalPrefixHash,
      admittedHash: admittedHash, relationHash: try binding(), bytes: bytes, records: records,
      window: window)
  }

  func requireExtension(of prior: DreamAdmittedView) throws {
    try validate()
    try prior.validate()
    if self == prior { return }
    if let window {
      guard path == prior.path, window.originalStart == prior.originalCompleteBytes,
        window.originalPrefixHash == prior.originalPrefixHash,
        window.predecessorRelationHash == prior.relationHash
      else { throw DreamSourceProtectionError.invalidReply }
      for record in records where record.admittedEnd <= window.admittedStart {
        if let previous = prior.records.first(where: { $0.originalStart == record.originalStart }) {
          guard previous.originalEnd == record.originalEnd,
            previous.originalHash == record.originalHash,
            previous.admittedHash == record.admittedHash,
            previous.identityHash == record.identityHash,
            previous.isOmitted == record.isOmitted
          else { throw DreamSourceProtectionError.invalidReply }
        }
      }
      return
    }
    guard path == prior.path, originalCompleteBytes >= prior.originalCompleteBytes,
      bytes.starts(with: prior.bytes), records.starts(with: prior.records)
    else { throw DreamSourceProtectionError.invalidReply }
  }

  func admittedOffset(original: UInt64) throws -> UInt64 {
    if original == 0 { return 0 }
    if let window, original == window.originalStart { return window.admittedStart }
    guard let record = records.first(where: { $0.originalEnd == original }) else {
      throw DreamSourceProtectionError.invalidReply
    }
    return record.admittedEnd
  }

  func originalOffset(admitted: UInt64) throws -> UInt64 {
    if admitted == 0 { return 0 }
    if let window, admitted == window.admittedStart { return window.originalStart }
    guard let record = records.first(where: { $0.admittedEnd == admitted }) else {
      throw DreamSourceProtectionError.invalidReply
    }
    return record.originalEnd
  }

  func project(_ position: SourcePosition) throws -> SourcePosition {
    let end = try admittedOffset(original: position.completeBytes)
    return SourcePosition(
      relativePath: position.relativePath, sessionID: position.sessionID, completeBytes: end,
      prefixHash: SourceDigest(bytes: bytes.prefix(Int(end))),
      classificationHash: position.classificationHash)
  }

  static func identity(_ bytes: Data) throws -> String {
    guard let object = try SessionReader.decodeRecord(bytes) as? [String: Any] else {
      throw DreamSourceProtectionError.invalidReply
    }
    var fields: [String: Any] = [:]
    for key in ["type", "id", "parentId", "timestamp", "cwd", "parentSession", "name"] {
      fields[key] = object[key]
    }
    if let message = object["message"] as? [String: Any] {
      var identity: [String: Any] = [:]
      for key in ["role", "toolCallId", "toolName", "isError"] { identity[key] = message[key] }
      if let content = message["content"] as? [[String: Any]] {
        identity["content"] = content.map { block -> [String: Any] in
          var value: [String: Any] = [:]
          for key in ["type", "id", "name"] { value[key] = block[key] }
          return value
        }
      }
      fields["message"] = identity
    }
    return SourceDigest(
      bytes: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    ).rawValue
  }

  static func omitted(_ bytes: Data) throws -> Data {
    guard var object = try SessionReader.decodeRecord(bytes) as? [String: Any],
      var message = object["message"] as? [String: Any], message["role"] as? String == "toolResult"
    else { throw DreamSourceProtectionError.blocked }
    message = [
      "role": "toolResult", "toolCallId": message["toolCallId"] ?? "",
      "toolName": message["toolName"] ?? "", "isError": message["isError"] ?? false, "content": [],
    ]
    var stub: [String: Any] = [
      "type": object["type"] ?? "", "id": object["id"] ?? "",
      "timestamp": object["timestamp"] ?? "", "message": message,
    ]
    stub["parentId"] = object["parentId"]
    object = stub
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
  }
}

extension PreparedSessionBatch {
  var admittedViews: [DreamAdmittedView] { provenance?.admittedViews ?? [] }

  func admittedProgress(_ progress: DreamProgress) throws -> DreamProgress {
    try DreamProgress(
      schemaVersion: progress.schemaVersion, generation: progress.generation,
      positions: progress.positions.map { position in
        guard let view = admittedViews.first(where: { $0.path == position.relativePath.rawValue })
        else { return position }
        return try view.project(position)
      })
  }

  func admittedProjection() throws -> PreparedSessionBatch {
    for view in admittedViews { try view.validate() }
    guard Set(admittedViews.map(\.path)).count == admittedViews.count else {
      throw DreamSourceProtectionError.invalidReply
    }
    let positions = try admittedProgress(
      DreamProgress(generation: predecessorGeneration, positions: positionsAfter)
    ).positions
    return PreparedSessionBatch(
      predecessorGeneration: predecessorGeneration, readerSchemaVersion: readerSchemaVersion,
      strippingInputHash: strippingInputHash, positionsAfter: positions,
      exactSourceRecords: exactSourceRecords,
      evidence: evidence, selections: selections,
      unfinishedTails: admittedViews.isEmpty ? unfinishedTails : [], isBacklog: isBacklog,
      provenance: provenance)
  }

  func validateOriginalProgress(_ progress: DreamProgress) throws {
    guard !admittedViews.isEmpty else { return }
    for view in admittedViews { try view.validate() }
    for position in progress.positions + positionsAfter {
      guard let view = admittedViews.first(where: { $0.path == position.relativePath.rawValue })
      else { continue }
      guard position.completeBytes <= view.originalCompleteBytes else {
        throw DreamSourceProtectionError.invalidReply
      }
      let expected =
        view.window?.originalStart == position.completeBytes
        ? view.window?.originalPrefixHash
        : view.records.first(where: { $0.originalEnd == position.completeBytes })?
          .originalPrefixHash
      guard expected == position.prefixHash.rawValue
      else { throw DreamSourceProtectionError.invalidReply }
    }
    for tail in unfinishedTails {
      guard
        tail.byteRange.lowerBound
          >= (positionsAfter.first(where: { $0.relativePath == tail.relativePath })?.completeBytes
            ?? 0)
      else { throw DreamSourceProtectionError.invalidReply }
    }
    for record in exactSourceRecords {
      guard
        let view = admittedViews.first(where: { $0.path == record.witness.relativePath.rawValue }),
        view.records.contains(where: { $0.admittedStart == record.witness.byteRange.lowerBound }),
        view.records.contains(where: { $0.admittedEnd == record.witness.byteRange.upperBound }),
        record.witness.byteRange.upperBound <= UInt64(view.bytes.count)
      else { throw DreamSourceProtectionError.invalidReply }
      let span = view.bytes.subdata(
        in: Int(record.witness.byteRange.lowerBound)..<Int(record.witness.byteRange.upperBound))
      guard SourceDigest(bytes: span) == record.witness.rawRecordHash,
        record.bytes == nil || record.bytes == span
      else { throw DreamSourceProtectionError.invalidReply }
      if record.bytes != nil {
        guard
          view.records.contains(where: {
            $0.admittedStart == record.witness.byteRange.lowerBound
              && $0.admittedEnd == record.witness.byteRange.upperBound
          })
        else { throw DreamSourceProtectionError.invalidReply }
      }
    }
    for classification in provenance?.sessions ?? [] {
      guard let view = admittedViews.first(where: { $0.path == classification.path.rawValue })
      else { throw DreamSourceProtectionError.invalidReply }
      for record in classification.records {
        guard
          view.records.contains(where: {
            $0.admittedStart == record.witness.byteRange.lowerBound
              && $0.admittedEnd == record.witness.byteRange.upperBound
              && $0.admittedHash == record.witness.rawRecordHash.rawValue
          }),
          record.witness.byteRange.upperBound <= UInt64(view.bytes.count),
          view.bytes.subdata(
            in: Int(record.witness.byteRange.lowerBound)..<Int(record.witness.byteRange.upperBound))
            == record.bytes
        else { throw DreamSourceProtectionError.invalidReply }
      }
    }
  }
}
