import Foundation

struct MemoryBatchAnchor: Codable, Equatable, Sendable {
  let path: String
  let start: Int
  let end: Int
  let before: Data
}

struct MemoryBatchEffect: Codable, Equatable, Sendable {
  enum AdditionStyle: String, Codable, Sendable { case manual, candidate }
  let itemID: UUID
  let path: String
  let start: Int
  let end: Int
  let before: Data
  let after: Data
  let identity: UUID?
  let originalReviewedProposal: Data?
  let additionStyle: AdditionStyle
  let readAnchors: [MemoryBatchAnchor]

  var range: Range<Int> { start..<end }
}

struct VerifiedMemoryPublication {
  let base: String
  let commit: String
  let effects: [MemoryBatchEffect]
}

struct MemoryBatchManifest: Codable, Sendable {
  let schemaVersion: Int
  let compositionVersion: Int
  let saveID: String
  let intentDigest: String
  let draft: MemoryDraft
  let effects: [MemoryBatchEffect]
  let documentDigests: [String: String]
}

struct MemoryBatchComposition {
  let effects: [MemoryBatchEffect]
  let replacements: [String: Data]

  static func prepare(
    _ draft: MemoryDraft, snapshot: ApprovedDecisionSnapshot, manager: MemoryManagement,
    candidate: (MemoryBatchItem, MemoryBatchCandidateIntent) throws -> MemoryBatchEffect?
  ) throws -> Self {
    guard draft.schemaVersion == 2, let batch = draft.batch, draft.operations.isEmpty,
      !batch.items.isEmpty, batch.items.count <= 256, draft.baseCommit == snapshot.base,
      Set(batch.items.map(\.itemID)).count == batch.items.count
    else { throw MemoryError("Save requires a complete typed batch") }
    var effects: [MemoryBatchEffect] = []
    var candidateIDs: Set<String> = []
    for item in batch.items {
      switch item.intent {
      case .manual(let manual):
        let request = manual.request
        guard [.add, .update, .delete].contains(request.operation), request.base == snapshot.base,
          let path = request.path, batch.binding.allowedPaths.contains(path)
        else { throw MemoryError("batch contains a foreign or non-CRUD manual request") }
        let change = try manager.prepare(
          request, snapshot: snapshot, date: manual.date, newIdentity: manual.identity)
        let document = snapshot.documents.first { $0.path == path }?.bytes ?? Data()
        let range = request.operation == .add ? document.count..<document.count : change.range
        let after: Data
        if request.operation == .add {
          let original =
            snapshot.documents.first { $0.path == path }?.bytes ?? Data("# Memory\n".utf8)
          after = Data(change.insertion.dropFirst(manualSeparator(original).count))
        } else {
          after = change.insertion
        }
        effects.append(
          MemoryBatchEffect(
            itemID: item.itemID, path: path, start: range.lowerBound, end: range.upperBound,
            before: Data(document[range]), after: after,
            identity: request.operation == .delete
              ? nil : MemoryDocument.entries(in: after).first?.identity,
            originalReviewedProposal: nil, additionStyle: .manual, readAnchors: []))
      case .confirmReviewed(let review):
        let entry = review.entry
        guard batch.binding.allowedPaths.contains(entry.path),
          let target = snapshot.reviewEntries().first(where: {
            $0.path == entry.path && $0.entry.locator == entry.locator
          })?.entry, target.isMutable, target.bytes == Data(entry.expected.utf8),
          target.identity == nil || target.identity == review.identity
        else { throw MemoryError("Confirm Reviewed target changed or is outside the batch scope") }
        let after = try MemoryDocument.reviewedBytes(
          target.bytes, identity: review.identity, instant: review.instant)
        effects.append(
          MemoryBatchEffect(
            itemID: item.itemID, path: entry.path, start: entry.locator.start,
            end: entry.locator.end,
            before: target.bytes, after: after, identity: review.identity,
            originalReviewedProposal: nil, additionStyle: .manual, readAnchors: []))
      case .candidate(let intent):
        guard candidateIDs.insert(intent.candidateID).inserted else {
          throw MemoryError("duplicate candidate in batch")
        }
        if let effect = try candidate(item, intent) {
          guard batch.binding.allowedPaths.contains(effect.path) else {
            throw MemoryError("candidate is outside the prepared scope")
          }
          effects.append(effect)
        }
      }
    }
    return Self(effects: effects, replacements: try compose(effects, snapshot: snapshot))
  }

