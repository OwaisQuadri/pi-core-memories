import Darwin
import Foundation

private struct NativeQueueBinding: Codable, Equatable {
  let schemaVersion: Int
  let review: ReviewRootBinding
  let queue: String
  let queueVolumeUUID: String
  let queueInode: UInt64
}

enum MemoryQueueAuthority {
  private static func locked<T>(git: Git, _ operation: (DreamStateDirectory) throws -> T) throws
    -> T
  {
    guard let common = try git.commonDirectory(), let resolved = realpath(common.path, nil) else {
      throw DreamRunError.unsafeState
    }
    let canonical = URL(fileURLWithPath: String(cString: resolved))
    free(resolved)
    let root = try DreamStateDirectory.openRoot(canonical.appendingPathComponent("memory-queue"))
    let lock = try root.openLock().descriptor
    defer {
      _ = flock(lock, LOCK_UN)
      _ = close(lock)
    }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw DreamRunError.busy }
    try root.verifyLock(lock)
    var parent = stat()
    var commonStatus = stat()
    guard fstatat(root.descriptor, "..", &parent, AT_SYMLINK_NOFOLLOW) == 0,
      lstat(canonical.path, &commonStatus) == 0,
      parent.st_dev == commonStatus.st_dev, parent.st_ino == commonStatus.st_ino
    else { throw DreamRunError.unsafeState }
    return try operation(root)
  }

  private static func binding(_ root: DreamStateDirectory) throws -> NativeQueueBinding? {
    guard try root.isPresent("binding.json") else { return nil }
    let binding = try MemoryReviewEncoding.decode(
      NativeQueueBinding.self,
      bytes: root.read("binding.json", maximum: MemoryReviewEncoding.maximumFileBytes))
    guard binding.schemaVersion == 1 else { throw DreamRunError.unsupportedSchema }
    return binding
  }

  static func rejectedNames(git: Git, repository: URL, sourceBinding: String) throws
    -> [String]
  {
    try withBoundReview(git: git, repository: repository, sourceBinding: sourceBinding) {
      reviewRoot, _, _ in
      try reviewRoot.names().filter { $0.hasPrefix("rejected-") && $0.hasSuffix(".json") }
        .sorted()
    } ?? []
  }

  static func rejectedFindings(git: Git, repository: URL, sourceBinding: String) throws
    -> [MemoryQueueFinding]
  {
    try withBoundReview(git: git, repository: repository, sourceBinding: sourceBinding) {
      reviewRoot, queue, review in
      guard try queue.isPresent("queue.json") else { return [] }
      let ledger = try MemoryReviewEncoding.decode(
        QueueLedger.self,
        bytes: queue.read("queue.json", maximum: MemoryReviewEncoding.maximumFileBytes))
      guard ledger.schemaVersion == 1,
        ledger.binding == SourceDigest(bytes: try MemoryReviewEncoding.encode(review)).rawValue,
        ledger.findings.count <= 10_000,
        Set(ledger.findings.map(\.revision)).count == ledger.findings.count,
        ledger.findings.allSatisfy({ $0.revision == $0.candidateID })
      else { throw MemoryError("queue binding conflict") }
      return try ledger.findings.filter { finding in
        let name = "rejected-\(finding.revision).json"
        guard MemoryDocument.isMatch(#"\A[0-9a-f]{64}\z"#, finding.revision) else {
          throw DreamRunError.corruption
        }
        guard try reviewRoot.isPresent(name) else { return false }
        let selection = try MemoryReviewEncoding.decode(
          ReviewSelection.self,
          bytes: reviewRoot.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
        guard selection.candidateID == finding.revision, selection.disposition == .rejected else {
          throw DreamRunError.corruption
        }
        return true
      }
    } ?? []
  }

  private static func withBoundReview<T>(
    git: Git, repository: URL, sourceBinding: String,
    _ operation: (DreamStateDirectory, DreamStateDirectory, ReviewRootBinding) throws -> T
  ) throws -> T? {
    guard let common = try git.commonDirectory(),
      FileManager.default.fileExists(atPath: common.appendingPathComponent("memory-queue").path)
    else { return nil }
    return try locked(git: git) { root -> T? in
      guard let binding = try binding(root) else { return nil }
      let review = binding.review
      guard review.schemaVersion == 2 else { throw DreamRunError.unsupportedSchema }
      guard review.repository == repository.path, review.sourceBinding == sourceBinding else {
        throw MemoryError("repository review profile differs from its native queue binding")
      }
      let reviewURL = URL(fileURLWithPath: review.state)
      let queueURL = URL(fileURLWithPath: binding.queue)
      let reviewRoot = try DreamStateDirectory.openRoot(reviewURL, isCreating: false)
      let queue = try DreamStateDirectory.openRoot(queueURL, isCreating: false)
      let reviewLock = try reviewRoot.openReadLock()
      defer {
        _ = flock(reviewLock, LOCK_UN)
        _ = close(reviewLock)
      }
      guard flock(reviewLock, LOCK_EX | LOCK_NB) == 0 else { throw DreamRunError.busy }
      try reviewRoot.verifyLock(reviewLock)
      let queueLock = try queue.openReadLock()
      defer {
        _ = flock(queueLock, LOCK_UN)
        _ = close(queueLock)
      }
      guard flock(queueLock, LOCK_EX | LOCK_NB) == 0 else { throw DreamRunError.busy }
      try queue.verifyLock(queueLock)
      var repositoryStatus = stat()
      var reviewStatus = stat()
      var queueStatus = stat()
      guard lstat(repository.path, &repositoryStatus) == 0,
        fstat(reviewRoot.descriptor, &reviewStatus) == 0,
        fstat(queue.descriptor, &queueStatus) == 0,
        UInt64(repositoryStatus.st_ino) == review.repositoryInode,
        UInt64(reviewStatus.st_ino) == review.stateInode,
        UInt64(queueStatus.st_ino) == binding.queueInode,
        try MemoryReviewEncoding.volumeUUID(at: repository) == review.repositoryVolumeUUID,
        try MemoryReviewEncoding.volumeUUID(at: reviewURL) == review.stateVolumeUUID,
        try MemoryReviewEncoding.volumeUUID(at: queueURL) == binding.queueVolumeUUID,
        try reviewRoot.read("root.json", maximum: MemoryReviewEncoding.maximumFileBytes)
          == MemoryReviewEncoding.encode(review)
      else { throw DreamRunError.unsafeState }
      _ = try reviewRoot.retainedBytes(maximum: MemoryReviewEncoding.maximumStateBytes)
      _ = try queue.retainedBytes(maximum: MemoryReviewEncoding.maximumStateBytes)
      return try operation(reviewRoot, queue, review)
    }
  }

  static func activate(git: Git, review: ReviewRootBinding, queue: URL) throws {
    let directory = try DreamStateDirectory.openRoot(queue, isCreating: false)
    var status = stat()
    guard fstat(directory.descriptor, &status) == 0 else { throw DreamRunError.unsafeState }
    let expected = NativeQueueBinding(
      schemaVersion: 1, review: review, queue: queue.path,
      queueVolumeUUID: try MemoryReviewEncoding.volumeUUID(at: queue),
      queueInode: UInt64(status.st_ino))
    try locked(git: git) { root in
      if let existing = try binding(root) {
        guard existing == expected else { throw MemoryError("repository queue binding conflict") }
      } else {
        try root.installReviewFile(MemoryReviewEncoding.encode(expected), name: "binding.json")
      }
    }
  }

  static func verifyReview(git: Git, review: ReviewRootBinding) throws {
    try locked(git: git) { root in
      if let binding = try binding(root), binding.review != review {
        throw MemoryError("repository review profile differs from its native queue binding")
      }
    }
  }

  static func publish<T>(git: Git, review: ReviewRootBinding?, _ operation: () throws -> T) throws
    -> T
  {
    try locked(git: git) { root in
      if let binding = try binding(root) {
        guard let review, binding.review == review else {
          throw MemoryError("queue-bound publication requires its verified native review profile")
        }
      }
      return try operation()
    }
  }
}
