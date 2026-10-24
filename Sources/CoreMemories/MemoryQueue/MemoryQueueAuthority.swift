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