  static func compose(_ effects: [MemoryBatchEffect], snapshot: ApprovedDecisionSnapshot) throws
    -> [String: Data]
  {
    for effect in effects {
      for anchor in effect.readAnchors {
        for other in effects where other.itemID != effect.itemID && other.path == anchor.path {
          guard !isOverlapping(other.range, anchor.start..<anchor.end) else {
            throw MemoryError("a batch member changes another member's required memory anchor")
          }
        }
      }
    }
    var replacements: [String: Data] = [:]
    for path in Set(effects.map(\.path)) {
      let edits = effects.filter { $0.path == path }
      let original = snapshot.documents.first { $0.path == path }?.bytes
      var document =
        original ?? (edits.first?.additionStyle == .manual ? Data("# Memory\n".utf8) : Data())
      let targets = edits.filter { !$0.range.isEmpty }.sorted { $0.start < $1.start }
      for pair in zip(targets, targets.dropFirst()) {
        guard pair.0.end <= pair.1.start else { throw MemoryError("overlapping batch targets") }
      }
      for edit in edits {
        guard edit.start >= 0, edit.end >= edit.start,
          edit.end <= (original?.count ?? 0),
          Data((original ?? Data())[edit.range]) == edit.before,
          !edit.range.isEmpty || edit.start == (original?.count ?? 0),
          edit.before != edit.after
        else { throw MemoryError("stale, invalid or unchanged batch effect") }
      }
      for edit in targets.reversed() { document.replaceSubrange(edit.range, with: edit.after) }
      for edit in edits where edit.range.isEmpty {
        document.append(
          edit.additionStyle == .candidate
            ? candidateSeparator(document) : manualSeparator(document))
        document.append(edit.after)
      }
      guard document.count <= 1_048_576, MemoryDocument.failures(in: document).isEmpty,
        document != original
      else { throw MemoryError("invalid or unchanged composed memory document") }
      let entries = MemoryDocument.entries(in: document)
      for edit in edits where !edit.after.isEmpty {
        let matches = entries.filter { $0.identity == edit.identity }
        guard edit.identity != nil, matches.count == 1, matches[0].isMutable,
          matches[0].bytes == edit.after
        else {
          throw MemoryError("composed entry bytes or identities differ from reviewed effects")
        }
      }
      replacements[path] = document
    }
    let identities =
      snapshot.documents.flatMap { document in
        MemoryDocument.entries(in: replacements[document.path] ?? document.bytes ?? Data())
          .compactMap(\.identity)
      }
      + replacements.filter { path, _ in !snapshot.documents.contains { $0.path == path } }
      .flatMap { MemoryDocument.entries(in: $0.value).compactMap(\.identity) }
    guard Set(identities).count == identities.count else {
      throw MemoryError("duplicate memory identity in final batch")
    }
    return replacements
  }

  static func transformed(
    _ range: Range<Int>, path: String, publications: [VerifiedMemoryPublication]
  ) throws -> Range<Int> {
    var current = range
    for publication in publications {
      let effects = publication.effects.filter { $0.path == path }
      var delta = 0
      for effect in effects {
        guard !isOverlapping(effect.range, current) else {
          throw MemoryError("approved publication overlaps the selected memory")
        }
        if effect.end <= current.lowerBound {
          delta += effect.after.count - effect.before.count
        }
      }
      current = (current.lowerBound + delta)..<(current.upperBound + delta)
    }
    return current
  }

  static func isOverlapping(_ first: Range<Int>, _ second: Range<Int>) -> Bool {
    if first.isEmpty {
      return first.lowerBound > second.lowerBound && first.lowerBound < second.upperBound
    }
    return first.lowerBound < second.upperBound && second.lowerBound < first.upperBound
  }

  static func manualSeparator(_ bytes: Data) -> Data {
    bytes.isEmpty || bytes.suffix(2) == Data([10, 10])
      ? Data()
      : bytes.last == 10 ? Data([10]) : Data([10, 10])
  }

  static func candidateSeparator(_ bytes: Data) -> Data {
    Data(
      (bytes.isEmpty ? "# Memory\n\n" : bytes.last == 10 || bytes.last == 13 ? "\n" : "\n\n").utf8)
  }
}
