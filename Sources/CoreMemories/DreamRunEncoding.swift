import Foundation

public struct FrozenDreamRun: Sendable {
  public let runID: String
  public let selection: DreamSelectedCall
  public let approvedBase: String
  public let inputHash: SourceDigest
  public let progress: DreamProgress
  public let batch: PreparedSessionBatch
  let predecessorProgressHash: SourceDigest?
  private let validatedByteCount: Int
  private let bindingBytes: Data

  fileprivate init(
    runID: String, selection: DreamSelectedCall, approvedBase: String, inputHash: SourceDigest,
    progress: DreamProgress, batch: PreparedSessionBatch,
    predecessorProgressHash: SourceDigest?, validatedByteCount: Int, bindingBytes: Data
  ) {
    self.runID = runID
    self.selection = selection
    self.approvedBase = approvedBase
    self.inputHash = inputHash
    self.progress = progress
    self.batch = batch
    self.predecessorProgressHash = predecessorProgressHash
    self.validatedByteCount = validatedByteCount
    self.bindingBytes = bindingBytes
  }

  func decisionBinding(maximumFrozenBytes: Int) throws -> Data {
    guard validatedByteCount <= maximumFrozenBytes else { throw DreamRunError.limitExceeded }
    return bindingBytes
  }
}

enum DreamRunEncoding {
  static let maximumMetadataBytes = 1_048_576

  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  static func decode<T: Codable>(_ type: T.Type, bytes: Data) throws -> T {
    do {
      let decoder = JSONDecoder()
      let schema = try decoder.decode(Schema.self, from: bytes)
      guard schema.schemaVersion == 2 else { throw DreamRunError.unsupportedSchema }
      let value = try decoder.decode(type, from: bytes)
      let encoded = try encode(value)
      if bytes == encoded { return value }
      guard let supplied = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary,
        let reconstructed = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
        supplied == reconstructed
      else { throw DreamRunError.corruption }
      return value
    } catch let error as DreamRunError { throw error } catch {
      throw DreamRunError.corruption
    }
  }

  static func isRunID(_ value: String) -> Bool {
    UUID(uuidString: value)?.uuidString.lowercased() == value
  }

  static func input(
    runID: String, context: DreamRunContext, bindingHash: SourceDigest,
    progress: DreamProgress, batch: PreparedSessionBatch, limits: DreamRunLimits,
    predecessorProgressHash: SourceDigest? = nil
  ) throws -> Data {
    do {
      try validate(progress: progress, batch: batch, limits: limits)
    } catch let error as DreamRunError { throw error } catch { throw DreamRunError.corruption }
    let bytes = try encode(
      Input(
        schemaVersion: 2, runID: runID, bindingHash: bindingHash.rawValue,
        selection: Selection(context.selection), approvedBase: context.currentApprovedBase,
        progress: Progress(progress), batch: Batch(batch),
        predecessorProgressHash: predecessorProgressHash?.rawValue))
    guard bytes.count <= limits.maximumFrozenBytes else { throw DreamRunError.limitExceeded }
    return bytes
  }

  static func frozen(
    bytes: Data, runID: String, inputHash: SourceDigest, bindingHash: SourceDigest,
    limits: DreamRunLimits
  ) throws -> FrozenDreamRun {
    guard bytes.count <= limits.maximumFrozenBytes else { throw DreamRunError.limitExceeded }
    let hash = SourceDigest(bytes: bytes)
    guard hash == inputHash else { throw DreamRunError.corruption }
    let input = try decode(Input.self, bytes: bytes)
    guard input.runID == runID, isRunID(input.runID),
      input.bindingHash == bindingHash.rawValue
    else { throw DreamRunError.corruption }
    do {
      let selection = try input.selection.domain()
      let context = try DreamRunContext(
        selection: selection, currentApprovedBase: input.approvedBase)
      guard input.progress.positions.count <= limits.maximumPositions,
        input.batch.positionsAfter.count <= limits.maximumPositions
      else { throw DreamRunError.limitExceeded }
      let progress = try input.progress.domain()
      let batch = try input.batch.domain()
      let validatedByteCount = try validate(progress: progress, batch: batch, limits: limits)
      let predecessorProgressHash = try input.predecessorProgressHash.map(SourceDigest.init)
      let bindingBytes = try encode(
        Input(
          schemaVersion: 2, runID: input.runID,
          bindingHash: SourceDigest(bytes: Data()).rawValue,
          selection: Selection(selection), approvedBase: context.currentApprovedBase,
          progress: Progress(progress), batch: Batch(batch),
          predecessorProgressHash: predecessorProgressHash?.rawValue))
      return FrozenDreamRun(
        runID: input.runID, selection: selection, approvedBase: context.currentApprovedBase,
        inputHash: hash, progress: progress, batch: batch,
        predecessorProgressHash: predecessorProgressHash,
        validatedByteCount: validatedByteCount, bindingBytes: bindingBytes)
    } catch let error as DreamRunError { throw error } catch { throw DreamRunError.corruption }
  }

