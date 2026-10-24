import Foundation

public struct ConnectedDreamEvidence: Sendable {
  public let evidence: [PrimaryTextEvidence]
  public let selections: [SelectionContext]
  public let currentSourceIDs: Set<PrimaryTextID>
  public let windowBindings: [SourceDigest]
  let relatedBatchBytes: [Data]

  public init(
    current: PreparedSessionBatch, relatedBatches: [PreparedSessionBatch] = [],
    limits: DreamInputLimits = try! DreamInputLimits(), maximumBytes: Int = 4_194_304
  ) throws {
    guard relatedBatches.count < 8, maximumBytes > 0 else {
      throw MemoryError("connected dream window limit exceeded")
    }
    let batches = [current] + relatedBatches
    var bindings: [Data] = []
    var totalBytes = 0
    for batch in batches {
      guard batch.readerSchemaVersion == SessionReader.preparationSchemaVersion,
        batch.evidence.count <= limits.maximumBatchRecords,
        batch.exactSourceRecords.count <= 2_001,
        batch.exactSourceRecords.allSatisfy({ ($0.bytes?.count ?? 0) <= limits.maximumRecordBytes })
      else { throw MemoryError("connected dream record limit exceeded") }
      _ = try DreamProgress(positions: batch.positionsAfter)
      let bytes = try DreamRunEncoding.batchBinding(batch, maximumBytes: maximumBytes - totalBytes)
      totalBytes += bytes.count
      bindings.append(bytes)
      try SessionReader.verifyPreparation(batch)
    }
    var connected: Set<Int> = [0]
    var sessions = Set(current.evidence.map { $0.id.citation.session })
    var projects = Set(current.evidence.compactMap(\.projectScope))
    var remaining = Array(1..<batches.count)
    while !remaining.isEmpty {
      let next = remaining.filter { index in
        batches[index].evidence.contains {
          sessions.contains($0.id.citation.session)
            || $0.projectScope.map { !$0.isEmpty && projects.contains($0) } == true
        }
      }
      guard !next.isEmpty else { throw MemoryError("disconnected dream evidence window") }
      for index in next {
        connected.insert(index)
        sessions.formUnion(batches[index].evidence.map { $0.id.citation.session })
        projects.formUnion(batches[index].evidence.compactMap(\.projectScope))
      }
      remaining.removeAll { connected.contains($0) }
    }
    var catalogue: [PrimaryTextID: PrimaryTextEvidence] = [:]
    var selections: [Citation: SelectionContext] = [:]
    var keptBytes = 0
    for batch in batches {
      for unit in batch.evidence {
        if let prior = catalogue[unit.id] {
          guard Self.isIdentical(prior, unit) else {
            throw MemoryError("conflicting dream evidence identity")
          }
          continue
        }
        guard unit.exactText.utf8.count <= limits.maximumEvidenceBytes,
          (unit.agentContext?.utf8.count ?? 0) <= limits.maximumEvidenceBytes,
          catalogue.count < limits.maximumBatchRecords
        else { throw MemoryError("connected dream evidence limit exceeded") }
        let size = unit.exactText.utf8.count + (unit.agentContext?.utf8.count ?? 0)
        guard size <= limits.maximumBatchBytes - keptBytes else {
          throw MemoryError("connected dream byte limit exceeded")
        }
        keptBytes += size
        catalogue[unit.id] = unit
      }
      for selection in batch.selections {
        if let prior = selections[selection.citation] {
          guard Data(prior.question.utf8) == Data(selection.question.utf8),
            prior.agentWrittenSelectedLabels.map({ Data($0.utf8) })
              == selection.agentWrittenSelectedLabels.map({ Data($0.utf8) })
          else { throw MemoryError("conflicting dream selection identity") }
          continue
        }
        let size = selection.agentWrittenSelectedLabels.reduce(selection.question.utf8.count) {
          $0 + $1.utf8.count
        }
        guard size <= limits.maximumBatchBytes - keptBytes else {
          throw MemoryError("connected dream byte limit exceeded")
        }
        keptBytes += size
        selections[selection.citation] = selection
      }
    }
    evidence = catalogue.values.sorted { isSourceOrdered($0.id, $1.id) }
    self.selections = selections.values.sorted {
      $0.citation.reference < $1.citation.reference
    }
    currentSourceIDs = Set(current.evidence.map(\.id))
    windowBindings = bindings.map { SourceDigest(bytes: $0) }
    relatedBatchBytes = Array(bindings.dropFirst())
  }

  private static func isIdentical(_ lhs: PrimaryTextEvidence, _ rhs: PrimaryTextEvidence) -> Bool {
    lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.witness == rhs.witness
      && lhs.timestamp.timeIntervalSinceReferenceDate.bitPattern
        == rhs.timestamp.timeIntervalSinceReferenceDate.bitPattern
      && lhs.projectScope.map({ Data($0.utf8) }) == rhs.projectScope.map({ Data($0.utf8) })
      && Data(lhs.exactText.utf8) == Data(rhs.exactText.utf8)
      && lhs.agentContext.map({ Data($0.utf8) }) == rhs.agentContext.map({ Data($0.utf8) })
  }
}
