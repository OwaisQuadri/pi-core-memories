import CryptoKit
import Darwin
import Foundation

public struct SourceRelativePath: Hashable, Sendable {
  public let rawValue: String

  init(_ value: String) throws {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      parts[1].hasSuffix(".jsonl"),
      !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      !value.contains("\\")
    else { throw MemoryError("unsafe session relative path") }
    rawValue = value
  }
}

public struct SessionIdentifier: Hashable, Sendable {
  public let rawValue: String

  init(_ value: String) throws {
    let bytes = Array(value.utf8)
    func isAlphanumeric(_ byte: UInt8) -> Bool {
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
    guard let first = bytes.first, let last = bytes.last,
      isAlphanumeric(first), isAlphanumeric(last),
      bytes.allSatisfy({ isAlphanumeric($0) || $0 == 45 || $0 == 95 || $0 == 46 })
    else { throw MemoryError("invalid session or entry identifier") }
    rawValue = value
  }
}

private struct EntryIdentifier: Hashable {
  let rawValue: String

  init(_ value: String) throws {
    guard !value.isEmpty,
      value.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || $0 == 45 || $0 == 95
      })
    else { throw MemoryError("invalid session or entry identifier") }
    rawValue = value
  }
}

public struct SourceDigest: Hashable, Sendable {
  public let rawValue: String

  init(_ value: String) throws {
    guard value.utf8.count == 64,
      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw MemoryError("invalid source digest") }
    rawValue = value
  }

  init(bytes: Data) {
    let digits = Array("0123456789abcdef".utf8)
    var encoded: [UInt8] = []
    encoded.reserveCapacity(64)
    for byte in SHA256.hash(data: bytes) {
      encoded.append(digits[Int(byte >> 4)])
      encoded.append(digits[Int(byte & 0x0f)])
    }
    rawValue = String(decoding: encoded, as: UTF8.self)
  }
}

public struct SourcePosition: Equatable, Sendable {
  public let relativePath: SourceRelativePath
  public let sessionID: SessionIdentifier
  public let completeBytes: UInt64
  public let prefixHash: SourceDigest
  public let classificationHash: SourceDigest
}

public struct DreamProgress: Equatable, Sendable {
  public let schemaVersion: Int
  public let generation: UInt64
  public let positions: [SourcePosition]

  public init(schemaVersion: Int = 1, generation: UInt64 = 0, positions: [SourcePosition] = [])
    throws
  {
    guard schemaVersion == SessionReader.preparationSchemaVersion,
      Set(positions.map(\.relativePath)).count == positions.count,
      Set(positions.map(\.sessionID)).count == positions.count
    else { throw MemoryError("unsupported or duplicate dream progress") }
    self.schemaVersion = schemaVersion
    self.generation = generation
    self.positions = positions
  }
}

public enum PrimaryTextKind: String, Sendable {
  case typed, typedSkillArguments, answered, toolCall, toolResult
}

public struct PrimaryTextID: Hashable, Sendable {
  public let citation: Citation
  public let part: Int
}

public struct RecordWitness: Equatable, Sendable {
  public let relativePath: SourceRelativePath
  public let byteRange: Range<UInt64>
  public let rawRecordHash: SourceDigest
}

public struct PrimaryTextEvidence: Sendable {
  public let id: PrimaryTextID
  public let kind: PrimaryTextKind
  public let timestamp: Date
  public let projectScope: String?
  public let exactText: String
  public let witness: RecordWitness
  public let agentContext: String?
  public var originalWitness: RecordWitness? = nil
}

public struct SelectionContext: Sendable {
  public let citation: Citation
  public let question: String
  public let agentWrittenSelectedLabels: [String]
}

public enum ExclusionReason: String, Sendable {
  case metadataV1, childV1, infrastructureV1, generatedV1, assistantV1, toolOutputV1
  case summaryV1, attachmentOnlyV1, skillOnlyV1, snippetOnlyV1, acknowledgementV1, emptyV1
  case selectionsOnlyV1, unansweredV1, unknownMarkupV1
  case protectedSourceV1
}

public enum RecordDisposition: Sendable {
  case primaryEvidence([PrimaryTextID])
  case excluded(ExclusionReason)
  case skipped
}

public struct ExactSourceRecord: Sendable {
  public let witness: RecordWitness
  public let bytes: Data?
  public let disposition: RecordDisposition
}

public struct DreamBacklog: Equatable, Sendable {
  public let backlogBytes: UInt64
  public let undreamtBytes: UInt64
  public let nextBytes: UInt64
}

public struct UnfinishedSessionTail: Sendable {
  public let relativePath: SourceRelativePath
  public let byteRange: Range<UInt64>
}

public struct PreparedSessionBatch: Sendable {
  public let predecessorGeneration: UInt64
  public let readerSchemaVersion: Int
  public let strippingInputHash: SourceDigest
  public let positionsAfter: [SourcePosition]
  public let exactSourceRecords: [ExactSourceRecord]
  public let evidence: [PrimaryTextEvidence]
  public let selections: [SelectionContext]
  public let unfinishedTails: [UnfinishedSessionTail]
  public let isBacklog: Bool
  let provenance: PreparationProvenance?

  init(
    predecessorGeneration: UInt64, readerSchemaVersion: Int, strippingInputHash: SourceDigest,
    positionsAfter: [SourcePosition], exactSourceRecords: [ExactSourceRecord],
    evidence: [PrimaryTextEvidence], selections: [SelectionContext],
    unfinishedTails: [UnfinishedSessionTail], isBacklog: Bool,
    provenance: PreparationProvenance? = nil
  ) {
    self.predecessorGeneration = predecessorGeneration
    self.readerSchemaVersion = readerSchemaVersion
    self.strippingInputHash = strippingInputHash
    self.positionsAfter = positionsAfter
    self.exactSourceRecords = exactSourceRecords
    self.evidence = evidence
    self.selections = selections
    self.unfinishedTails = unfinishedTails
    self.isBacklog = isBacklog
    self.provenance = provenance
  }

  public var dispositions: [RecordDisposition] { exactSourceRecords.map(\.disposition) }

  public var keptBytes: Int { SessionReader.keptBytes(evidence: evidence, selections: selections) }
}

public struct DreamInputLimits: Sendable {
  public let maximumRecordBytes: Int
  public let maximumEvidenceBytes: Int
  public let maximumBatchBytes: Int
  public let maximumBatchRecords: Int