  @discardableResult
  static func validate(
    progress: DreamProgress, batch: PreparedSessionBatch, limits: DreamRunLimits
  ) throws -> Int {
    guard batch.predecessorGeneration == progress.generation else {
      throw DreamRunError.staleGeneration
    }
    guard progress.schemaVersion == 1, batch.readerSchemaVersion == 1 else {
      throw DreamRunError.unsupportedSchema
    }
    guard progress.positions.count <= limits.maximumPositions,
      batch.positionsAfter.count <= limits.maximumPositions
    else { throw DreamRunError.limitExceeded }
    try SessionReader.verifyPreparation(batch)
    var aggregate = 0
    func count(_ size: Int) throws {
      guard size <= limits.maximumFrozenBytes - aggregate else { throw DreamRunError.limitExceeded }
      aggregate += size
    }
    for record in batch.exactSourceRecords { try count(record.bytes?.count ?? 0) }
    for evidence in batch.evidence {
      try count(evidence.exactText.utf8.count)
      try count(evidence.agentContext?.utf8.count ?? 0)
      try count(evidence.projectScope?.utf8.count ?? 0)
    }
    for context in batch.selections {
      try count(context.question.utf8.count)
      for label in context.agentWrittenSelectedLabels { try count(label.utf8.count) }
    }
    _ = try DreamProgress(positions: batch.positionsAfter)
    let old = Dictionary(uniqueKeysWithValues: progress.positions.map { ($0.relativePath, $0) })
    let after = Dictionary(uniqueKeysWithValues: batch.positionsAfter.map { ($0.relativePath, $0) })
    guard batch.positionsAfter.allSatisfy({ $0.completeBytes > 0 })
    else { throw DreamRunError.corruption }
    for position in progress.positions {
      guard let next = after[position.relativePath], next.completeBytes >= position.completeBytes,
        next.sessionID == position.sessionID,
        next.classificationHash == position.classificationHash,
        next.completeBytes != position.completeBytes || next == position
      else { throw DreamRunError.corruption }
    }
    var offsets = old.mapValues(\.completeBytes)
    var prefixes: [SourceRelativePath: Data] = [:]
    var unhashedPrefixes: Set<SourceRelativePath> = []
    var witnesses: [RecordWitnessKey: (session: String, entry: String)] = [:]
    var dispositionIDs: Set<PrimaryTextID> = []
    var recordCitations: Set<Citation> = []
    var selectionCitations: Set<Citation> = []
    for record in batch.exactSourceRecords {
      let witness = record.witness
      let range = witness.byteRange
      guard let bytes = record.bytes else {
        guard case .skipped = record.disposition, range.lowerBound > 0,
          range.lowerBound < range.upperBound,
          let position = after[witness.relativePath], range.upperBound <= position.completeBytes,
          range.lowerBound == (offsets[witness.relativePath] ?? 0)
        else { throw DreamRunError.corruption }
        offsets[witness.relativePath] = range.upperBound
        unhashedPrefixes.insert(witness.relativePath)
        continue
      }
      guard range.lowerBound < range.upperBound,
        range.upperBound - range.lowerBound == UInt64(bytes.count),
        bytes.last == 0x0A, !bytes.dropLast().contains(0x0A),
        String(data: bytes, encoding: .utf8) != nil,
        SourceDigest(bytes: bytes) == witness.rawRecordHash,
        let position = after[witness.relativePath], range.upperBound <= position.completeBytes,
        range.lowerBound == (offsets[witness.relativePath] ?? 0),
        let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        let entry = object["id"] as? String
      else { throw DreamRunError.corruption }
      let citation = Citation(session: position.sessionID.rawValue, entry: entry)
      guard range.lowerBound != 0 || object["type"] as? String == "session" else {
        throw DreamRunError.corruption
      }
      if object["type"] as? String == "session" {
        guard range.lowerBound == 0, entry == position.sessionID.rawValue else {
          throw DreamRunError.corruption
        }
      } else {
        try validateCitation(citation)
      }
      guard recordCitations.insert(citation).inserted else { throw DreamRunError.corruption }
      offsets[witness.relativePath] = range.upperBound
      if old[witness.relativePath] == nil {
        prefixes[witness.relativePath, default: Data()].append(bytes)
      }
      let key = RecordWitnessKey(witness)
      guard witnesses.updateValue((citation.session, citation.entry), forKey: key) == nil else {
        throw DreamRunError.corruption
      }
      switch record.disposition {
      case .primaryEvidence(let ids):
        guard !ids.isEmpty else { throw DreamRunError.corruption }
        for id in ids {
          try validateID(id)
          guard id.citation == citation, dispositionIDs.insert(id).inserted else {
            throw DreamRunError.corruption
          }
        }
      case .excluded(let reason):
        if reason == .selectionsOnlyV1 { selectionCitations.insert(citation) }
      case .skipped: throw DreamRunError.corruption
      }
    }
    for position in batch.positionsAfter {
      guard offsets[position.relativePath] == position.completeBytes else {
        throw DreamRunError.corruption
      }
      if let prefix = prefixes[position.relativePath],
        !unhashedPrefixes.contains(position.relativePath)
      {
        guard SourceDigest(bytes: prefix) == position.prefixHash else {
          throw DreamRunError.corruption
        }
      }
    }
    var evidenceIDs: Set<PrimaryTextID> = []
    for evidence in batch.evidence {
      try validateID(evidence.id)
      guard evidenceIDs.insert(evidence.id).inserted, !evidence.exactText.isEmpty,
        evidence.timestamp.timeIntervalSinceReferenceDate.isFinite,
        let record = witnesses[RecordWitnessKey(evidence.witness)],
        record.session == evidence.id.citation.session, record.entry == evidence.id.citation.entry,
        UInt64(evidence.id.part) < evidence.witness.byteRange.upperBound
          - evidence.witness.byteRange.lowerBound,
        evidence.kind == .answered || evidence.id.part == 0
      else { throw DreamRunError.corruption }
      if evidence.kind == .answered { selectionCitations.insert(evidence.id.citation) }
    }
    guard evidenceIDs == dispositionIDs else { throw DreamRunError.corruption }
    var contexts: Set<Citation> = []
    for context in batch.selections {
      try validateCitation(context.citation)
      guard contexts.insert(context.citation).inserted,
        selectionCitations.contains(context.citation)
      else { throw DreamRunError.corruption }
    }
    guard contexts == selectionCitations else { throw DreamRunError.corruption }
    var tailPaths: Set<SourceRelativePath> = []
    for tail in batch.unfinishedTails {
      guard tailPaths.insert(tail.relativePath).inserted,
        tail.byteRange.lowerBound < tail.byteRange.upperBound,
        tail.byteRange.lowerBound >= (after[tail.relativePath]?.completeBytes ?? 0)
      else { throw DreamRunError.corruption }
    }
    if batch.exactSourceRecords.isEmpty {
      guard batch.positionsAfter == progress.positions, batch.evidence.isEmpty,
        batch.selections.isEmpty, !batch.isBacklog
      else { throw DreamRunError.corruption }
    }
    return aggregate
  }

