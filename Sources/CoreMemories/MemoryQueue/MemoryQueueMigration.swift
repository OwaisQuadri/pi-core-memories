import Darwin
import Foundation

package struct MemoryQueueArtifact: Codable, Equatable {
  package let source: String
  package let name: String
  package let digest: String
  package let byteCount: String
  package let limitation: String
}

package struct MemoryQueueInventory: Codable {
  package let schemaVersion: Int
  package let mode: String
  package let approvedBase: String
  package let refs: [[String]]
  package let artifacts: [MemoryQueueArtifact]
  package let runs: [SavedDreamRun]
  package let candidateRevisions: [String]
  package let limitation: String?

  package static func readOnly(configuration: MemoryConfiguration) throws -> Self {
    let store = try MemoryStore(repo: configuration.memoryURL)
    let base = try store.approvedCommit()
    let refs = try MemoryQueueMigration.refs(store.reviewGit)
    let artifacts =
      try MemoryQueueMigration.retained(
        URL(fileURLWithPath: configuration.reviewState), source: "review")
      + MemoryQueueMigration.retained(
        URL(fileURLWithPath: configuration.journal), source: "journal")
      + MemoryQueueMigration.retained(configuration.stateURL, source: "dream")
      + MemoryQueueMigration.proposals(refs)
    guard try store.approvedCommit() == base else {
      throw MemoryError("inventory changed; retry inspection")
    }
    return Self(
      schemaVersion: 1, mode: "inventory-only", approvedBase: base, refs: refs,
      artifacts: artifacts, runs: [], candidateRevisions: [],
      limitation:
        "Verified dream sources are unavailable. All retained items are blocked migration inventory, not findings or consent; original native recovery and fresh review are required."
    )
  }
}

enum MemoryQueueMigration {
  static func refs(_ git: Git) throws -> [[String]] {
    let raw = try git.text([
      "for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)",
      "refs/heads/proposals/", "refs/memory-review/", "refs/memory-management/",
      "refs/memory-batches/",
    ])
    guard raw.utf8.count <= MemoryReviewEncoding.maximumFileBytes else {
      throw DreamRunError.limitExceeded
    }
    let refs = raw.split(separator: "\n").map {
      $0.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    }
    guard refs.count <= 10_000, refs.allSatisfy({ $0.count == 3 }) else {
      throw DreamRunError.corruption
    }
    return refs
  }

  static func proposals(_ refs: [[String]]) -> [MemoryQueueArtifact] {
    refs.filter { $0[0].hasPrefix("refs/heads/proposals/") }.map { ref in
      MemoryQueueArtifact(
        source: "proposal", name: ref[0], digest: ref[1], byteCount: "0",
        limitation:
          "Unapproved proposal ref. Ref alone supplies no verified primary evidence or live authority; original proposal inspection and evidence recovery are required."
      )
    }
  }

  static func retained(_ url: URL, source: String) throws -> [MemoryQueueArtifact] {
    var status = stat()
    if lstat(url.path, &status) != 0 {
      guard errno == ENOENT else { throw DreamRunError.unsafeState }
      return []
    }
    let root = try DreamStateDirectory.openRoot(url, isCreating: false)
    let lock = try root.openReadLock()
    defer {
      _ = flock(lock, LOCK_UN)
      _ = close(lock)
    }
    guard flock(lock, LOCK_SH | LOCK_NB) == 0 else { throw DreamRunError.busy }
    try root.verifyLock(lock)
    _ = try root.retainedBytes(maximum: 1_073_741_824, isDreamAuthority: source == "dream")
    return try artifacts(root, source: source)
  }

  static func artifacts(
    _ root: DreamStateDirectory, source: String, prefix: String = "", depth: Int = 0
  ) throws -> [MemoryQueueArtifact] {
    guard depth < 8 else { throw DreamRunError.limitExceeded }
    var artifacts: [MemoryQueueArtifact] = []
    for name in try root.names().sorted() where name != "writer.lock" {
      var status = stat()
      guard fstatat(root.descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw DreamRunError.unsafeState
      }
      let relative = prefix + name
      if status.st_mode & S_IFMT == S_IFDIR {
        artifacts += try self.artifacts(
          root.child(name), source: source, prefix: relative + "/", depth: depth + 1)
      } else {
        let bytes = try root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes)
        artifacts.append(
          MemoryQueueArtifact(
            source: source, name: relative, digest: SourceDigest(bytes: bytes).rawValue,
            byteCount: String(bytes.count),
            limitation:
              "Retained in original authority; no restored consent. Recovery uses the original native format."
          ))
      }
      guard artifacts.count <= 10_000 else { throw DreamRunError.limitExceeded }
    }
    return artifacts
  }
}

extension MemoryQueue {
  package func inventory(configuration: MemoryConfiguration) throws -> MemoryQueueInventory {
    let review = try controller()
    guard configuration.memoryURL.path == review.repository.path,
      configuration.reviewState == review.binding.state
    else { throw MemoryError("inventory configuration binding conflict") }
    let base = try review.store.approvedCommit()
    var limitation: String?
    var revisions: [String] = []
    do {
      let request = try MemoryQueueRequest(sessionID: "inventory", requestID: "inventory")
      revisions = try importCandidates(review.list(), review: review, request: request)
        .map { $0.finding.revision }
    } catch {
      if (error as? DreamRunError) == .busy { throw error }
      limitation =
        "Verified candidate projection is blocked; original artifacts remain authoritative."
    }
    let dreams = try DreamInspection.read(stateRoot: configuration.stateURL)
    guard !dreams.isBusy else { throw DreamRunError.busy }
    let refs = try MemoryQueueMigration.refs(review.store.reviewGit)
    let artifacts =
      try MemoryQueueMigration.artifacts(review.root, source: "review")
      + MemoryQueueMigration.retained(
        URL(fileURLWithPath: configuration.journal), source: "journal")
      + MemoryQueueMigration.retained(configuration.stateURL, source: "dream")
      + MemoryQueueMigration.proposals(refs)
    guard try review.store.approvedCommit() == base else {
      throw MemoryError("inventory changed; retry inspection")
    }
    let inventory = MemoryQueueInventory(
      schemaVersion: 1, mode: "additive-projection", approvedBase: base,
      refs: refs, artifacts: artifacts, runs: dreams.runs,
      candidateRevisions: revisions.sorted(), limitation: limitation)
    let bytes = try MemoryReviewEncoding.encode(inventory)
    let digest = SourceDigest(bytes: bytes).rawValue
    try ledger(review) { _ in
      try directory.installReviewFile(bytes, name: "inventory-\(digest).json")
    }
    return inventory
  }
}