  public init(
    maximumRecordBytes: Int = 1_048_576, maximumEvidenceBytes: Int = 262_144,
    maximumBatchBytes: Int = 262_144, maximumBatchRecords: Int = 1_000
  ) throws {
    guard maximumRecordBytes > 0, maximumEvidenceBytes > 0, maximumBatchBytes > 0,
      maximumBatchRecords > 0
    else { throw MemoryError("dream input limits must be positive") }
    self.maximumRecordBytes = maximumRecordBytes
    self.maximumEvidenceBytes = maximumEvidenceBytes
    self.maximumBatchBytes = maximumBatchBytes
    self.maximumBatchRecords = maximumBatchRecords
  }
}

extension SessionReader {
  public static let preparationSchemaVersion = 1
  public static let dreamWindow: TimeInterval = 7 * 86_400
  public static let dreamBacklogBytes: UInt64 = 4 * 1_048_576

  static func keptBytes(evidence: [PrimaryTextEvidence], selections: [SelectionContext]) -> Int {
    evidence.reduce(0) { $0 + $1.exactText.utf8.count + ($1.agentContext?.utf8.count ?? 0) }
      + selections.reduce(0) { total, selection in
        selection.agentWrittenSelectedLabels.reduce(total + selection.question.utf8.count) {
          $0 + $1.utf8.count
        }
      }
  }

  public func prepare(
    progress: DreamProgress, limits: DreamInputLimits,
    modifiedAfter: Date = Date().addingTimeInterval(-dreamWindow),
    maximumBacklogBytes: UInt64 = dreamBacklogBytes,
    isToolEvidenceIncluded: Bool = false, isSourceScrubbed: Bool = false,
    backlog: (DreamBacklog) -> Void = { _ in },
    isCancelled: () -> Bool = { false }
  ) throws -> PreparedSessionBatch {
    try prepare(
      progress: progress, limits: limits, modifiedAfter: modifiedAfter,
      maximumBacklogBytes: maximumBacklogBytes,
      isToolEvidenceIncluded: isToolEvidenceIncluded, isSourceScrubbed: isSourceScrubbed,
      beforeRead: { _ in }, backlog: backlog,
      isCancelled: isCancelled)
  }

  package func prepareProtected(
    progress: DreamProgress, limits: DreamInputLimits,
    protect: @escaping ([String]) throws -> Void,
    admit: @escaping ([String]) throws -> [String],
    priorViews: [DreamAdmittedView] = [],
    backlog: (DreamBacklog) -> Void = { _ in },
    isCancelled: () -> Bool = { false }
  ) throws -> PreparedSessionBatch {
    try prepare(
      progress: progress, limits: limits,
      modifiedAfter: Date().addingTimeInterval(-Self.dreamWindow),
      maximumBacklogBytes: Self.dreamBacklogBytes, protect: protect, admit: admit,
      priorViews: priorViews,
      beforeRead: { _ in }, backlog: backlog, isCancelled: isCancelled)
  }