  private static func validateCitation(_ citation: Citation) throws {
    _ = try SessionIdentifier(citation.session)
    guard !citation.entry.isEmpty,
      citation.entry.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || $0 == 45 || $0 == 95
      })
    else { throw DreamRunError.corruption }
  }

  private static func validateID(_ id: PrimaryTextID) throws {
    try validateCitation(id.citation)
    guard id.part >= 0 else { throw DreamRunError.corruption }
  }

  private struct RecordWitnessKey: Hashable {
    let path: SourceRelativePath
    let lower: UInt64
    let upper: UInt64
    let hash: SourceDigest

    init(_ witness: RecordWitness) {
      path = witness.relativePath
      lower = witness.byteRange.lowerBound
      upper = witness.byteRange.upperBound
      hash = witness.rawRecordHash
    }
  }

  private struct Schema: Decodable {
    let schemaVersion: Int
  }

  struct Selection: Codable {
    let provider: String
    let modelID: String
    let thinkingLevel: String

    init(_ value: DreamSelectedCall) {
      provider = value.provider
      modelID = value.modelID
      thinkingLevel = value.thinkingLevel
    }

    func domain() throws -> DreamSelectedCall {
      try DreamSelectedCall(provider: provider, modelID: modelID, thinkingLevel: thinkingLevel)
    }
  }

  struct Position: Codable {
    let relativePath: String
    let sessionID: String
    let completeBytes: UInt64
    let prefixHash: String
    let classificationHash: String

    init(_ value: SourcePosition) {
      relativePath = value.relativePath.rawValue
      sessionID = value.sessionID.rawValue
      completeBytes = value.completeBytes
      prefixHash = value.prefixHash.rawValue
      classificationHash = value.classificationHash.rawValue
    }

    func domain() throws -> SourcePosition {
      guard completeBytes > 0 else { throw DreamRunError.corruption }
      return try SourcePosition(
        relativePath: SourceRelativePath(relativePath), sessionID: SessionIdentifier(sessionID),
        completeBytes: completeBytes, prefixHash: SourceDigest(prefixHash),
        classificationHash: SourceDigest(classificationHash))
    }
  }

  struct Progress: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let positions: [Position]

    init(_ value: DreamProgress) {
      schemaVersion = value.schemaVersion
      generation = value.generation
      positions = value.positions.map(Position.init)
    }

    func domain() throws -> DreamProgress {
      try DreamProgress(
        schemaVersion: schemaVersion, generation: generation,
        positions: positions.map { try $0.domain() })
    }
  }

  private struct Witness: Codable {
    let relativePath: String
    let lower: UInt64
    let upper: UInt64
    let rawRecordHash: String

    init(_ value: RecordWitness) {
      relativePath = value.relativePath.rawValue
      lower = value.byteRange.lowerBound
      upper = value.byteRange.upperBound
      rawRecordHash = value.rawRecordHash.rawValue
    }

    func domain() throws -> RecordWitness {
      guard lower < upper else { throw DreamRunError.corruption }
      return try RecordWitness(
        relativePath: SourceRelativePath(relativePath), byteRange: lower..<upper,
        rawRecordHash: SourceDigest(rawRecordHash))
    }
  }

  struct ID: Codable {
    let session: String
    let entry: String
    let part: Int

    init(_ value: PrimaryTextID) {
      session = value.citation.session
      entry = value.citation.entry
      part = value.part
    }

    func domain() throws -> PrimaryTextID {
      let id = PrimaryTextID(citation: Citation(session: session, entry: entry), part: part)
      try validateID(id)
      return id
    }
  }

  private struct Record: Codable {
    let witness: Witness
    let bytes: Data?
    let tag: String
    let ids: [ID]?
    let exclusion: String?

    init(_ value: ExactSourceRecord) {
      witness = Witness(value.witness)
      bytes = value.bytes
      switch value.disposition {
      case .skipped:
        tag = "skipped"
        ids = nil
        exclusion = nil
      case .primaryEvidence(let values):
        tag = "primaryEvidence"
        ids = values.map(ID.init)
        exclusion = nil
      case .excluded(let reason):
        tag = "excluded"
        ids = nil
        exclusion = reason.rawValue
      }
    }

    func domain() throws -> ExactSourceRecord {
      let disposition: RecordDisposition
      switch tag {
      case "primaryEvidence":
        guard let ids, exclusion == nil else { throw DreamRunError.corruption }
        disposition = .primaryEvidence(try ids.map { try $0.domain() })
      case "excluded":
        guard ids == nil, let exclusion, let reason = ExclusionReason(rawValue: exclusion) else {
          throw DreamRunError.corruption
        }
        disposition = .excluded(reason)
      case "skipped":
        guard ids == nil, exclusion == nil, bytes == nil else { throw DreamRunError.corruption }
        disposition = .skipped
      default: throw DreamRunError.corruption
      }
      guard tag == "skipped" || bytes != nil else { throw DreamRunError.corruption }
      return try ExactSourceRecord(
        witness: witness.domain(), bytes: bytes, disposition: disposition)
    }
  }

  private struct Evidence: Codable {
    let id: ID
    let kind: String
    let timestampBits: UInt64
    let projectScope: String?
    let exactText: String
    let witness: Witness
    let agentContext: String?

    init(_ value: PrimaryTextEvidence) {
      id = ID(value.id)
      kind = value.kind.rawValue
      timestampBits = value.timestamp.timeIntervalSinceReferenceDate.bitPattern
      projectScope = value.projectScope
      exactText = value.exactText
      witness = Witness(value.witness)
      agentContext = value.agentContext
    }

    func domain() throws -> PrimaryTextEvidence {
      guard let kind = PrimaryTextKind(rawValue: kind) else { throw DreamRunError.corruption }
      let time = Double(bitPattern: timestampBits)
      guard time.isFinite else { throw DreamRunError.corruption }
      return try PrimaryTextEvidence(
        id: id.domain(), kind: kind, timestamp: Date(timeIntervalSinceReferenceDate: time),
        projectScope: projectScope, exactText: exactText, witness: witness.domain(),
        agentContext: agentContext)
    }
  }

  private struct Context: Codable {
    let session: String
    let entry: String
    let question: String
    let agentWrittenSelectedLabels: [String]

    init(_ value: SelectionContext) {
      session = value.citation.session
      entry = value.citation.entry
      question = value.question
      agentWrittenSelectedLabels = value.agentWrittenSelectedLabels
    }

    func domain() throws -> SelectionContext {
      let citation = Citation(session: session, entry: entry)
      try validateCitation(citation)
      return SelectionContext(
        citation: citation, question: question,
        agentWrittenSelectedLabels: agentWrittenSelectedLabels)
    }
  }

  struct Tail: Codable {
    let relativePath: String
    let lower: UInt64
    let upper: UInt64

    init(_ value: UnfinishedSessionTail) {
      relativePath = value.relativePath.rawValue
      lower = value.byteRange.lowerBound
      upper = value.byteRange.upperBound
    }

    func domain() throws -> UnfinishedSessionTail {
      guard lower < upper else { throw DreamRunError.corruption }
      return try UnfinishedSessionTail(
        relativePath: SourceRelativePath(relativePath), byteRange: lower..<upper)
    }
  }

  private struct Batch: Codable {
    let predecessorGeneration: UInt64
    let readerSchemaVersion: Int
    let strippingInputHash: String
    let positionsAfter: [Position]
    let exactSourceRecords: [Record]
    let evidence: [Evidence]
    let selections: [Context]
    let unfinishedTails: [Tail]
    let isBacklog: Bool
    let provenance: Provenance?

    init(_ value: PreparedSessionBatch) {
      predecessorGeneration = value.predecessorGeneration
      readerSchemaVersion = value.readerSchemaVersion
      strippingInputHash = value.strippingInputHash.rawValue
      positionsAfter = value.positionsAfter.map(Position.init)
      exactSourceRecords = value.exactSourceRecords.map(Record.init)
      evidence = value.evidence.map(Evidence.init)
      selections = value.selections.map(Context.init)
      unfinishedTails = value.unfinishedTails.map(Tail.init)
      isBacklog = value.isBacklog
      provenance = value.provenance.map(Provenance.init)
    }

    func domain() throws -> PreparedSessionBatch {
      try PreparedSessionBatch(
        predecessorGeneration: predecessorGeneration, readerSchemaVersion: readerSchemaVersion,
        strippingInputHash: SourceDigest(strippingInputHash),
        positionsAfter: positionsAfter.map { try $0.domain() },
        exactSourceRecords: exactSourceRecords.map { try $0.domain() },
        evidence: evidence.map { try $0.domain() }, selections: selections.map { try $0.domain() },
        unfinishedTails: unfinishedTails.map { try $0.domain() }, isBacklog: isBacklog,
        provenance: try provenance?.domain())
    }
  }

  private struct Provenance: Codable {
    let stripping: [Stripping]
    let sessions: [Classification]

    struct Stripping: Codable {
      let kind: String
      let name: String
      let bytes: Data
    }

    struct Classification: Codable {
      let path: String
      let records: [ClassificationRecord]
    }

    struct ClassificationRecord: Codable {
      let witness: Witness
      let bytes: Data
    }

    init(_ value: PreparationProvenance) {
      stripping = value.stripping.map { Stripping(kind: $0.kind, name: $0.name, bytes: $0.bytes) }
      sessions = value.sessions.map {
        Classification(
          path: $0.path.rawValue,
          records: $0.records.map {
            ClassificationRecord(witness: Witness($0.witness), bytes: $0.bytes)
          })
      }
    }

    func domain() throws -> PreparationProvenance {
      try PreparationProvenance(
        stripping: stripping.map {
          PreparationStrippingInput(kind: $0.kind, name: $0.name, bytes: $0.bytes)
        },
        sessions: sessions.map {
          try PreparationClassificationWitness(
            path: SourceRelativePath($0.path),
            records: $0.records.map {
              try PreparationClassificationRecord(witness: $0.witness.domain(), bytes: $0.bytes)
            })
        })
    }
  }

  private struct Input: Codable {
    let schemaVersion: Int
    let runID: String
    let bindingHash: String
    let selection: Selection
    let approvedBase: String
    let progress: Progress
    let batch: Batch
    let predecessorProgressHash: String?
  }

}

