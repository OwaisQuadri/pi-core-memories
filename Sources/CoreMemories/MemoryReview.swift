import Darwin
import Foundation

package enum MemoryReviewDisposition: String, Codable, Sendable {
  case pending, deferred, rejected, approved, blocked
}

package struct MemoryReviewCandidate: Sendable {
  package let change: AtomicMemoryChange
  package let disposition: MemoryReviewDisposition
  package let limitation: String?
  package let frozenLimitations: [String]
}

package struct MemoryReviewPreview: Sendable {
  package let change: AtomicMemoryChange
  package let currentBase: String
  package let identity: UUID
  package let instant: MemoryDocument.ReviewInstant
  package let before: Data
  package let after: Data
  package let replacement: Data
  package let digest: SourceDigest
  let payload: ReviewPreviewPayload
}

package struct MemoryReviewCheckoutPreview: Sendable {
  package let commit: String
  package let main: String
  package let isDetachRequired: Bool
  package let digest: SourceDigest
  let witness: ReviewCheckoutWitness
}

package struct MemoryReviewApproval: Sendable {
  package let candidateID: SourceDigest
  package let previewHash: SourceDigest
  package let commit: String
  package let auditRef: String
}

package struct MemoryReviewMutationFailure: Error, CustomStringConvertible {
  package enum Mutation: String, Sendable { case approved, detached }
  package let mutation: Mutation
  package let commit: String
  package let auditRef: String?
  package let followUpFailure: String

  package var description: String {
    "\(mutation.rawValue) at \(commit); follow-up persistence or recovery is incomplete: \(followUpFailure)"
  }
}

