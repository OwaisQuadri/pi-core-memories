import Darwin
import Foundation

enum MemoryReviewEncoding {
  static let maximumFileBytes = 8 * 1024 * 1024
  static let maximumStateBytes = 64 * 1024 * 1024

  static func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(value)
    guard bytes.count <= maximumFileBytes else { throw DreamRunError.limitExceeded }
    return bytes
  }

  static func volumeUUID(at url: URL) throws -> String {
    guard let value = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
      let uuid = UUID(uuidString: value)
    else {
      throw DreamRunError.nativeReviewLimitation(
        "persistent volume identity is unavailable for \(url.path)")
    }
    return uuid.uuidString
  }

  static func decode<T: Codable>(_ type: T.Type, bytes: Data) throws -> T {
    let value = try JSONDecoder().decode(type, from: bytes)
    guard try encode(value) == bytes else { throw DreamRunError.corruption }
    return value
  }
}

struct ReviewAdmission: Codable, Equatable {
  let schemaVersion: Int
  let candidateID: String
  let runID: String
  let generation: UInt64
  let admissionHash: String
  let completionHash: String
  let decisionsHash: String
  let receipts: [[String]]
  let recoveryCheckpointHash: String?

  init(change: AtomicMemoryChange, bundle: VerifiedDreamReviewCandidates) {
    schemaVersion = bundle.recoveryCheckpointHash == nil ? 1 : 2
    recoveryCheckpointHash = bundle.recoveryCheckpointHash?.rawValue
    candidateID = change.id.rawValue
    runID = bundle.runID
    generation = bundle.generation
    admissionHash = bundle.admissionHash.rawValue
    completionHash = bundle.completionHash.rawValue
    decisionsHash = bundle.decisionsHash.rawValue
    receipts = bundle.receipts.map {
      [$0.planHash.rawValue, $0.ref, $0.commit, $0.base, $0.path]
    }
  }
}

struct ReviewRootBinding: Codable, Equatable {
  let schemaVersion: Int
  let repository: String
  let repositoryVolumeUUID: String
  let repositoryInode: UInt64
  let sourceBinding: String
  let state: String
  let stateVolumeUUID: String
  let stateInode: UInt64
}

struct LegacyReviewRootBinding: Codable, Equatable {
  let schemaVersion: Int
  let repository: String
  let repositoryDevice: UInt64
  let repositoryInode: UInt64
  let sourceBinding: String
  let stateDevice: UInt64
  let stateInode: UInt64
}

struct ReviewSelection: Codable, Equatable {
  let candidateID: String
  let disposition: MemoryReviewDisposition
}

struct ReviewPreviewPayload: Codable, Equatable {
  let candidateID: String
  let admissionHash: String
  let frozenBase: String
  let currentBase: String
  let path: String
  let identity: UUID
  let instant: MemoryDocument.ReviewInstant
  let start: Int
  let end: Int
  let before: Data
  let after: Data
  let originalDocument: Data
  let replacement: Data
  let checkout: ReviewCheckoutWitness
}

struct ReviewAttempt: Codable, Equatable {
  let schemaVersion: Int
  let preview: ReviewPreviewPayload
  let previewHash: String
  let resultCommit: String
  let resultTree: String
  let auditRef: String
}

struct ReviewCheckoutWitness: Codable, Equatable, Sendable {
  let gitDevice: UInt64
  let gitInode: UInt64
  let head: Data
  let commit: String
  let main: String
  let index: Data
  let config: Data
  let sharedIndexes: [String: Data]
}

struct ReviewDetachAttempt: Codable, Equatable {
  let schemaVersion: Int
  let witness: ReviewCheckoutWitness
  let digest: String
  let auditRef: String
}

struct ReviewCheckoutLease: Codable, Equatable {
  let owner: Int32
  let identity: UUID
  let gitDevice: UInt64
  let gitInode: UInt64
  let headDevice: UInt64
  let headInode: UInt64
  let indexDevice: UInt64
  let indexInode: UInt64
  let detachedHead: Data
}

enum MemoryReviewPersistenceEvent: Equatable {
  case afterCheckoutLocks
  case beforeWrite(String)
  case beforeFileSync(String)
  case beforeInstall(String)
  case afterInstall(String)
  case afterDirectorySync(String)
  case beforeDetach
  case afterDetach
  case beforePublication
  case afterPublication
}

struct MemoryReviewFileIO {
  var writeChunkBytes: Int = Int.max
  var write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
  var sync: (Int32) -> Int32 = { Darwin.fsync($0) }
  var install: (Int32, String, String) -> Int32 = {
    Darwin.renameatx_np($0, $1, $0, $2, UInt32(RENAME_EXCL))
  }
}

extension DreamStateDirectory {
  func installReviewFile(
    _ bytes: Data, name: String, isReplacing: Bool = false,
    fault: ((MemoryReviewPersistenceEvent) throws -> Void)? = nil,
    io: MemoryReviewFileIO = MemoryReviewFileIO()
  ) throws {
    guard !name.isEmpty, !name.contains("/"), name != ".", name != "..",
      bytes.count <= MemoryReviewEncoding.maximumFileBytes
    else { throw DreamRunError.unsafeState }
    if try isPresent(name) {
      let existing = try read(name, maximum: MemoryReviewEncoding.maximumFileBytes)
      if !isReplacing {
        guard existing == bytes else { throw DreamRunError.corruption }
        return
      }
    }
    let retained = try retainedBytes(maximum: MemoryReviewEncoding.maximumStateBytes)
    guard bytes.count <= MemoryReviewEncoding.maximumStateBytes - retained else {
      throw DreamRunError.limitExceeded
    }
    let temporary = ".pending-" + UUID().uuidString
    let file = openat(
      descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw DreamRunError.persistenceFailure }
    var isClosed = false
    defer {
      if !isClosed { _ = close(file) }
      _ = unlinkat(descriptor, temporary, 0)
    }
    try verifyFile(file)
    try fault?(.beforeWrite(name))
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let requested = min(buffer.count - offset, io.writeChunkBytes)
        guard requested > 0 else { throw DreamRunError.persistenceFailure }
        let count = io.write(file, buffer.baseAddress! + offset, requested)
        if count < 0, errno == EINTR { continue }
        guard count > 0, count <= requested else { throw DreamRunError.persistenceFailure }
        offset += count
      }
    }
    try fault?(.beforeFileSync(name))
    guard io.sync(file) == 0, close(file) == 0 else { throw DreamRunError.persistenceFailure }
    isClosed = true
    try fault?(.beforeInstall(name))
    let installed =
      isReplacing
      ? Darwin.renameat(descriptor, temporary, descriptor, name)
      : io.install(descriptor, temporary, name)
    guard installed == 0 else {
      throw DreamRunError.persistenceFailure
    }
    try fault?(.afterInstall(name))
    guard io.sync(descriptor) == 0 else { throw DreamRunError.persistenceFailure }
    try fault?(.afterDirectorySync(name))
  }
}