extension DreamRunEncoding {
  struct Generation: Codable {
    let schemaVersion: Int
    let bindingHash: String
    let predecessorHash: String?
    let admissionHash: String?
    let completionHash: String?
    let runID: String?
    let progress: Progress
  }

  struct Admission: Codable {
    let schemaVersion: Int
    let bindingHash: String
    let generation: UInt64
    let predecessorHash: String
    let runID: String
    let inputHash: String
    let contextHash: String
    let requestHash: String
    let selection: Selection
    let base: String
  }

  struct State: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let generationHash: String
    let admissionHash: String?
    let runID: String?
  }

  struct Request: Codable {
    let schemaVersion: Int
    let runID: String
    let generation: UInt64
    let inputHash: String
    let contextHash: String
    let systemPrompt: String
    let messages: [DreamRequestMessage]

    func domain(run: FrozenDreamRun, context: DreamDecisionContext, bytes: Data) throws
      -> DreamModelRequest
    {
      guard schemaVersion == 2, runID == run.runID, generation == run.progress.generation,
        inputHash == run.inputHash.rawValue, contextHash == context.contextHash.rawValue,
        systemPrompt == context.savedSystemPrompt, messages.count == 1,
        messages[0].role == .user,
        messages
          == (try context.requestMessages(
            timestampMilliseconds: messages[0].timestampMilliseconds))
      else { throw DreamRunError.corruption }
      return DreamModelRequest(
        runID: runID, generation: generation, inputHash: run.inputHash,
        contextHash: context.contextHash, requestHash: SourceDigest(bytes: bytes),
        selection: run.selection, systemPrompt: systemPrompt, messages: messages)
    }
  }

  struct Intent: Codable {
    let schemaVersion: Int
    let admissionHash: String
    let requestHash: String
    let selection: Selection?
  }

  struct ReplacementIntent: Codable {
    let schemaVersion: Int
    let admissionHash: String
    let requestHash: String
    let rejectedResponseHash: String
  }

  struct BoundResponse: Codable {
    let schemaVersion: Int
    let admissionHash: String
    let runID: String
    let generation: UInt64
    let inputHash: String
    let contextHash: String
    let requestHash: String
    let selection: Selection
    let text: String

    func domain(
      run: FrozenDreamRun, context: DreamDecisionContext, request: DreamModelRequest,
      admissionHash: SourceDigest, selection: DreamSelectedCall, bytes: Data,
      maximumResponseBytes: Int
    ) throws -> DurableDreamResponse {
      guard self.admissionHash == admissionHash.rawValue,
        runID == run.runID, generation == run.progress.generation,
        inputHash == run.inputHash.rawValue, contextHash == context.contextHash.rawValue,
        requestHash == request.requestHash.rawValue, try self.selection.domain() == selection,
        text.utf8.count <= maximumResponseBytes
      else { throw DreamRunError.corruption }
      return DurableDreamResponse(
        run: run, response: try DreamCompletedResponse(text: text),
        responseHash: SourceDigest(bytes: bytes), isReplay: true, isBaseCurrent: false)
    }
  }

  struct ScopeValue: Codable {
    let kind: String
    let key: String?
    var deviceKey: String?

    init(_ scope: DreamMemoryScope) {
      switch scope {
      case .global:
        kind = "global"
        key = nil
      case .project(let value):
        kind = "project"
        key = value
      case .device(let value):
        kind = "device"
        key = nil
        deviceKey = value
      case .deviceProject(let device, let project):
        kind = "deviceProject"
        key = project
        deviceKey = device
      }
    }

    func domain() throws -> DreamMemoryScope {
      if let deviceKey {
        let scope: DreamMemoryScope
        if kind == "device", key == nil {
          scope = .device(deviceKey)
        } else if kind == "deviceProject", let key {
          scope = .deviceProject(device: deviceKey, project: key)
        } else {
          throw DreamRunError.corruption
        }
        guard MemoryDocument.isAllowedPath(scope.path) else { throw DreamRunError.corruption }
        return scope
      }
      if kind == "global", key == nil { return .global }
      guard kind == "project", let key,
        MemoryDocument.isAllowedPath("projects/\(key).md")
      else { throw DreamRunError.corruption }
      return .project(key)
    }
  }

  struct MemoryAnchor: Codable {
    let scope: ScopeValue
    let documentHash: String
    let start: Int
    let end: Int
    let before: String
    let isEligible: Bool

    init(_ value: DreamMemoryAnchor) {
      scope = ScopeValue(value.scope)
      documentHash = value.documentHash.rawValue
      start = value.start
      end = value.end
      before = value.before
      isEligible = value.isEligible
    }
  }

  struct OwnerAnchor: Codable {
    let key: String
    let ownerHash: String
    let start: Int
    let end: Int
    let before: String

    init(_ value: DreamOwnerAnchor) {
      key = value.key
      ownerHash = value.ownerHash.rawValue
      start = value.start
      end = value.end
      before = value.before
    }
  }

  struct Plan: Codable {
    let base: String
    let path: String
    let replacement: Data
    let reason: String
    let contradictions: String
    let beforeDigest: String?
    let afterDigest: String
    let sources: [ID]
    let anchors: [MemoryAnchor]

    init(_ value: SingleFileProposalPlan) {
      base = value.base
      path = value.path
      replacement = value.replacement
      reason = value.reason
      contradictions = value.contradictions
      beforeDigest = value.beforeDigest?.rawValue
      afterDigest = value.afterDigest.rawValue
      sources = value.sources.map(ID.init)
      anchors = value.anchors.map(MemoryAnchor.init)
    }
  }

  struct Note: Codable {
    let kind: String
    let sources: [ID]
    let explanation: String
    let reasonCode: String?
    let owner: OwnerAnchor?
    let ownerReference: String?
    let contradictions: String

    init(_ value: DreamDecisionNote) {
      kind = value.kind
      sources = value.sources.map(ID.init)
      explanation = value.explanation
      reasonCode = value.reasonCode
      owner = value.owner.map(OwnerAnchor.init)
      ownerReference = value.ownerReference
      contradictions = value.contradictions
    }
  }

  struct Decisions: Codable {
    let schemaVersion: Int
    let admissionHash: String
    let responseHash: String?
    let contextHash: String
    let plans: [Plan]
    let notes: [Note]
    let exclusionInputHash: String?
  }

  struct Receipt: Codable {
    let schemaVersion: Int
    let admissionHash: String
    let decisionsHash: String
    let planHash: String
    let ref: String
    let commit: String
    let base: String
    let path: String
  }

  struct Completion: Codable {
    let schemaVersion: Int
    let admissionHash: String
    let decisionsHash: String
    let predecessorHash: String
    let predecessorGeneration: UInt64
    let nextGeneration: UInt64
    let progress: Progress
    let receiptHashes: [String]
    let notes: [Note]
    let tails: [Tail]
    let isBacklog: Bool
  }

  private struct ContextPayload: Decodable {
    let deviceKey: String?
    let projectBindings: [String: String]?
    let schemaVersion: Int
    let run: Data
    let inputHash: String
    let base: String
    let layoutHash: String
    let layoutEntryCount: Int
    let layoutByteCount: Int
    let layoutEntries: [Layout]
    let documents: [Document]
    let scopes: [Scope]
    let owners: [Owner]
    let date: String
    let limits: Limits
    let policyVersion: Int
    let policy: String
    let limitations: [String]

    struct Limits: Decodable {
      let maximumResponseBytes: Int
      let maximumFrozenBytes: Int
      let maximumLayoutEntries: Int
      let maximumLayoutBytes: Int
      let maximumSnapshotBytes: Int
      let maximumDocumentBytes: Int
      let maximumProjectKeys: Int
      let maximumOwners: Int
      let maximumOwnerBytes: Int
      let maximumSingleOwnerBytes: Int
      let maximumOwnerReferenceBytes: Int
      let maximumDecisions: Int
      let maximumSources: Int
      let maximumContradictions: Int
      let maximumReferences: Int
      let maximumTextBytes: Int
      let maximumBeforeBytes: Int
      let maximumPlans: Int
      let maximumReplacementBytes: Int
      let maximumOutputBytes: Int
      let maximumMetadataBytes: Int

      func domain() throws -> DreamDecisionLimits {
        try DreamDecisionLimits(
          maximumResponseBytes: maximumResponseBytes, maximumFrozenBytes: maximumFrozenBytes,
          maximumLayoutEntries: maximumLayoutEntries, maximumLayoutBytes: maximumLayoutBytes,
          maximumSnapshotBytes: maximumSnapshotBytes, maximumDocumentBytes: maximumDocumentBytes,
          maximumProjectKeys: maximumProjectKeys, maximumOwners: maximumOwners,
          maximumOwnerBytes: maximumOwnerBytes, maximumSingleOwnerBytes: maximumSingleOwnerBytes,
          maximumOwnerReferenceBytes: maximumOwnerReferenceBytes,
          maximumDecisions: maximumDecisions,
          maximumSources: maximumSources, maximumContradictions: maximumContradictions,
          maximumReferences: maximumReferences, maximumTextBytes: maximumTextBytes,
          maximumBeforeBytes: maximumBeforeBytes, maximumPlans: maximumPlans,
          maximumReplacementBytes: maximumReplacementBytes, maximumOutputBytes: maximumOutputBytes,
          maximumMetadataBytes: maximumMetadataBytes)
      }
    }

    struct Layout: Decodable {
      let path: String
      let mode: String
      let blob: String
    }

    struct Document: Decodable {
      let path: String
      let mode: String
      let blob: String
      let digest: String
      let bytes: String

      func domain() throws -> ApprovedDecisionDocument {
        if bytes == "absent" {
          guard mode == "absent", blob == "absent", digest == "absent" else {
            throw DreamRunError.corruption
          }
          return ApprovedDecisionDocument(
            path: path, mode: nil, blob: nil, digest: nil, bytes: nil, diagnostics: [])
        }
        guard let data = Data(base64Encoded: bytes) else { throw DreamRunError.corruption }
        return try ApprovedDecisionDocument(
          path: path, mode: mode, blob: blob, digest: SourceDigest(digest), bytes: data,
          diagnostics: MemoryDocument.failures(in: data))
      }
    }

    struct Scope: Decodable {
      let source: ID
      let cwd: String
      let isCwdPresent: Int
      let resolution: Resolution

      struct Resolution: Decodable {
        let kind: String
        let key: String?
        let isGlobalEligible: Int?

        func domain() throws -> PinnedScopeResolution {
          switch kind {
          case "project":
            guard let key, let isGlobalEligible, [0, 1].contains(isGlobalEligible) else {
              throw DreamRunError.corruption
            }
            return .project(key: key, isGlobalEligible: isGlobalEligible == 1)
          case "outsideGit":
            guard key == nil, let isGlobalEligible, [0, 1].contains(isGlobalEligible) else {
              throw DreamRunError.corruption
            }
            return .outsideGit(isGlobalEligible: isGlobalEligible == 1)
          case "unresolved":
            guard key == nil, isGlobalEligible == nil else { throw DreamRunError.corruption }
            return .unresolved
          default: throw DreamRunError.corruption
          }
        }
      }
    }

    struct Owner: Decodable {
      let key: String
      let reference: String
      let scope: ScopeValue
      let digest: String
      let bytes: Data

      func domain() throws -> PinnedOwnerInput {
        let value = try PinnedOwnerInput(
          key: key, reference: reference, scope: scope.domain(), bytes: bytes)
        guard value.digest.rawValue == digest else { throw DreamRunError.corruption }
        return value
      }
    }
  }

  static func context(bytes: Data, run: FrozenDreamRun) throws -> DreamDecisionContext {
    do {
      let payload = try JSONDecoder().decode(ContextPayload.self, from: bytes)
      guard payload.schemaVersion == 1, payload.inputHash == run.inputHash.rawValue,
        payload.policyVersion == 1, payload.policy == DreamDecisionContext.policy
      else { throw DreamRunError.corruption }
      let limits = try payload.limits.domain()
      let snapshot = try ApprovedDecisionSnapshot(
        base: payload.base,
        layoutEntries: payload.layoutEntries.map {
          ApprovedDecisionLayoutEntry(path: $0.path, mode: $0.mode, blob: $0.blob)
        }, documents: payload.documents.map { try $0.domain() }, limits: limits)
      guard snapshot.layoutHash.rawValue == payload.layoutHash,
        snapshot.layoutEntryCount == payload.layoutEntryCount,
        snapshot.layoutByteCount == payload.layoutByteCount
      else { throw DreamRunError.corruption }
      let scopes = try payload.scopes.map {
        guard [0, 1].contains($0.isCwdPresent), $0.isCwdPresent != 0 || $0.cwd.isEmpty else {
          throw DreamRunError.corruption
        }
        return try PinnedEvidenceScope(
          source: $0.source.domain(), projectScope: $0.isCwdPresent == 1 ? $0.cwd : nil,
          resolution: $0.resolution.domain())
      }
      let context = try DreamDecisionContext(
        run: run, snapshot: snapshot, scopes: scopes,
        owners: payload.owners.map { try $0.domain() }, addedDate: payload.date,
        limits: limits, limitations: payload.limitations, deviceKey: payload.deviceKey,
        projectBindings: payload.projectBindings ?? [:])
      guard context.canonicalBytes == bytes else { throw DreamRunError.corruption }
      return context
    } catch let error as DreamRunError { throw error } catch { throw DreamRunError.corruption }
  }
}