package final class MemoryReviewController {
  let root: DreamStateDirectory
  private let stateURL: URL
  let repository: URL
  private let sources: DreamRunStore
  let store: MemoryStore
  let binding: ReviewRootBinding
  private let repositoryDevice: dev_t
  private let stateDevice: dev_t
  private let writer: Int32
  private let operationLock = NSLock()
  var candidates: [String: (AtomicMemoryChange, ReviewAdmission, [String])] = [:]
  var batchPublications: [String: VerifiedMemoryPublication] = [:]
  var legacyPublications: [String: VerifiedMemoryPublication] = [:]
  var batchSelections: [String: MemoryReviewDisposition] = [:]
  var previews: [String: ReviewPreviewPayload] = [:]
  private var checkoutPreviews: [String: ReviewCheckoutWitness] = [:]
  var approvals: [String: ReviewAttempt] = [:]
  var checkoutState: DreamStateDirectory?
  var fileIO = MemoryReviewFileIO()
  package var isCancelled: () -> Bool = { false }
  var persistenceFault: ((MemoryReviewPersistenceEvent) throws -> Void)?
  var batchHistoryObserver: (() -> Void)?

  package init(
    repository: URL, stateRoot: URL, sources: DreamRunStore,
    environment: [String: String]
  ) throws {
    guard
      [repository, stateRoot].allSatisfy({
        $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.contains("\0")
          && !$0.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
      }), let resolved = realpath(repository.path, nil)
    else { throw DreamRunError.unsafeState }
    let repo = URL(fileURLWithPath: String(cString: resolved))
    free(resolved)
    guard repo.path == repository.path, sources.acceptedSources.memory.path == repo.path else {
      throw DreamRunError.unsafeState
    }
    let protectedRoots =
      [repo, sources.reviewStateRoot, sources.acceptedSources.sessions]
      + sources.acceptedSources.stripping
    guard
      protectedRoots.allSatisfy({ source in
        !Self.isWithin(stateRoot, source) && !Self.isWithin(source, stateRoot)
      })
    else { throw DreamRunError.unsafeState }
    var ancestor = stateRoot
    while !FileManager.default.fileExists(atPath: ancestor.path) {
      ancestor.deleteLastPathComponent()
    }
    guard try Git(repo: ancestor, environment: environment).commonDirectory() == nil else {
      throw DreamRunError.unsafeState
    }
    let directory = try DreamStateDirectory.openRoot(stateRoot)
    let ownership = try directory.openLock()
    let lock = ownership.descriptor
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      _ = close(lock)
      throw DreamRunError.busy
    }
    do {
      try directory.verifyLock(lock)
      var repoStatus = stat()
      var stateStatus = stat()
      guard lstat(repo.path, &repoStatus) == 0, repoStatus.st_mode & S_IFMT == S_IFDIR,
        repoStatus.st_uid == geteuid(), fstat(directory.descriptor, &stateStatus) == 0
      else { throw DreamRunError.unsafeState }
      let binding = ReviewRootBinding(
        schemaVersion: 2, repository: repo.path,
        repositoryVolumeUUID: try MemoryReviewEncoding.volumeUUID(at: repo),
        repositoryInode: UInt64(repoStatus.st_ino),
        sourceBinding: try sources.reviewSourceBinding().rawValue, state: stateRoot.path,
        stateVolumeUUID: try MemoryReviewEncoding.volumeUUID(at: stateRoot),
        stateInode: UInt64(stateStatus.st_ino))
      try MemoryQueueAuthority.verifyReview(git: Git(repo: repo, environment: environment), review: binding)
      let bytes = try MemoryReviewEncoding.encode(binding)
      if try directory.isPresent("root.json") {
        let existing = try directory.read(
          "root.json", maximum: MemoryReviewEncoding.maximumFileBytes)
        if let legacy = try? MemoryReviewEncoding.decode(
          LegacyReviewRootBinding.self, bytes: existing), legacy.schemaVersion == 1
        {
          let expected = LegacyReviewRootBinding(
            schemaVersion: 1, repository: repo.path,
            repositoryDevice: UInt64(repoStatus.st_dev), repositoryInode: UInt64(repoStatus.st_ino),
            sourceBinding: try sources.reviewSourceBinding(isLegacy: true).rawValue,
            stateDevice: UInt64(stateStatus.st_dev), stateInode: UInt64(stateStatus.st_ino))
          guard try existing == MemoryReviewEncoding.encode(expected) else {
            throw DreamRunError.corruption
          }
          try directory.installReviewFile(bytes, name: "root.json", isReplacing: true)
        } else {
          guard existing == bytes else { throw DreamRunError.corruption }
        }
      } else {
        try directory.installReviewFile(bytes, name: "root.json")
      }
      self.root = directory
      self.writer = lock
      self.stateURL = stateRoot
      self.repository = repo
      self.sources = sources
      self.store = try MemoryStore(repo: repo, environment: environment)
      self.binding = binding
      self.repositoryDevice = repoStatus.st_dev
      self.stateDevice = stateStatus.st_dev
    } catch {
      _ = flock(lock, LOCK_UN)
      _ = close(lock)
      throw error
    }
  }

  deinit {
    _ = flock(writer, LOCK_UN)
    _ = close(writer)
  }

  package func list() throws -> [MemoryReviewCandidate] {
    try locked {
      try refresh()
      var currentSnapshot: ApprovedDecisionSnapshot?
      var frozenSnapshot: ApprovedDecisionSnapshot?
      return try candidates.keys.sorted().map { id in
        let (change, _, limitations) = candidates[id]!
        let disposition = try selection(id)
        if disposition == .rejected || disposition == .approved {
          return MemoryReviewCandidate(
            change: change, disposition: disposition, limitation: nil,
            frozenLimitations: limitations)
        }
        do {
          _ = try currentTarget(
            change, currentSnapshot: &currentSnapshot, frozenSnapshot: &frozenSnapshot)
          return MemoryReviewCandidate(
            change: change, disposition: disposition, limitation: nil,
            frozenLimitations: limitations)
        } catch let error as MemoryError {
          return MemoryReviewCandidate(
            change: change, disposition: .blocked, limitation: error.description,
            frozenLimitations: limitations)
        }
      }
    }
  }

  package func preview(
    candidateID: SourceDigest, clockDate: Date, amendment: MemoryBatchAmendment? = nil
  ) throws -> MemoryReviewPreview {
    try locked {
      try refresh()
      let id = candidateID.rawValue
      guard let (change, admission, _) = candidates[id],
        try selection(id) == .pending || selection(id) == .deferred
      else { throw MemoryError("candidate is not selectable") }
      var currentSnapshot: ApprovedDecisionSnapshot?
      var frozenSnapshot: ApprovedDecisionSnapshot?
      let target = try currentTarget(
        change, currentSnapshot: &currentSnapshot, frozenSnapshot: &frozenSnapshot)
      let identity = try change.entryID ?? Self.assignedIdentity(id)
      guard
        !target.snapshot.reviewEntries().contains(where: {
          $0.entry.identity == identity
            && !($0.path == change.path && $0.entry.locator == target.locator)
        })
      else { throw MemoryError("memory identity is already in use") }
      guard clockDate.timeIntervalSince1970.isFinite else {
        throw MemoryError("invalid review clock")
      }
      let formatter = ISO8601DateFormatter()
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.formatOptions = [.withInternetDateTime]
      let instant = try MemoryDocument.ReviewInstant(formatter.string(from: clockDate))
      let before = Data(target.bytes[target.range])
      let original = try MemoryDocument.reviewedBytes(
        change.after, identity: identity, instant: instant)
      let admissionHash = SourceDigest(bytes: try MemoryReviewEncoding.encode(admission)).rawValue
      let intent = MemoryBatchCandidateIntent(
        candidateID: id, admissionHash: admissionHash, choice: .accept,
        identity: identity, instant: instant, amendment: amendment)
      let after = try Self.amendedBatchBytes(intent, proposal: original, before: before)
      var replacement = target.bytes
      let insertion = change.operation == .add ? Self.addSeparator(target.bytes) + after : after
      replacement.replaceSubrange(target.range, with: insertion)
      guard MemoryDocument.failures(in: replacement).isEmpty,
        let reviewed = MemoryDocument.entries(in: replacement).first(where: {
          $0.identity == identity
        }),
        reviewed.isMutable, reviewed.bytes == after,
        MemoryDocument.entries(in: replacement).filter({ $0.identity == identity }).count == 1
      else { throw MemoryError("final native review document is invalid") }
      let payload = ReviewPreviewPayload(
        candidateID: id, admissionHash: admissionHash,
        frozenBase: change.base, currentBase: target.snapshot.base, path: change.path,
        identity: identity, instant: instant, start: target.range.lowerBound,
        end: target.range.upperBound, before: before, after: after,
        originalDocument: target.bytes, replacement: replacement,
        checkout: try store.reviewGit.reviewCheckout().witness(), amendment: amendment)
      let digest = SourceDigest(bytes: try MemoryReviewEncoding.encode(payload))
      previews[id] = payload
      return MemoryReviewPreview(
        change: change, currentBase: target.snapshot.base, identity: identity, instant: instant,
        before: payload.before, after: after, replacement: replacement, digest: digest,
        payload: payload)
    }
  }

  package func checkoutPreview() throws -> MemoryReviewCheckoutPreview {
    try locked {
      try refresh()
      let witness = try store.reviewGit.reviewCheckout().witness()
      let digest = SourceDigest(bytes: try MemoryReviewEncoding.encode(witness))
      checkoutPreviews[digest.rawValue] = witness
      return MemoryReviewCheckoutPreview(
        commit: witness.commit, main: witness.main,
        isDetachRequired: witness.head == Data("ref: refs/heads/main\n".utf8),
        digest: digest, witness: witness)
    }
  }

  package func confirmDetach(_ preview: MemoryReviewCheckoutPreview) throws {
    try locked {
      try refresh()
      guard checkoutPreviews.removeValue(forKey: preview.digest.rawValue) == preview.witness,
        preview.isDetachRequired
      else { throw MemoryError("checkout confirmation is stale") }
      guard !isCancelled() else { throw MemoryError("review cancelled before checkout change") }
      let checkout = try store.reviewGit.reviewCheckout()
      try checkout.lock(state: checkoutState!, detachedHead: Data((preview.commit + "\n").utf8))
      try persistenceFault?(.afterCheckoutLocks)
      guard try checkout.witness(isLocked: true) == preview.witness else {
        throw MemoryError("checkout preview changed; review it again")
      }
      let attempt = ReviewDetachAttempt(
        schemaVersion: 1, witness: preview.witness, digest: preview.digest.rawValue,
        auditRef: "refs/memory-review/detach/\(preview.digest.rawValue)")
      try root.installReviewFile(
        MemoryReviewEncoding.encode(attempt), name: "detach-attempt-\(attempt.digest).json",
        fault: persistenceFault, io: fileIO)
      try persistenceFault?(.beforeDetach)
      guard !isCancelled() else { throw MemoryError("review cancelled before checkout change") }
      try checkout.detach(preview.witness)
      previews.removeAll()
      do {
        try persistenceFault?(.afterDetach)
        try recordDetach(attempt)
      } catch {
        throw MemoryReviewMutationFailure(
          mutation: .detached, commit: preview.commit,
          auditRef: (try? directAudit(attempt.auditRef)) == preview.commit ? attempt.auditRef : nil,
          followUpFailure: "\(error)")
      }
    }
  }

  package func apply(_ preview: MemoryReviewPreview) throws -> MemoryReviewApproval {
    try locked {
      try withBatchSources(state: checkoutState!) {
        let payload = preview.payload
        guard previews.removeValue(forKey: payload.candidateID) == payload,
          try selection(payload.candidateID) == .pending
            || selection(payload.candidateID) == .deferred,
          preview.digest.rawValue
            == SourceDigest(bytes: try MemoryReviewEncoding.encode(payload)).rawValue,
          try store.approvedCommit() == payload.currentBase
        else { throw MemoryError("entry preview changed; review it again") }
        guard !isCancelled() else { throw MemoryError("review cancelled before publication") }
        return try MemoryBatchPublisher.applyLegacy(preview, review: self)
      }
    }
  }

  package func reject(candidateID: SourceDigest) throws {
    try choose(candidateID, disposition: .rejected)
  }

  package func deferCandidate(candidateID: SourceDigest) throws {
    try choose(candidateID, disposition: .deferred)
  }

  private func choose(_ candidateID: SourceDigest, disposition: MemoryReviewDisposition) throws {
    try locked {
      try withBatchSources(state: checkoutState!) {
        let id = candidateID.rawValue
        guard candidates[id] != nil, try selection(id) != .approved,
          try selection(id) != .rejected
        else { throw MemoryError("candidate is not selectable") }
        let selection = ReviewSelection(candidateID: id, disposition: disposition)
        try root.installReviewFile(
          MemoryReviewEncoding.encode(selection), name: "\(disposition.rawValue)-\(id).json",
          fault: persistenceFault, io: fileIO)
        previews.removeValue(forKey: id)
      }
    }
  }

  func selection(_ id: String) throws -> MemoryReviewDisposition {
    if let disposition = batchSelections[id] { return disposition }
    if approvals[id] != nil { return .approved }
    for disposition in [MemoryReviewDisposition.rejected, .deferred] {
      let name = "\(disposition.rawValue)-\(id).json"
      if try root.isPresent(name) {
        let value = try MemoryReviewEncoding.decode(
          ReviewSelection.self,
          bytes: root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
        guard value == ReviewSelection(candidateID: id, disposition: disposition) else {
          throw DreamRunError.corruption
        }
        return disposition
      }
    }
    return .pending
  }

  func refresh(bundles supplied: [VerifiedDreamReviewCandidates]? = nil) throws {
    batchHistoryObserver?()
    try verifyBinding()
    try store.reviewGit.reviewCheckout().recoverLease(state: root)
    let bundles = try supplied ?? sources.verifiedCompletedReviewCandidates()
    var loaded: [String: (AtomicMemoryChange, ReviewAdmission, [String])] = [:]
    for bundle in bundles {
      for change in bundle.changes {
        let id = change.id.rawValue
        let admission = ReviewAdmission(change: change, bundle: bundle)
        guard loaded[id] == nil else { throw DreamRunError.corruption }
        loaded[id] = (change, admission, bundle.limitations)
      }
    }
    guard loaded.count <= 10_000 else { throw DreamRunError.limitExceeded }
    for name in try root.names() where !name.hasPrefix(".pending-") {
      if name == "root.json" || name == "writer.lock" { continue }
      if name == "batch-format.json" || name.hasPrefix("batch-decisions-")
        || name.hasPrefix("batch-attempt-") || name.hasPrefix("batch-draft-")
        || name.hasPrefix("batch-receipt-")
      {
        continue
      }
      if name.hasPrefix("attempt-") || name.hasPrefix("detach-") { continue }
      let prefixes = ["candidate-", "rejected-", "deferred-", "outcome-"]
      guard let prefix = prefixes.first(where: name.hasPrefix), name.hasSuffix(".json") else {
        throw DreamRunError.corruption
      }
      let id = String(name.dropFirst(prefix.count).dropLast(5))
      guard loaded[id] != nil else {
        throw DreamRunError.nativeReviewLimitation(
          "admitted candidate lacks verified completion: \(id)")
      }
    }
    for (id, (_, admission, _)) in loaded {
      try root.installReviewFile(
        MemoryReviewEncoding.encode(admission), name: "candidate-\(id).json",
        fault: persistenceFault, io: fileIO)
    }
    candidates = loaded
    try recoverApprovals()
    try recoverBatches()
  }

  private func currentTarget(
    _ change: AtomicMemoryChange,
    currentSnapshot: inout ApprovedDecisionSnapshot?,
    frozenSnapshot: inout ApprovedDecisionSnapshot?
  ) throws -> (
    snapshot: ApprovedDecisionSnapshot, bytes: Data, range: Range<Int>,
    locator: MemoryDocument.EntryLocator?
  ) {
    let base = try store.approvedCommit()
    if currentSnapshot?.base != base {
      currentSnapshot = try store.reviewSnapshot(base: base)
    }
    let snapshot = currentSnapshot!
    if frozenSnapshot?.base != change.base {
      frozenSnapshot =
        change.base == base ? snapshot : try store.reviewSnapshot(base: change.base)
    }
    let frozen = frozenSnapshot!
    let original = frozen.documents.first(where: { $0.path == change.path })?.bytes
    guard change.documentHash == original.map(SourceDigest.init(bytes:)) else {
      throw MemoryError("frozen target document changed")
    }
    let bytes = snapshot.documents.first(where: { $0.path == change.path })?.bytes ?? Data()
    var range = change.locator.map { $0.start..<$0.end }
    if candidates[change.id.rawValue]?.1.recoveryCheckpointHash != nil {
      return try Self.recoveredTarget(change, frozen: frozen, snapshot: snapshot)
    }
    let publications = try verifiedPublications(from: change.base, to: base)
    if let target = range {
      range = try MemoryBatchComposition.transformed(
        target, path: change.path, publications: publications)
    }
    _ = try batchAnchors(change, snapshot: snapshot, publications: publications)
    switch change.operation {
    case .add:
      return (snapshot, bytes, bytes.count..<bytes.count, nil)
    case .update:
      guard let range, let before = change.before, range.lowerBound >= 0,
        range.upperBound <= bytes.count, Data(bytes[range]) == before,
        let entry = snapshot.reviewEntries().first(where: {
          $0.path == change.path && $0.entry.locator.start == range.lowerBound
            && $0.entry.locator.end == range.upperBound
        })?.entry,
        entry.isMutable, entry.identity == change.entryID
      else { throw MemoryError("selected native entry changed or is ambiguous") }
      return (snapshot, bytes, range, entry.locator)
    }
  }

  func recoverApprovals() throws {
    let git = store.reviewGit
    let limits = try DreamDecisionLimits()
    let attempts = try root.names().filter { $0.hasPrefix("attempt-") }
    let objects = try attempts.isEmpty ? nil : ReviewGitObjects(git: git)
    defer { objects?.close() }
    var snapshots: [String: ApprovedDecisionSnapshot] = [:]
    var retainedBytes = 0
    func snapshot(_ base: String) throws -> ApprovedDecisionSnapshot {
      if let value = snapshots[base] { return value }
      let value = try store.reviewSnapshot(base: base, objects: objects)
      guard snapshots.count < limits.maximumLayoutEntries else { return value }
      let available = limits.maximumSnapshotBytes - retainedBytes
      var size = value.layoutByteCount
      guard size <= available else { return value }
      for document in value.documents {
        let count = document.bytes?.count ?? 0
        guard count <= available - size else { return value }
        size += count
      }
      snapshots[base] = value
      retainedBytes += size
      return value
    }
    var recovered: [String: ReviewAttempt] = [:]
    for name in attempts {
      let attempt = try MemoryReviewEncoding.decode(
        ReviewAttempt.self, bytes: root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
      guard attempt.schemaVersion == 1, name == "attempt-\(attempt.previewHash).json",
        attempt.previewHash
          == SourceDigest(bytes: try MemoryReviewEncoding.encode(attempt.preview)).rawValue,
        attempt.auditRef == "refs/memory-review/approvals/\(attempt.previewHash)",
        candidates[attempt.preview.candidateID] != nil,
        Self.isCommitID(attempt.resultCommit), Self.isCommitID(attempt.resultTree)
      else { throw DreamRunError.corruption }
      guard let actual = try directAudit(attempt.auditRef, objects: objects) else { continue }
      guard actual == attempt.resultCommit else { throw DreamRunError.corruption }
      try validatePayload(attempt.preview, loadSnapshot: snapshot)
      let raw = try objects!.contents(
        actual, type: "commit", maximumBytes: MemoryReviewEncoding.maximumStateBytes)
      guard let text = String(data: raw, encoding: .utf8), let separator = text.range(of: "\n\n")
      else {
        throw DreamRunError.corruption
      }
      let header = text[..<separator.lowerBound].split(separator: "\n")
      let parents = header.filter { $0.hasPrefix("parent ") }.map { String($0.dropFirst(7)) }
      guard parents == [attempt.preview.currentBase],
        header.filter({ $0.hasPrefix("tree ") }).map({ String($0.dropFirst(5)) }) == [
          attempt.resultTree
        ],
        try Data(text[separator.upperBound...].utf8) == Self.approvalMessage(attempt.preview),
        try git.text(["rev-parse", "\(actual)^{tree}"]) == attempt.resultTree,
        try git.committedChangedPathBytes(from: attempt.preview.currentBase, to: actual)
          == Data((attempt.preview.path + "\0").utf8)
      else { throw DreamRunError.corruption }
      let result = try snapshot(actual)
      guard let document = result.documents.first(where: { $0.path == attempt.preview.path }),
        document.mode == "100644", document.bytes == attempt.preview.replacement,
        result.reviewEntries().filter({ $0.entry.identity == attempt.preview.identity }).count == 1,
        result.reviewEntries().first(where: { $0.entry.identity == attempt.preview.identity })?
          .entry.isMutable == true,
        recovered[attempt.preview.candidateID] == nil
      else { throw DreamRunError.corruption }
      recovered[attempt.preview.candidateID] = attempt
    }
    for name in try root.names() where name.hasPrefix("outcome-") {
      let value = try MemoryReviewEncoding.decode(
        ReviewAttempt.self, bytes: root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
      guard name == "outcome-\(value.preview.candidateID).json",
        recovered[value.preview.candidateID] == value
      else { throw DreamRunError.corruption }
    }
    for (id, attempt) in recovered {
      try root.installReviewFile(
        MemoryReviewEncoding.encode(attempt), name: "outcome-\(id).json", fault: persistenceFault,
        io: fileIO)
    }
    approvals = recovered
    try indexLegacyPublications()
    try recoverDetach()
  }

  func validatePayload(
    _ payload: ReviewPreviewPayload,
    loadSnapshot: ((String) throws -> ApprovedDecisionSnapshot)? = nil
  ) throws {
    guard let (change, admission, _) = candidates[payload.candidateID],
      payload.admissionHash
        == SourceDigest(bytes: try MemoryReviewEncoding.encode(admission)).rawValue,
      payload.path == change.path, payload.frozenBase == change.base,
      Self.isCommitID(payload.currentBase),
      payload.identity == (try change.entryID ?? Self.assignedIdentity(payload.candidateID))
    else { throw DreamRunError.corruption }
    let intent = MemoryBatchCandidateIntent(
      candidateID: payload.candidateID, admissionHash: payload.admissionHash, choice: .accept,
      identity: payload.identity, instant: payload.instant, amendment: payload.amendment)
    let original = try MemoryDocument.reviewedBytes(
      change.after, identity: payload.identity, instant: payload.instant)
    guard try payload.after == Self.amendedBatchBytes(intent, proposal: original, before: payload.before)
    else { throw DreamRunError.corruption }
    let snapshot =
      try loadSnapshot?(payload.currentBase)
      ?? store.reviewSnapshot(base: payload.currentBase)
    let bytes = snapshot.documents.first(where: { $0.path == payload.path })?.bytes ?? Data()
    guard payload.originalDocument == bytes,
      payload.start >= 0, payload.end >= payload.start, payload.end <= bytes.count,
      Data(bytes[payload.start..<payload.end]) == payload.before
    else { throw DreamRunError.corruption }
    if admission.recoveryCheckpointHash != nil {
      let frozen = try loadSnapshot?(change.base) ?? store.reviewSnapshot(base: change.base)
      let target = try Self.recoveredTarget(change, frozen: frozen, snapshot: snapshot)
      guard target.range == payload.start..<payload.end else { throw DreamRunError.corruption }
    }
    switch change.operation {
    case .add:
      guard payload.start == bytes.count, payload.end == bytes.count, payload.before.isEmpty else {
        throw DreamRunError.corruption
      }
    case .update:
      guard payload.before == change.before,
        let entry = snapshot.reviewEntries().first(where: {
          $0.path == payload.path && $0.entry.locator.start == payload.start
            && $0.entry.locator.end == payload.end
        })?.entry, entry.isMutable, entry.identity == change.entryID
      else { throw DreamRunError.corruption }
    }
    guard
      !snapshot.reviewEntries().contains(where: {
        $0.entry.identity == payload.identity
          && !($0.path == payload.path && $0.entry.locator.start == payload.start
            && $0.entry.locator.end == payload.end)
      })
    else { throw DreamRunError.corruption }
    var replacement = bytes
    let insertion =
      change.operation == .add ? Self.addSeparator(bytes) + payload.after : payload.after
    replacement.replaceSubrange(payload.start..<payload.end, with: insertion)
    guard replacement == payload.replacement, MemoryDocument.failures(in: replacement).isEmpty,
      MemoryDocument.entries(in: replacement).first(where: { $0.identity == payload.identity })?
        .bytes == payload.after
    else { throw DreamRunError.corruption }
  }

  static func recoveredTarget(
    _ change: AtomicMemoryChange, frozen: ApprovedDecisionSnapshot,
    snapshot: ApprovedDecisionSnapshot
  ) throws -> (
    snapshot: ApprovedDecisionSnapshot, bytes: Data, range: Range<Int>,
    locator: MemoryDocument.EntryLocator?
  ) {
    let original = frozen.documents.first(where: { $0.path == change.path })?.bytes
    guard change.path == change.scope.path,
      original.map(SourceDigest.init(bytes:)) == change.documentHash
    else { throw MemoryError("frozen target document changed") }
    let document = snapshot.documents.first(where: { $0.path == change.path })
    if let document {
      guard document.mode == "100644", document.diagnostics.isEmpty else {
        throw MemoryError("current memory document cannot be changed safely")
      }
    }
    let entries = snapshot.reviewEntries()
    let frozenEntries = frozen.reviewEntries()
    func exactEntry(path: String, original: MemoryDocument.MemoryEntry) throws
      -> MemoryDocument.MemoryEntry
    {
      let matches = entries.filter {
        $0.path == path && $0.entry.identity == original.identity && $0.entry.bytes == original.bytes
      }
      guard let document = snapshot.documents.first(where: { $0.path == path }),
        document.mode == "100644", document.diagnostics.isEmpty,
        original.isMutable, matches.count == 1, matches[0].entry.isMutable else {
        throw MemoryError("selected memory changed or is ambiguous")
      }
      return matches[0].entry
    }
    for contradiction in change.contradictions {
      guard case .memory(let anchor, _) = contradiction else { continue }
      guard let document = frozen.documents.first(where: { $0.path == anchor.scope.path }),
        document.digest == anchor.documentHash,
        let entry = frozenEntries.first(where: {
          $0.path == anchor.scope.path && $0.entry.locator.start == anchor.start
            && $0.entry.locator.end == anchor.end && $0.entry.bytes == Data(anchor.before.utf8)
        })?.entry
      else { throw MemoryError("frozen contradiction anchor changed") }
      _ = try exactEntry(path: anchor.scope.path, original: entry)
    }
    let bytes = document?.bytes ?? Data()
    switch change.operation {
    case .add:
      let identity = try change.entryID ?? assignedIdentity(change.id.rawValue)
      guard !entries.contains(where: { $0.entry.identity == identity }) else {
        throw MemoryError("memory identity is already in use")
      }
      return (snapshot, bytes, bytes.count..<bytes.count, nil)
    case .update:
      guard let locator = change.locator, let before = change.before,
        let entry = frozenEntries.first(where: {
          $0.path == change.path && $0.entry.locator == locator
            && $0.entry.bytes == before && $0.entry.identity == change.entryID
        })?.entry
      else { throw MemoryError("frozen target entry changed") }
      let current = try exactEntry(path: change.path, original: entry)
      return (snapshot, bytes, current.locator.start..<current.locator.end, current.locator)
    }
  }

  private func directAudit(_ ref: String, objects: ReviewGitObjects? = nil) throws -> String? {
    let git = store.reviewGit
    guard try git.run(["symbolic-ref", "--quiet", ref]).status == 1 else {
      throw DreamRunError.corruption
    }
    let result = try git.run(["rev-parse", "--verify", "--quiet", ref])
    if result.status == 1 { return nil }
    guard result.status == 0 else { throw DreamRunError.corruption }
    let commit = result.text.trimmingCharacters(in: .newlines)
    guard Self.isCommitID(commit),
      try (objects?.info(commit).type ?? git.text(["cat-file", "-t", commit])) == "commit"
    else {
      throw DreamRunError.corruption
    }
    return commit
  }

  private func recordDetach(_ attempt: ReviewDetachAttempt) throws {
    let git = store.reviewGit
    if let actual = try directAudit(attempt.auditRef) {
      guard actual == attempt.witness.commit else { throw DreamRunError.corruption }
    } else {
      let result = try git.directRefTransaction(
        "create \(attempt.auditRef) \(attempt.witness.commit)\n", refs: [attempt.auditRef],
        isolatedHead: attempt.witness.commit)
      guard result.status == 0 else { throw DreamRunError.persistenceFailure }
    }
    try root.installReviewFile(
      MemoryReviewEncoding.encode(attempt), name: "detach-outcome-\(attempt.digest).json",
      fault: persistenceFault, io: fileIO)
  }

  private func recoverDetach() throws {
    for name in try root.names() where name.hasPrefix("detach-attempt-") {
      let attempt = try MemoryReviewEncoding.decode(
        ReviewDetachAttempt.self,
        bytes: root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
      guard attempt.schemaVersion == 1, name == "detach-attempt-\(attempt.digest).json",
        attempt.digest
          == SourceDigest(bytes: try MemoryReviewEncoding.encode(attempt.witness)).rawValue,
        attempt.auditRef == "refs/memory-review/detach/\(attempt.digest)",
        attempt.witness.head == Data("ref: refs/heads/main\n".utf8),
        Self.isCommitID(attempt.witness.commit)
      else { throw DreamRunError.corruption }
      if let actual = try directAudit(attempt.auditRef) {
        guard actual == attempt.witness.commit else { throw DreamRunError.corruption }
        try root.installReviewFile(
          MemoryReviewEncoding.encode(attempt), name: "detach-outcome-\(attempt.digest).json",
          fault: persistenceFault, io: fileIO)
      } else {
        let checkout = try store.reviewGit.reviewCheckout()
        let witness = try checkout.witness()
        if witness.head == Data((attempt.witness.commit + "\n").utf8),
          witness.gitDevice == attempt.witness.gitDevice,
          witness.gitInode == attempt.witness.gitInode,
          witness.index == attempt.witness.index, witness.config == attempt.witness.config,
          witness.sharedIndexes == attempt.witness.sharedIndexes
        {
          try recordDetach(attempt)
        }
      }
    }
    for name in try root.names() where name.hasPrefix("detach-outcome-") {
      let attempt = try MemoryReviewEncoding.decode(
        ReviewDetachAttempt.self,
        bytes: root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
      guard name == "detach-outcome-\(attempt.digest).json",
        try root.read(
          "detach-attempt-\(attempt.digest).json", maximum: MemoryReviewEncoding.maximumFileBytes)
          == MemoryReviewEncoding.encode(attempt),
        try directAudit(attempt.auditRef) == attempt.witness.commit
      else { throw DreamRunError.corruption }
    }
  }

  static func approvalMessage(_ payload: ReviewPreviewPayload) throws -> Data {
    Data("Core memory native review\n\n".utf8) + (try MemoryReviewEncoding.encode(payload))
      + Data("\n".utf8)
  }

  private static func isCommitID(_ value: String) -> Bool {
    MemoryDocument.isMatch(#"\A([0-9a-f]{40}|[0-9a-f]{64})\z"#, value)
  }

  private func verifyBinding() throws {
    try root.verifyLock(writer)
    var repoStatus = stat()
    var stateStatus = stat()
    var heldState = stat()
    guard lstat(repository.path, &repoStatus) == 0, lstat(stateURL.path, &stateStatus) == 0,
      fstat(root.descriptor, &heldState) == 0,
      repoStatus.st_mode & S_IFMT == S_IFDIR, stateStatus.st_mode & S_IFMT == S_IFDIR,
      repoStatus.st_dev == repositoryDevice,
      UInt64(repoStatus.st_ino) == binding.repositoryInode,
      stateStatus.st_dev == stateDevice, heldState.st_dev == stateStatus.st_dev,
      heldState.st_ino == stateStatus.st_ino,
      UInt64(stateStatus.st_ino) == binding.stateInode,
      try MemoryReviewEncoding.volumeUUID(at: repository) == binding.repositoryVolumeUUID,
      try MemoryReviewEncoding.volumeUUID(at: stateURL) == binding.stateVolumeUUID,
      try sources.reviewSourceBinding().rawValue == binding.sourceBinding,
      try root.read("root.json", maximum: MemoryReviewEncoding.maximumFileBytes)
        == MemoryReviewEncoding.encode(binding)
    else { throw DreamRunError.unsafeState }
    try MemoryQueueAuthority.verifyReview(git: store.reviewGit, review: binding)
    _ = try root.retainedBytes(maximum: MemoryReviewEncoding.maximumStateBytes)
  }

  func withBatchOwnership<T>(_ operation: () throws -> T) throws -> T {
    guard operationLock.try() else { throw DreamRunError.busy }
    defer { operationLock.unlock() }
    return try operation()
  }

  func withBatchSources<T>(state: DreamStateDirectory, _ operation: () throws -> T) throws -> T {
    try sources.withVerifiedReviewCandidates { bundles in
      checkoutState = state
      defer { checkoutState = nil }
      try refresh(bundles: bundles)
      return try operation()
    }
  }

  func locked<T>(_ operation: () throws -> T) throws -> T {
    guard operationLock.try() else { throw DreamRunError.busy }
    defer { operationLock.unlock() }
    return try store.reviewGit.reviewCheckout().withLeaseState { state in
      checkoutState = state
      defer { checkoutState = nil }
      return try operation()
    }
  }

  static func assignedIdentity(_ id: String) throws -> UUID {
    let hex = String(
      SourceDigest(bytes: Data(("memory-review-entry:" + id).utf8)).rawValue.prefix(32))
    let parts = [
      hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
      hex.dropFirst(16).prefix(4), hex.dropFirst(20),
    ]
    guard let identity = UUID(uuidString: parts.map(String.init).joined(separator: "-")) else {
      throw DreamRunError.corruption
    }
    return identity
  }

  private static func addSeparator(_ bytes: Data) -> Data {
    Data(
      (bytes.isEmpty ? "# Memory\n\n" : (bytes.last == 10 || bytes.last == 13 ? "\n" : "\n\n")).utf8
    )
  }

  private static func isWithin(_ path: URL, _ parent: URL) -> Bool {
    path.path == parent.path || path.path.hasPrefix(parent.path + "/")
  }
}