  func prepare(
    progress: DreamProgress, limits: DreamInputLimits, modifiedAfter: Date = .distantPast,
    maximumBacklogBytes: UInt64 = .max,
    isToolEvidenceIncluded: Bool = false, isSourceScrubbed: Bool = false,
    protect: (([String]) throws -> Void)? = nil,
    admit: (([String]) throws -> [String])? = nil,
    priorViews: [DreamAdmittedView] = [],
    beforeRead: (URL) throws -> Void,
    backlog: (DreamBacklog) -> Void = { _ in },
    isCancelled: () -> Bool = { false }
  ) throws -> PreparedSessionBatch {
    guard !isToolEvidenceIncluded || isSourceScrubbed else {
      throw MemoryError("tool evidence requires caller-scrubbed source input")
    }
    func checkedRead(_ url: URL) throws {
      if isCancelled() { throw CancellationError() }
      try beforeRead(url)
    }
    let stripping = try preparationStrippingInputs(beforeRead: checkedRead, admit: admit)
    if let protect {
      try protect(
        try stripping.inputs.flatMap { [$0.name, try DreamSourceProtection.text($0.bytes)] })
    }
    var modified: [SourceRelativePath: Date] = [:]
    var tracked = Dictionary(uniqueKeysWithValues: progress.positions.map { ($0.relativePath, $0) })
    var captured: [CapturedSession] = []
    var views: [DreamAdmittedView] = []
    var originalData: [SourceRelativePath: Data] = [:]
    var identities: Set<SessionIdentifier> = []
    var discovered: Set<SourceRelativePath> = []
    var tails: [UnfinishedSessionTail] = []
    try forEachPreparationFolder { files in
      if isCancelled() { throw CancellationError() }
      for file in files {
        let date = try file.directory.status(file.name).modified
        if date > modifiedAfter { modified[file.path] = date }
      }
      for file in files {
        let path = file.path
        discovered.insert(path)
        guard modified[path] != nil else { continue }
        try checkedRead(file.directory.url.appendingPathComponent(file.name))
        let data = try file.directory.capture(file.name)
        let complete = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        if complete < data.count {
          tails.append(
            UnfinishedSessionTail(
              relativePath: path, byteRange: UInt64(complete)..<UInt64(data.count)))
        }
        if let saved = tracked[path] {
          guard saved.completeBytes <= UInt64(complete)
          else { throw MemoryError("session shrank: \(path.rawValue)") }
          let offset = Int(saved.completeBytes)
          guard offset > 0, data[offset - 1] == 0x0A,
            SourceDigest(bytes: Data(data[..<offset])) == saved.prefixHash
          else { throw MemoryError("session prefix changed: \(path.rawValue)") }
        }
        guard complete > 0 else { continue }
        var session = try CapturedSession(path: path, bytes: data, completeBytes: complete)
        if let admit {
          try protect?([path.rawValue])
          let prior = priorViews.first { $0.path == path.rawValue }
          let view = try session.admitting(prior: prior, admit: admit)
          views.append(view)
          originalData[path] = data
          session = try CapturedSession(
            path: path, bytes: view.bytes, completeBytes: view.bytes.count, admittedView: view)
        } else if let protect {
          try session.requireAdmissibleReadProvenance()
          try protect(
            [path.rawValue] + (try session.records.map { try DreamSourceProtection.text($0.bytes) })
          )
        }
        guard identities.insert(session.id).inserted else {
          throw MemoryError("duplicate session identity: \(session.id.rawValue)")
        }
        if let saved = tracked[path] {
          guard saved.sessionID == session.id else {
            throw MemoryError("session identity changed: \(path.rawValue)")
          }
          guard saved.classificationHash == session.classificationHash else {
            throw MemoryError("session classification changed: \(path.rawValue)")
          }
        }
        captured.append(session)
      }
    }
    for saved in progress.positions where modified[saved.relativePath] == nil {
      guard identities.insert(saved.sessionID).inserted else {
        throw MemoryError("duplicate session identity: \(saved.sessionID.rawValue)")
      }
    }
    guard Set(tracked.keys).isSubset(of: discovered) else {
      throw MemoryError("missing tracked session file")
    }
    tracked = try Dictionary(
      uniqueKeysWithValues: tracked.map { path, position in
        (path, try views.first(where: { $0.path == path.rawValue })?.project(position) ?? position)
      })
    let isIncludingTools = isToolEvidenceIncluded || protect != nil
    captured.sort {
      modified[$0.path]! != modified[$1.path]!
        ? modified[$0.path]! > modified[$1.path]! : $0.path.rawValue < $1.path.rawValue
    }
    var positions = tracked
    var records: [ExactSourceRecord] = []
    var evidence: [PrimaryTextEvidence] = []
    var selections: [SelectionContext] = []
    var batchBytes = 0
    var storedRecords = 0
    var isBacklog = false
    var isBatchFull = false
    var backlogBytes: UInt64 = 0
    var undreamtBytes: UInt64 = 0
    var nextBytes: UInt64 = 0
    var nextRecords = 0
    var isNextFull = false
    for session in captured where undreamtBytes < maximumBacklogBytes {
      let savedOffset = tracked[session.path]?.completeBytes ?? 0
      var nextOffset = savedOffset
      var chain: [String: PreparedChainLink] = [:]
      var span: Range<UInt64>?
      func closeSpan() {
        guard let range = span else { return }
        records.append(
          ExactSourceRecord(
            witness: RecordWitness(
              relativePath: session.path, byteRange: range,
              rawRecordHash: SourceDigest(
                bytes: Data(session.bytes[Int(range.lowerBound)..<Int(range.upperBound)]))),
            bytes: nil, disposition: .skipped))
        span = nil
      }
      for record in session.records {
        if isCancelled() { throw CancellationError() }
        let parent = record.object["parentId"] as? String
        let extracted = try record.extract(
          session: session, snippets: stripping.snippets, templates: stripping.templates,
          isToolEvidenceIncluded: isIncludingTools,
          agentContext: { PreparedChainLink.context(parent: parent, chain: chain) })
        if let id = record.object["id"] as? String {
          chain[id] = PreparedChainLink(parent: parent, text: extracted.agentText)
        }
        let kept = Self.keptBytes(evidence: extracted.evidence, selections: extracted.selections)
        backlogBytes += UInt64(kept)
        guard record.range.upperBound > savedOffset else { continue }
        undreamtBytes += UInt64(kept)
        let isStored =
          !extracted.evidence.isEmpty || !extracted.selections.isEmpty
          || record.range.lowerBound == 0
        if !isBatchFull, isStored,
          storedRecords >= limits.maximumBatchRecords
            || (batchBytes > 0 && kept > limits.maximumBatchBytes - batchBytes)
        {
          isBatchFull = true
        }
        if isBatchFull {
          isBacklog = true
          if !isNextFull {
            let budget = UInt64(limits.maximumBatchBytes)
            let isFitting =
              nextBytes == 0 || (nextBytes <= budget && UInt64(kept) <= budget - nextBytes)
            if isFitting && (!isStored || nextRecords < limits.maximumBatchRecords) {
              nextBytes += UInt64(kept)
              if isStored { nextRecords += 1 }
            } else {
              isNextFull = true
            }
          }
          continue
        }
        if isStored {
          guard
            extracted.evidence.allSatisfy({
              $0.exactText.utf8.count <= limits.maximumEvidenceBytes
                && ($0.agentContext?.utf8.count ?? 0) <= limits.maximumEvidenceBytes
            })
          else { throw MemoryError("oversized dream evidence: \(session.path.rawValue)") }
          guard
            !extracted.evidence.contains(where: { $0.kind == .toolCall || $0.kind == .toolResult })
              || kept <= limits.maximumBatchBytes
          else { throw MemoryError("oversized dream tool record: \(session.path.rawValue)") }
          guard record.bytes.count <= limits.maximumRecordBytes else {
            throw MemoryError("oversized dream record: \(session.path.rawValue)")
          }
          closeSpan()
          records.append(
            ExactSourceRecord(
              witness: extracted.evidence.first?.witness ?? record.witness(path: session.path),
              bytes: record.bytes, disposition: extracted.disposition))
          evidence += extracted.evidence
          selections += extracted.selections
          batchBytes += kept
          storedRecords += 1
        } else {
          span = (span?.lowerBound ?? record.range.lowerBound)..<record.range.upperBound
        }
        nextOffset = record.range.upperBound
      }
      closeSpan()
      if nextOffset > 0 {
        positions[session.path] = SourcePosition(
          relativePath: session.path, sessionID: session.id, completeBytes: nextOffset,
          prefixHash: SourceDigest(bytes: Data(session.bytes.prefix(Int(nextOffset)))),
          classificationHash: session.classificationHash)
      }
    }
    backlog(
      DreamBacklog(backlogBytes: backlogBytes, undreamtBytes: undreamtBytes, nextBytes: nextBytes))
    return PreparedSessionBatch(
      predecessorGeneration: progress.generation,
      readerSchemaVersion: Self.preparationSchemaVersion,
      strippingInputHash: stripping.hash,
      positionsAfter: try positions.values.map { position in
        guard let view = views.first(where: { $0.path == position.relativePath.rawValue }),
          let data = originalData[position.relativePath]
        else { return position }
        let offset = try view.originalOffset(admitted: position.completeBytes)
        return SourcePosition(
          relativePath: position.relativePath, sessionID: position.sessionID,
          completeBytes: offset, prefixHash: SourceDigest(bytes: data.prefix(Int(offset))),
          classificationHash: position.classificationHash)
      }.sorted { $0.relativePath.rawValue < $1.relativePath.rawValue },
      exactSourceRecords: records, evidence: evidence, selections: selections,
      unfinishedTails: tails, isBacklog: isBacklog,
      provenance: PreparationProvenance(
        isToolEvidenceIncluded: isIncludingTools, admittedViews: views, stripping: stripping.inputs,
        sessions: captured.filter { session in
          records.contains { $0.witness.relativePath == session.path }
        }.map { session in
          PreparationClassificationWitness(
            path: session.path,
            records: session.records.filter {
              ["session", "session_info"].contains($0.object["type"] as? String ?? "")
            }.map {
              PreparationClassificationRecord(
                witness: $0.witness(path: session.path), bytes: $0.bytes)
            })
        }))
  }

  private func preparationStrippingInputs(
    beforeRead: (URL) throws -> Void, admit: (([String]) throws -> [String])? = nil
  ) throws -> (
    snippets: [String], templates: [String], hash: SourceDigest,
    inputs: [PreparationStrippingInput]
  ) {
    var binding = Data()
    var inputs: [PreparationStrippingInput] = []
    func load(_ folder: URL?, kind: String) throws -> [String] {
      binding.append(Data(kind.utf8))
      binding.append(0)
      guard let folder else { return [] }
      let directory = try PreparationDirectory(url: folder)
      var bodies: [String] = []
      for name in try directory.names() where name.lowercased().hasSuffix(".md") {
        try beforeRead(folder.appendingPathComponent(name))
        guard !DreamSourceProtection.isProtectedPath(folder.appendingPathComponent(name).path)
        else {
          throw DreamSourceProtectionError.blocked
        }
        var bytes = try directory.capture(name, isFollowingLinks: true)
        let originalHash = admit == nil ? nil : SourceDigest(bytes: bytes)
        if let admit { bytes = Data(try admit([DreamSourceProtection.text(bytes)])[0].utf8) }
        guard let raw = String(data: bytes, encoding: .utf8) else {
          throw MemoryError("invalid stripping input UTF-8")
        }
        binding.append(Data("\(name.utf8.count):\(name)\(bytes.count):".utf8))
        binding.append(bytes)
        inputs.append(
          PreparationStrippingInput(
            kind: kind, name: name, bytes: bytes, originalHash: originalHash))
        let body = kind == "snippets" ? Self.snippetBody(raw) : Self.templateBody(raw)
        if let body { bodies.append(body) }
      }
      guard !bodies.isEmpty else { throw MemoryError("no usable stripping inputs") }
      return bodies
    }
    let snippets = try load(snippetFolder, kind: "snippets")
    let templates = try load(promptFolder, kind: "templates")
    return (snippets, templates, SourceDigest(bytes: binding), inputs)
  }
}

struct PreparationSessionFile {
  let path: SourceRelativePath
  let directory: PreparationDirectory
  let name: String
}

struct PreparationDirectoryIdentity: Equatable {
  let device: dev_t
  let inode: ino_t

  init(_ status: stat) {
    device = status.st_dev
    inode = status.st_ino
  }
}

final class PreparationDirectory {
  let url: URL
  let identity: PreparationDirectoryIdentity
  private let descriptor: Int32
  private let parent: PreparationDirectory?

  init(url: URL, parent: PreparationDirectory? = nil) throws {
    let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    let descriptor =
      parent.map { openat($0.descriptor, url.lastPathComponent, flags) }
      ?? open(url.path, flags)
    guard descriptor >= 0 else { throw MemoryError("cannot open preparation directory") }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
      close(descriptor)
      throw MemoryError("unsafe preparation directory")
    }
    self.url = url
    identity = PreparationDirectoryIdentity(status)
    self.descriptor = descriptor
    self.parent = parent
  }

  deinit { close(descriptor) }

  func names(maximum: Int = Int.max) throws -> [String] {
    let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard copy >= 0 else { throw MemoryError("cannot copy preparation directory descriptor") }
    guard let directory = fdopendir(copy) else {
      close(copy)
      throw MemoryError("cannot list preparation directory")
    }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else { throw MemoryError("cannot read preparation directory") }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
      }
      if name != ".", name != ".." { names.append(name) }
      guard names.count <= maximum else { throw DreamRunError.limitExceeded }
    }
    return names.sorted()
  }

  func entry(_ name: String) throws -> (kind: mode_t, identity: PreparationDirectoryIdentity) {
    var status = stat()
    guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw MemoryError("cannot inspect preparation directory entry")
    }
    return (status.st_mode & S_IFMT, PreparationDirectoryIdentity(status))
  }

  func status(_ name: String) throws -> (modified: Date, size: UInt64) {
    var status = stat()
    guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0, status.st_size >= 0 else {
      throw MemoryError("cannot inspect session file: \(name)")
    }
    let modified = Date(
      timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
        + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000)
    return (modified, UInt64(status.st_size))
  }

  func verifyPromptRoot() throws {
    var held = stat()
    var named = stat()
    guard fstat(descriptor, &held) == 0, lstat(url.path, &named) == 0,
      PreparationDirectoryIdentity(held) == identity,
      PreparationDirectoryIdentity(named) == identity,
      named.st_mode & S_IFMT == S_IFDIR,
      [geteuid(), 0].contains(held.st_uid), held.st_mode & 0o022 == 0
    else { throw MemoryError("unsafe replacement prompt directory") }
  }

  func checkedTemplates(maximumBytes: Int) throws -> [PreparationStrippingInput] {
    var held = stat()
    var named = stat()
    guard fstat(descriptor, &held) == 0, lstat(url.path, &named) == 0,
      PreparationDirectoryIdentity(held) == identity,
      PreparationDirectoryIdentity(named) == identity,
      named.st_mode & S_IFMT == S_IFDIR,
      [geteuid(), 0].contains(held.st_uid), held.st_mode & 0o022 == 0
    else { throw MemoryError("unsafe replacement prompt directory") }
    let beforeDirectory = held
    let names = try names(maximum: 10_000)
    var total = 0
    var inputs: [PreparationStrippingInput] = []
    var statuses: [String: stat] = [:]
    for name in names where name.lowercased().hasSuffix(".md") {
      var before = stat()
      guard fstatat(descriptor, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
        before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
        [geteuid(), 0].contains(before.st_uid), before.st_mode & 0o022 == 0,
        before.st_size >= 0, UInt64(before.st_size) <= UInt64(maximumBytes - total)
      else { throw MemoryError("unsafe or oversized replacement prompt entry") }
      let bytes = try capture(name, maximumBytes: maximumBytes - total, isCheckingStability: true)
      guard bytes.count == before.st_size,
        let text = String(data: bytes, encoding: .utf8), !text.contains("\0"),
        SessionReader.templateBody(text) != nil
      else { throw MemoryError("unusable replacement prompt entry") }
      total += bytes.count
      statuses[name] = before
      inputs.append(PreparationStrippingInput(kind: "templates", name: name, bytes: bytes))
    }
    for (name, before) in statuses {
      var after = stat()
      guard fstatat(descriptor, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
        Self.isSameCapture(before, after)
      else { throw MemoryError("replacement prompts changed during capture") }
    }
    guard try self.names(maximum: 10_000) == names,
      fstat(descriptor, &held) == 0, lstat(url.path, &named) == 0,
      Self.isSameCapture(beforeDirectory, held), Self.isSameCapture(held, named)
    else { throw MemoryError("replacement prompts changed during capture") }
    return inputs
  }

  private static func isSameCapture(_ before: stat, _ after: stat) -> Bool {
    PreparationDirectoryIdentity(before) == PreparationDirectoryIdentity(after)
      && before.st_mode == after.st_mode && before.st_uid == after.st_uid
      && before.st_nlink == after.st_nlink && before.st_size == after.st_size
      && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
      && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
      && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
      && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
  }

  func capture(
    _ name: String, isFollowingLinks: Bool = false, maximumBytes: Int = Int.max,
    isCheckingStability: Bool = false
  ) throws -> Data {
    let flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | (isFollowingLinks ? 0 : O_NOFOLLOW)
    let file = openat(descriptor, name, flags)
    guard file >= 0 else { throw MemoryError("cannot open session file: \(name)") }
    let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
    defer { try? handle.close() }
    var status = stat()
    guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_size >= 0, UInt64(status.st_size) <= UInt64(maximumBytes)
    else { throw MemoryError("unsafe session file") }
    let ceiling = Int(status.st_size)
    var data = Data()
    while data.count < ceiling {
      guard let chunk = try handle.read(upToCount: min(65_536, ceiling - data.count)),
        !chunk.isEmpty
      else { throw MemoryError("session shrank during capture") }
      data.append(chunk)
    }
    if isCheckingStability {
      var after = stat()
      guard fstat(file, &after) == 0, Self.isSameCapture(status, after) else {
        throw MemoryError("source changed during capture")
      }
    }
    return data
  }
}

private struct PreparedChainLink {
  let parent: String?
  let text: String?

  static func context(parent: String?, chain: [String: Self]) -> String? {
    var next = parent
    var visited: Set<String> = []
    while let id = next, visited.insert(id).inserted, let link = chain[id] {
      if let text = link.text { return text }
      next = link.parent
    }
    return nil
  }
}

private struct CapturedSession {
  let path: SourceRelativePath
  let id: SessionIdentifier
  let bytes: Data
  let records: [PreparedRecord]
  let sessionClass: SessionClass
  let classificationHash: SourceDigest
  let projectScope: String
  let admittedView: DreamAdmittedView?

  func requireAdmissibleReadProvenance() throws {
    try DreamSourceProtection.requireAdmissibleReadProvenance(records.map(\.object))
  }

  init(
    path: SourceRelativePath, bytes: Data, completeBytes: Int,
    admittedView: DreamAdmittedView? = nil
  ) throws {
    var records: [PreparedRecord] = []
    var start = 0
    var ids: Set<String> = []
    for end in bytes[..<completeBytes].indices where bytes[end] == 0x0A {
      let record = try PreparedRecord(bytes: Data(bytes[start...end]), start: start)
      if let value = record.object["id"] as? String {
        guard ids.insert(value).inserted else {
          throw MemoryError("duplicate entry identifier: \(path.rawValue)")
        }
      }
      records.append(record)
      start = end + 1
    }
    guard let first = records.first, first.object["type"] as? String == "session",
      let rawID = first.object["id"] as? String,
      let cwd = first.object["cwd"] as? String, !cwd.isEmpty,
      let time = first.object["timestamp"] as? String, let timestamp = SessionReader.date(time)
    else { throw MemoryError("invalid session header: \(path.rawValue)") }
    let id = try SessionIdentifier(rawID)
    let parent = first.object["parentSession"]
    guard parent == nil || parent is NSNull || parent is String else {
      throw MemoryError("invalid parent session")
    }
    let parentPath = parent as? String
    var sessionClass = parentPath == nil ? SessionClass.primary : .child
    var names: [String] = []
    for record in records.dropFirst() {
      guard record.object["type"] as? String != "session" else {
        throw MemoryError("repeated session header")
      }
      if record.object["type"] as? String == "session_info" {
        let value = record.object["name"]
        guard value == nil || value is String else {
          throw MemoryError("invalid session classification metadata")
        }
        let name = value as? String
        names.append(name ?? "")
        let header = SessionHeader(
          id: rawID, cwd: cwd, timestamp: timestamp, parentSession: parentPath, name: name)
        let label = SessionReader.classify(header).0
        if label == .infrastructure {
          sessionClass = .infrastructure
        } else if label == .child, sessionClass != .infrastructure {
          sessionClass = .child
        }
      }
    }
    let classification = try JSONSerialization.data(
      withJSONObject: ["class": sessionClass.rawValue, "parent": parentPath ?? "", "names": names],
      options: [.sortedKeys])
    self.path = path
    self.admittedView = admittedView
    self.id = id
    self.bytes = bytes
    self.records = records
    self.sessionClass = sessionClass
    self.classificationHash = SourceDigest(bytes: classification)
    self.projectScope = cwd
  }
}

private struct PreparedRecord {
  let bytes: Data
  let range: Range<UInt64>
  let object: [String: Any]

  init(bytes: Data, start: Int) throws {
    guard String(data: bytes, encoding: .utf8) != nil,
      let object = try SessionReader.decodeRecord(bytes) as? [String: Any],
      let type = object["type"] as? String, !type.isEmpty,
      let id = object["id"] as? String,
      let time = object["timestamp"] as? String, SessionReader.date(time) != nil
    else { throw MemoryError("malformed complete session record") }
    if type == "session" {
      _ = try SessionIdentifier(id)
    } else {
      _ = try EntryIdentifier(id)
    }
    if let parent = object["parentId"], !(parent is NSNull) {
      guard let value = parent as? String else {
        throw MemoryError("invalid parent entry identifier")
      }
      _ = try EntryIdentifier(value)
    }
    self.bytes = bytes
    self.range = UInt64(start)..<UInt64(start + bytes.count)
    self.object = object
  }

  func witness(path: SourceRelativePath) -> RecordWitness {
    RecordWitness(relativePath: path, byteRange: range, rawRecordHash: SourceDigest(bytes: bytes))
  }

  func extract(
    session: CapturedSession, snippets: [String], templates: [String],
    isToolEvidenceIncluded: Bool, agentContext: () -> String?
  ) throws -> (
    disposition: RecordDisposition, evidence: [PrimaryTextEvidence],
    selections: [SelectionContext], agentText: String?
  ) {
    func excluded(_ reason: ExclusionReason, agentText: String? = nil) -> (
      RecordDisposition, [PrimaryTextEvidence], [SelectionContext], String?
    ) {
      (.excluded(reason), [], [], agentText)
    }
    if session.admittedView?.records.first(where: { $0.admittedStart == range.lowerBound })?
      .isOmitted == true
    {
      return excluded(.protectedSourceV1)
    }
    let type = object["type"] as? String ?? ""
    switch type {
    case "session", "session_info", "model_change", "thinking_level_change", "label", "usage":
      return excluded(.metadataV1)
    case "custom", "custom_message", "context_edit": return excluded(.generatedV1)
    case "compaction", "branch_summary": return excluded(.summaryV1)
    case "message": break
    default: throw MemoryError("unknown session record type: \(type)")
    }
    guard let message = object["message"] as? [String: Any],
      let role = message["role"] as? String
    else { throw MemoryError("unknown message payload") }
    switch role {
    case "custom", "system": return excluded(.generatedV1)
    case "compactionSummary", "branchSummary": return excluded(.summaryV1)
    case "bashExecution": return excluded(.toolOutputV1)
    case "user", "assistant", "toolResult": break
    default: throw MemoryError("unknown message role")
    }
    if role == "assistant", !isToolEvidenceIncluded || session.sessionClass != .primary {
      return excluded(.assistantV1, agentText: try textContent(message["content"], isHuman: false))
    }
    if session.sessionClass == .child { return excluded(.childV1) }
    if session.sessionClass == .infrastructure { return excluded(.infrastructureV1) }
    if role == "toolResult", !isToolEvidenceIncluded,
      message["toolName"] as? String != "ask_user_question"
    {
      return excluded(.toolOutputV1)
    }
    guard let time = object["timestamp"] as? String, let timestamp = SessionReader.date(time) else {
      throw MemoryError("invalid primary record timestamp")
    }
    let citation = Citation(session: session.id.rawValue, entry: object["id"] as? String ?? "")
    var recordWitness: RecordWitness?
    var context: String?
    func evidence(_ text: String, kind: PrimaryTextKind, part: Int) -> PrimaryTextEvidence {
      let source = recordWitness ?? witness(path: session.path)
      if recordWitness == nil { context = agentContext() }
      recordWitness = source
      var value = PrimaryTextEvidence(
        id: PrimaryTextID(citation: citation, part: part), kind: kind, timestamp: timestamp,
        projectScope: session.projectScope, exactText: text, witness: source,
        agentContext: context)
      if let relation = session.admittedView?.records.first(where: {
        $0.admittedStart == range.lowerBound && $0.admittedEnd == range.upperBound
      }) {
        value.originalWitness = RecordWitness(
          relativePath: session.path, byteRange: relation.originalStart..<relation.originalEnd,
          rawRecordHash: try! SourceDigest(relation.originalHash))
      }
      return value
    }
    func toolText(_ fields: [String: Any]) throws -> String {
      String(
        decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
        as: UTF8.self)
    }
    if role == "assistant" {
      guard let blocks = message["content"] as? [[String: Any]] else {
        return excluded(
          .assistantV1, agentText: try textContent(message["content"], isHuman: false))
      }
      var units: [PrimaryTextEvidence] = []
      for (part, block) in blocks.enumerated() where block["type"] as? String == "toolCall" {
        guard let id = block["id"] as? String, !id.isEmpty,
          let name = block["name"] as? String, !name.isEmpty,
          let arguments = block["arguments"] as? [String: Any]
        else { throw MemoryError("invalid primary tool call") }
        units.append(
          evidence(
            try toolText([
              "toolCallID": id, "toolName": name, "arguments": arguments,
            ]), kind: .toolCall, part: part))
      }
      let agentText = try textContent(message["content"], isHuman: false)
      return units.isEmpty
        ? excluded(.assistantV1, agentText: agentText)
        : (.primaryEvidence(units.map(\.id)), units, [], agentText)
    }
    if role == "toolResult", message["toolName"] as? String != "ask_user_question" {
      guard let id = message["toolCallId"] as? String, !id.isEmpty,
        let name = message["toolName"] as? String, !name.isEmpty,
        let isError = message["isError"] as? Bool
      else { throw MemoryError("invalid primary tool result") }
      let text = try textContent(message["content"], isHuman: false)
      guard !text.isEmpty else { return excluded(.attachmentOnlyV1) }
      let unit = evidence(
        try toolText([
          "toolCallID": id, "toolName": name, "text": text, "isError": isError,
        ]), kind: .toolResult, part: 0)
      return (.primaryEvidence([unit.id]), [unit], [], nil)
    }
    if role == "user" {
      let raw = try textContent(message["content"], isHuman: true)
      switch SessionReader.humanText(
        raw, snippets: snippets, templates: templates, isClipped: false)
      {
      case .human(let text, let kind):
        let unit = evidence(
          text, kind: kind == .typedSkillArguments ? .typedSkillArguments : .typed, part: 0)
        return (.primaryEvidence([unit.id]), [unit], [], nil)
      case .unknownMarkup: return excluded(.unknownMarkupV1)
      case .skillOnly: return excluded(.skillOnlyV1)
      case .snippetOnly: return excluded(.snippetOnlyV1)
      case .acknowledgement: return excluded(.acknowledgementV1)
      case .empty: return excluded(raw.isEmpty ? .emptyV1 : .attachmentOnlyV1)
      }
    }
    if let details = message["details"] as? [String: Any],
      let status = details["status"] as? String,
      ["policy-guidance", "automatic-policy-guidance"].contains(status)
    {
      return excluded(.generatedV1)
    }
    guard let details = message["details"] as? [String: Any],
      let status = details["status"] as? String,
      ["answered", "cancelled", "invalid", "unavailable"].contains(status)
    else { throw MemoryError("unknown answer payload") }
    guard status == "answered" else { return excluded(.unansweredV1) }
    let legacyAnswers = (details["answer"] as? String).map { [["type": "text", "label": $0]] }
    guard let answers = details["answers"] as? [[String: Any]] ?? legacyAnswers,
      let question = details["question"] as? String,
      answers.allSatisfy({
        ["text", "other", "option"].contains($0["type"] as? String ?? "")
          && $0["label"] is String
      })
    else { throw MemoryError("unknown potentially human answer") }
    let parts = SessionReader.answerParts(answers)
    let units = parts.enumerated().compactMap { index, answer in
      answer.type == "option" ? nil : evidence(answer.label, kind: .answered, part: index)
    }
    let labels = parts.filter { $0.type == "option" }.map(\.label)
    let selections =
      labels.isEmpty && units.isEmpty
      ? []
      : [
        SelectionContext(citation: citation, question: question, agentWrittenSelectedLabels: labels)
      ]
    let disposition: RecordDisposition =
      units.isEmpty
      ? .excluded(labels.isEmpty ? .emptyV1 : .selectionsOnlyV1)
      : .primaryEvidence(units.map(\.id))
    return (disposition, units, selections, nil)
  }

  private func textContent(_ content: Any?, isHuman: Bool) throws -> String {
    if let text = content as? String { return text }
    guard let blocks = content as? [[String: Any]] else {
      throw MemoryError("unknown message content")
    }
    var texts: [String] = []
    for block in blocks {
      switch block["type"] as? String {
      case "text":
        guard let text = block["text"] as? String else { throw MemoryError("invalid text block") }
        texts.append(text)
      case "image": break
      case "thinking" where !isHuman,
        "toolCall" where !isHuman:
        break
      default: throw MemoryError("unknown potentially human content block")
      }
    }
    return texts.joined(separator: "\n")
  }
}

struct PreparationStrippingInput: Sendable {
  let kind: String
  let name: String
  let bytes: Data
  var originalHash: SourceDigest? = nil
}

struct PreparationClassificationRecord: Sendable {
  let witness: RecordWitness
  let bytes: Data
}

struct PreparationClassificationWitness: Sendable {
  let path: SourceRelativePath
  let records: [PreparationClassificationRecord]
}

struct PreparationProvenance: Sendable {
  var isToolEvidenceIncluded: Bool = false
  var admittedViews: [DreamAdmittedView] = []
  let stripping: [PreparationStrippingInput]
  let sessions: [PreparationClassificationWitness]
}

extension SessionReader {
  static func verifyPreparation(_ supplied: PreparedSessionBatch, isProjected: Bool = false) throws
  {
    let batch = try isProjected ? supplied : supplied.admittedProjection()
    guard let provenance = batch.provenance else {
      throw MemoryError("missing preparation provenance")
    }
    var strippingBytes = Data()
    var snippets: [String] = []
    var templates: [String] = []
    guard provenance.stripping.allSatisfy({ ["snippets", "templates"].contains($0.kind) }) else {
      throw MemoryError("invalid stripping provenance kind")
    }
    for kind in ["snippets", "templates"] {
      strippingBytes.append(Data(kind.utf8))
      strippingBytes.append(0)
      let inputs = provenance.stripping.filter { $0.kind == kind }
      guard inputs.map(\.name) == inputs.map(\.name).sorted(),
        Set(inputs.map(\.name)).count == inputs.count
      else { throw MemoryError("stripping provenance ordering") }
      for input in inputs {
        guard !input.name.isEmpty, !input.name.contains("/"),
          input.name.lowercased().hasSuffix(".md"),
          let text = String(data: input.bytes, encoding: .utf8)
        else { throw MemoryError("stripping provenance bytes") }
        strippingBytes.append(
          Data("\(input.name.utf8.count):\(input.name)\(input.bytes.count):".utf8))
        strippingBytes.append(input.bytes)
        if let body = kind == "snippets" ? snippetBody(text) : templateBody(text) {
          if kind == "snippets" { snippets.append(body) } else { templates.append(body) }
        }
      }
      guard inputs.isEmpty || !(kind == "snippets" ? snippets : templates).isEmpty else {
        throw MemoryError("unusable stripping provenance")
      }
    }
    guard SourceDigest(bytes: strippingBytes) == batch.strippingInputHash,
      Set(provenance.sessions.map(\.path))
        == Set(batch.exactSourceRecords.map { $0.witness.relativePath }),
      Set(provenance.sessions.map(\.path)).count == provenance.sessions.count
    else {
      throw MemoryError("preparation provenance coverage")
    }
    var captured: [SourceRelativePath: CapturedSession] = [:]
    for witness in provenance.sessions {
      guard !witness.records.isEmpty else { throw MemoryError("missing classification header") }
      var previousEnd: UInt64 = 0
      var bytes = Data()
      for (index, record) in witness.records.enumerated() {
        guard record.witness.relativePath == witness.path,
          record.witness.rawRecordHash == SourceDigest(bytes: record.bytes),
          record.witness.byteRange.lowerBound >= previousEnd,
          record.witness.byteRange.upperBound - record.witness.byteRange.lowerBound
            == UInt64(record.bytes.count),
          record.bytes.last == 10, !record.bytes.dropLast().contains(10),
          let object = try SessionReader.decodeRecord(record.bytes) as? [String: Any],
          object["type"] as? String == (index == 0 ? "session" : "session_info"),
          index != 0 || record.witness.byteRange.lowerBound == 0
        else {
          throw MemoryError("classification witness")
        }
        previousEnd = record.witness.byteRange.upperBound
        bytes.append(record.bytes)
      }
      let session = try CapturedSession(
        path: witness.path, bytes: bytes, completeBytes: bytes.count,
        admittedView: provenance.admittedViews.first { $0.path == witness.path.rawValue })
      guard let position = batch.positionsAfter.first(where: { $0.relativePath == witness.path }),
        position.sessionID == session.id, position.classificationHash == session.classificationHash
      else {
        throw MemoryError("classification binding")
      }
      captured[witness.path] = session
    }
    var evidence: [PrimaryTextEvidence] = []
    var selections: [SelectionContext] = []
    for record in batch.exactSourceRecords {
      guard let bytes = record.bytes else {
        guard case .skipped = record.disposition, captured[record.witness.relativePath] != nil
        else { throw MemoryError("record provenance") }
        continue
      }
      guard let session = captured[record.witness.relativePath],
        bytes.count <= Int.max,
        record.witness.byteRange.lowerBound <= UInt64(Int.max - bytes.count),
        record.witness.byteRange.upperBound - record.witness.byteRange.lowerBound
          == UInt64(bytes.count)
      else { throw MemoryError("record provenance") }
      let raw = try PreparedRecord(bytes: bytes, start: Int(record.witness.byteRange.lowerBound))
      if ["session", "session_info"].contains(raw.object["type"] as? String ?? "") {
        guard
          provenance.sessions.first(where: { $0.path == record.witness.relativePath })?
            .records.contains(where: { $0.witness == record.witness && $0.bytes == bytes })
            == true
        else { throw MemoryError("selected classification record differs from witness") }
      }
      let extracted = try raw.extract(
        session: session, snippets: snippets, templates: templates,
        isToolEvidenceIncluded: provenance.isToolEvidenceIncluded,
        agentContext: {
          batch.evidence.first { $0.witness == record.witness }?.agentContext
        })
      switch (record.disposition, extracted.disposition) {
      case (.excluded(let supplied), .excluded(let derived)):
        guard supplied == derived else { throw MemoryError("forged exclusion disposition") }
      case (.primaryEvidence(let supplied), .primaryEvidence(let derived)):
        guard supplied == derived else { throw MemoryError("forged primary disposition") }
      default: throw MemoryError("concealed primary evidence")
      }
      evidence += extracted.evidence
      selections += extracted.selections
    }
    guard evidence.count == batch.evidence.count, selections.count == batch.selections.count else {
      throw MemoryError("derived catalogue coverage")
    }
    for (derived, supplied) in zip(evidence, batch.evidence) {
      guard derived.id == supplied.id, derived.kind == supplied.kind,
        derived.timestamp.timeIntervalSinceReferenceDate.bitPattern
          == supplied.timestamp.timeIntervalSinceReferenceDate.bitPattern,
        derived.projectScope.map({ Data($0.utf8) }) == supplied.projectScope.map({ Data($0.utf8) }),
        Data(derived.exactText.utf8) == Data(supplied.exactText.utf8),
        derived.witness == supplied.witness, derived.originalWitness == supplied.originalWitness,
        derived.agentContext.map({ Data($0.utf8) }) == supplied.agentContext.map({ Data($0.utf8) })
      else {
        throw MemoryError("derived primary catalogue")
      }
    }
    for (derived, supplied) in zip(selections, batch.selections) {
      guard derived.citation == supplied.citation,
        Data(derived.question.utf8) == Data(supplied.question.utf8),
        derived.agentWrittenSelectedLabels.map({ Data($0.utf8) })
          == supplied.agentWrittenSelectedLabels.map({ Data($0.utf8) })
      else {
        throw MemoryError("derived selection catalogue")
      }
    }
  }
}

extension CapturedSession {
  fileprivate func admitting(prior: DreamAdmittedView?, admit: ([String]) throws -> [String]) throws
    -> DreamAdmittedView
  {
    if let prior {
      try prior.validate()
      guard prior.path == path.rawValue, prior.originalCompleteBytes <= UInt64(bytes.count),
        SourceDigest(bytes: bytes.prefix(Int(prior.originalCompleteBytes))).rawValue
          == prior.originalPrefixHash
      else { throw DreamSourceProtectionError.invalidReply }
    }
    let omissions = try DreamSourceProtection.omittedReadResults(records.map(\.object))
    let oldCount = prior?.records.count ?? 0
    guard records.count <= DreamSourceProtection.maximumPieces, oldCount <= records.count else {
      throw DreamSourceProtectionError.limitExceeded
    }
    let pending = try records.enumerated().dropFirst(oldCount).map { index, record in
      try DreamSourceProtection.text(
        omissions.contains(index) ? DreamAdmittedView.omitted(record.bytes) : record.bytes)
    }
    let checked = pending.isEmpty ? [] : try admit(pending)
    guard checked.count == pending.count else { throw DreamSourceProtectionError.invalidReply }
    var admitted = prior?.bytes ?? Data()
    var relations = prior?.records ?? []
    for (offset, record) in records.dropFirst(oldCount).enumerated() {
      let index = oldCount + offset
      let original =
        omissions.contains(index) ? try DreamAdmittedView.omitted(record.bytes) : record.bytes
      let safe = Data(checked[offset].utf8)
      let identity = try DreamAdmittedView.identity(original)
      guard safe.last == 10, !safe.dropLast().contains(10),
        try DreamAdmittedView.identity(safe) == identity
      else { throw DreamSourceProtectionError.invalidReply }
      let start = UInt64(admitted.count)
      admitted.append(safe)
      guard admitted.count <= DreamSourceProtection.maximumInputBytes else {
        throw DreamSourceProtectionError.limitExceeded
      }
      relations.append(
        DreamAdmittedView.Record(
          originalStart: record.range.lowerBound, originalEnd: record.range.upperBound,
          originalHash: SourceDigest(bytes: record.bytes).rawValue,
          originalPrefixHash: SourceDigest(bytes: bytes.prefix(Int(record.range.upperBound)))
            .rawValue,
          admittedStart: start, admittedEnd: UInt64(admitted.count),
          admittedHash: SourceDigest(bytes: safe).rawValue,
          identityHash: identity, isOmitted: omissions.contains(index)))
    }
    let complete = records.last!.range.upperBound
    let view = try DreamAdmittedView(
      version: 1, extractionVersion: SessionReader.preparationSchemaVersion,
      path: path.rawValue, originalCompleteBytes: complete,
      originalPrefixHash: SourceDigest(bytes: bytes.prefix(Int(complete))).rawValue,
      admittedHash: SourceDigest(bytes: admitted).rawValue, relationHash: "", bytes: admitted,
      records: relations
    ).sealed()
    try view.validate()
    return view
  }
}
