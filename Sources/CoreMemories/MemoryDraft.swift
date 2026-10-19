import Darwin
import Foundation

package struct MemoryDraft: Codable, Sendable {
  package let schemaVersion: Int
  package let draftID: UUID
  package let revision: UInt64
  package let repositoryBinding: String
  package let baseCommit: String
  package let created: Date
  package let operations: [MemoryManagementRequest]
  package let batch: MemoryBatchContents?
}

package struct MemoryDraftReceipt: Codable, Sendable {
  package let draftID: UUID
  package let revision: UInt64
  package let contentDigest: String
  package let base: String
  package let commit: String
  package let auditRef: String
}

package struct MemoryDraftRecovery: Sendable {
  package let draftID: UUID
  package let revision: UInt64
  package let created: Date
  package let failure: MemoryBatchRecoveryRequired
}

package struct MemoryDraftInspection: Sendable {
  package let drafts: [MemoryDraft]
  package let recoveryRequired: [MemoryDraftRecovery]
}

private struct DraftPublication: Codable {
  let schemaVersion: Int
  let draft: MemoryDraft
  let contentDigest: String
  let idempotencyKey: String
  let changes: [Data]
}

package final class MemoryDraftStore {
  let root: DreamStateDirectory
  package let journal: URL
  private let repository: URL
  private let binding: String
  let store: MemoryStore
  private let git: Git
  var beforePublication: (() throws -> Void)?
  var afterPublication: (() throws -> Void)?
  var batchPersistenceFault: ((MemoryReviewPersistenceEvent) throws -> Void)?

  package init(repository: URL, journal: URL) throws {
    let environment = ProcessInfo.processInfo.environment
    self.store = try MemoryStore(repo: repository, environment: environment)
    self.git = store.reviewGit
    self.repository = repository
    self.journal = journal
    guard !journal.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      !journal.path.hasPrefix(repository.path + "/"), journal.path != repository.path
    else { throw DreamRunError.unsafeState }
    var ancestor = journal
    while !FileManager.default.fileExists(atPath: ancestor.path) {
      guard ancestor.path != "/" else { throw DreamRunError.unsafeState }
      ancestor.deleteLastPathComponent()
    }
    guard try Git(repo: ancestor, environment: environment).commonDirectory() == nil else {
      throw DreamRunError.unsafeState
    }
    var status = stat()
    guard lstat(repository.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
      throw DreamRunError.unsafeState
    }
    binding =
      SourceDigest(
        bytes: Data("\(repository.path)\0\(status.st_dev)\0\(status.st_ino)".utf8)
      ).rawValue
    root = try DreamStateDirectory.openRoot(journal)
    try locked {
      try root.installReviewFile(Data(binding.utf8), name: "repository")
    }
  }

  package func create(base: String? = nil, operations: [MemoryManagementRequest] = []) throws
    -> MemoryDraft
  {
    try locked {
      let draft = try prepareDraft(base: base, operations: operations)
      try persist(draft)
      return draft
    }
  }

  func prepareDraft(base: String? = nil, operations: [MemoryManagementRequest] = []) throws
    -> MemoryDraft
  {
    let acceptedBase = try base ?? store.approvedCommit()
    guard operations.count <= 256, operations.allSatisfy({ $0.base == acceptedBase }) else {
      throw MemoryError("draft operations must use the selected base")
    }
    _ = try store.reviewSnapshot(base: acceptedBase)
    return MemoryDraft(
      schemaVersion: 1, draftID: UUID(), revision: 0, repositoryBinding: binding,
      baseCommit: acceptedBase, created: Date(), operations: operations, batch: nil)
  }

  func persistPreparedDraft(_ draft: MemoryDraft) throws {
    try locked {
      guard draft.schemaVersion == 1, draft.repositoryBinding == binding, Self.isValid(draft) else {
        throw DreamRunError.corruption
      }
      try persist(draft)
    }
  }

  package func list(review: MemoryReviewController? = nil) throws -> [MemoryDraft] {
    if let review {
      return try withBatchJournal(review) { _ in try drafts(review: review) }
    }
    return try locked { try drafts() }
  }

  package func inspectDrafts(review: MemoryReviewController? = nil) throws -> MemoryDraftInspection
  {
    func inspect() throws -> MemoryDraftInspection {
      var recoveryRequired: [MemoryDraftRecovery] = []
      let available = try drafts(review: review) { draft, failure in
        recoveryRequired.append(
          MemoryDraftRecovery(
            draftID: draft.draftID, revision: draft.revision, created: draft.created,
            failure: failure))
      }
      return MemoryDraftInspection(
        drafts: available,
        recoveryRequired: recoveryRequired.sorted { $0.created < $1.created })
    }
    if let review {
      return try withBatchJournal(review) { _ in try inspect() }
    }
    return try locked { try inspect() }
  }

  package func recoveryDetails(_ recovery: MemoryDraftRecovery) throws -> MemoryDraft {
    try locked {
      let draft = try read(recovery.draftID, revision: recovery.revision)
      guard try memoryBatchDigest(draft) == recovery.failure.saveID else {
        throw MemoryError("recovery record changed; refresh the workspace")
      }
      return draft
    }
  }

  package func update(
    draftID: UUID, expectedRevision: UInt64, operations: [MemoryManagementRequest]
  ) throws -> MemoryDraft {
    try locked {
      let previous = try current(draftID, revision: expectedRevision)
      guard previous.batch == nil else {
        throw MemoryError("typed batches must be edited through the memory batch session")
      }
      guard expectedRevision < UInt64.max, operations.count <= 256 else {
        throw DreamRunError.limitExceeded
      }
      if try DreamRunEncoding.encode(operations) == DreamRunEncoding.encode(previous.operations) {
        return previous
      }
      let draft = MemoryDraft(
        schemaVersion: 1, draftID: draftID, revision: expectedRevision + 1,
        repositoryBinding: binding, baseCommit: previous.baseCommit,
        created: previous.created, operations: operations, batch: nil)
      try persist(draft)
      return draft
    }
  }

  package func discard(draftID: UUID, expectedRevision: UInt64) throws {
    try locked {
      _ = try current(draftID, revision: expectedRevision)
      try root.installReviewFile(Data(), name: "\(draftID.uuidString)-discarded")
    }
  }

  package func recoverSave(draftID: UUID, expectedRevision: UInt64, idempotencyKey: String)
    throws -> MemoryDraftReceipt?
  {
    try locked {
      let draft = try current(draftID, revision: expectedRevision)
      guard draft.batch == nil else {
        throw MemoryError("typed batches require the proof-aware batch recovery")
      }
      return try recover(draft: draft, idempotencyKey: idempotencyKey)
    }
  }

  package func save(draftID: UUID, expectedRevision: UInt64, idempotencyKey: String) throws
    -> MemoryDraftReceipt
  {
    try locked {
      let draft = try read(draftID, revision: expectedRevision)
      guard draft.batch == nil else {
        throw MemoryError("typed batches require the proof-aware batch Save")
      }
      try root.installReviewFile(
        DreamRunEncoding.encode(draft), name: "\(draftID.uuidString)-\(expectedRevision).json")
      if let receipt = try recover(draft: draft, idempotencyKey: idempotencyKey) {
        return receipt
      }
      let digest = SourceDigest(bytes: try DreamRunEncoding.encode(draft)).rawValue
      let auditRef = saveAuditRef(draftID: draftID, idempotencyKey: idempotencyKey)
      _ = try current(draftID, revision: expectedRevision)
      guard try store.approvedCommit() == draft.baseCommit else {
        throw MemoryError(
          "draft base changed; preserve this draft and reconcile against a new catalog")
      }
      let (replacements, changes) = try compose(draft)
      let publication = DraftPublication(
        schemaVersion: 1, draft: draft, contentDigest: digest, idempotencyKey: idempotencyKey,
        changes: changes.map(\.audit))
      let message =
        Data("Core memory draft Save\n\n".utf8)
        + (try DreamRunEncoding.encode(publication)) + Data([10])
      let checkout = try git.reviewCheckout()
      return try checkout.withLeaseState { state in
        let witness = try checkout.witness()
        guard witness.head == Data((witness.commit + "\n").utf8), witness.main == draft.baseCommit
        else {
          throw MemoryError("Save requires the unchanged base and a prepared detached checkout")
        }
        try checkout.lock(state: state, detachedHead: witness.head)
        guard try checkout.witness(isLocked: true) == witness else {
          throw MemoryError("checkout changed during Save")
        }
        let commit = try store.reviewCommit(
          base: draft.baseCommit, replacements: replacements, message: message)
        let final = try store.reviewSnapshot(base: commit)
        let identities = final.reviewEntries().compactMap { $0.entry.identity }
        guard Set(identities).count == identities.count else {
          throw MemoryError("duplicate memory identity in final store")
        }
        try beforePublication?()
        try store.publishCheckedMemoryCommit(
          commit: commit, base: draft.baseCommit, auditRef: auditRef, checkout: witness)
        try afterPublication?()
        return MemoryDraftReceipt(
          draftID: draftID, revision: expectedRevision, contentDigest: digest,
          base: draft.baseCommit, commit: commit, auditRef: auditRef)
      }
    }
  }

  private func compose(_ draft: MemoryDraft) throws -> ([String: Data], [PreparedManagementChange])
  {
    let snapshot = try store.reviewSnapshot(base: draft.baseCommit)
    let manager = try MemoryManagement(repository: repository)
    var changes: [PreparedManagementChange] = []
    for (index, operation) in draft.operations.enumerated() {
      guard [.add, .update, .delete].contains(operation.operation),
        operation.base == draft.baseCommit
      else { throw MemoryError("draft contains a non-CRUD operation or a foreign base") }
      let hex = SourceDigest(bytes: Data("\(draft.draftID):\(index)".utf8)).rawValue
      let raw = Array(hex.prefix(32))
      let id =
        String(raw[0..<8]) + "-" + String(raw[8..<12]) + "-"
        + String(raw[12..<16]) + "-" + String(raw[16..<20]) + "-" + String(raw[20..<32])
      changes.append(
        try manager.prepare(
          operation, snapshot: snapshot, date: draft.created, newIdentity: UUID(uuidString: id)!))
    }
    var replacements: [String: Data] = [:]
    for path in Set(changes.map(\.path)) {
      var document = snapshot.documents.first { $0.path == path }?.bytes ?? Data("# Memory\n".utf8)
      let edits = changes.filter { $0.path == path }
      let targets = edits.filter { !$0.range.isEmpty }.sorted {
        $0.range.lowerBound < $1.range.lowerBound
      }
      for pair in zip(targets, targets.dropFirst()) {
        guard pair.0.range.upperBound <= pair.1.range.lowerBound else {
          throw MemoryError("overlapping draft targets")
        }
      }
      for edit in targets.reversed() {
        document.replaceSubrange(edit.range, with: edit.insertion)
      }
      for edit in edits where edit.range.isEmpty {
        let separator =
          document.isEmpty || document.suffix(2) == Data([10, 10])
          ? Data()
          : document.last == 10 ? Data([10]) : Data([10, 10])
        let original =
          snapshot.documents.first { $0.path == path }?.bytes ?? Data("# Memory\n".utf8)
        let prefixCount =
          original.isEmpty || original.suffix(2) == Data([10, 10]) ? 0 : original.last == 10 ? 1 : 2
        document.append(separator)
        document.append(edit.insertion.dropFirst(prefixCount))
      }
      guard document.count <= 1_048_576 else { throw DreamRunError.limitExceeded }
      let failures = MemoryDocument.failures(in: document)
      guard failures.isEmpty else { throw MemoryError(failures.joined(separator: "; ")) }
      replacements[path] = document
    }
    return (replacements, changes)
  }

  private func saveAuditRef(draftID: UUID, idempotencyKey: String) -> String {
    "refs/memory-management/drafts/"
      + SourceDigest(bytes: Data("\(binding)\0\(draftID)\0\(idempotencyKey)".utf8)).rawValue
  }

  private func recover(draft: MemoryDraft, idempotencyKey: String) throws -> MemoryDraftReceipt? {
    guard !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 256,
      !idempotencyKey.contains("\0"), !draft.operations.isEmpty
    else { throw MemoryError("Save requires changes and a bounded idempotency key") }
    let digest = SourceDigest(bytes: try DreamRunEncoding.encode(draft)).rawValue
    let auditRef = saveAuditRef(draftID: draft.draftID, idempotencyKey: idempotencyKey)
    let refs = try git.text([
      "for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)", auditRef,
    ])
    let exact = refs.split(separator: "\n").filter { $0.hasPrefix(auditRef + "\0") }
    if exact.isEmpty {
      guard refs.isEmpty else { throw MemoryError("Save receipt must be an exact direct ref") }
      return nil
    }
    guard exact.count == 1 else { throw DreamRunError.corruption }
    let fields = exact[0].split(separator: "\0", omittingEmptySubsequences: false)
    guard fields.count == 3, fields[2].isEmpty, MemoryStore.isFullOID(String(fields[1])) else {
      throw MemoryError("Save receipt must be an exact direct ref")
    }
    let commit = String(fields[1])
    let raw = try git.data(["cat-file", "commit", commit])
    guard let split = raw.range(of: Data([10, 10])) else { throw DreamRunError.corruption }
    let parents = String(decoding: raw[..<split.lowerBound], as: UTF8.self)
      .split(separator: "\n").filter { $0.hasPrefix("parent ") }
    guard parents == [Substring("parent " + draft.baseCommit)] else {
      throw DreamRunError.corruption
    }
    let bytes = Data(raw[split.upperBound...])
    let prefix = Data("Core memory draft Save\n\n".utf8)
    guard bytes.starts(with: prefix) else { throw DreamRunError.corruption }
    let publication = try JSONDecoder().decode(
      DraftPublication.self, from: bytes.dropFirst(prefix.count))
    let (replacements, changes) = try compose(draft)
    let expected = DraftPublication(
      schemaVersion: 1, draft: draft, contentDigest: digest, idempotencyKey: idempotencyKey,
      changes: changes.map(\.audit))
    guard try DreamRunEncoding.encode(publication) == DreamRunEncoding.encode(expected) else {
      throw MemoryError("idempotency key already used for different draft content")
    }
    let before = try store.reviewSnapshot(base: draft.baseCommit)
    let after = try store.reviewSnapshot(base: commit)
    var layout = Dictionary(
      uniqueKeysWithValues: before.layoutEntries.map { ($0.path, ($0.mode, $0.blob)) })
    for (path, replacement) in replacements {
      layout[path] = (
        "100644", try git.text(["hash-object", "--stdin", "--no-filters"], input: replacement)
      )
    }
    guard after.layoutEntries.count == layout.count,
      after.layoutEntries.allSatisfy({ entry in
        layout[entry.path].map { $0.0 == entry.mode && $0.1 == entry.blob } ?? false
      })
    else { throw MemoryError("Save receipt tree differs from the saved draft") }
    guard try MemoryBatchReplay.isAncestor(commit, of: store.approvedCommit(), git: git) else {
      throw MemoryError("Save receipt is absent from approved history")
    }
    return MemoryDraftReceipt(
      draftID: draft.draftID, revision: draft.revision, contentDigest: digest,
      base: draft.baseCommit, commit: commit, auditRef: auditRef)
  }

  package func persistBatch(_ draft: MemoryDraft, expectedRevision: UInt64) throws {
    try locked {
      guard Self.isValid(draft), draft.schemaVersion == 2,
        draft.repositoryBinding == binding, draft.revision >= expectedRevision
      else { throw DreamRunError.corruption }
      let previous = try current(draft.draftID, revision: expectedRevision)
      guard previous.baseCommit == draft.baseCommit, previous.created == draft.created else {
        throw DreamRunError.corruption
      }
      if previous.revision == draft.revision {
        guard try memoryBatchDigest(previous) == memoryBatchDigest(draft) else {
          throw MemoryError("a different draft revision is already durable")
        }
        return
      }
      if previous.schemaVersion == 1 {
        try root.installReviewFile(
          DreamRunEncoding.encode(previous),
          name: "\(previous.draftID.uuidString)-\(previous.revision).json")
      }
      try persist(draft)
    }
  }

  private static func isValid(_ draft: MemoryDraft) -> Bool {
    guard MemoryStore.isFullOID(draft.baseCommit), draft.created.timeIntervalSince1970.isFinite,
      draft.operations.count <= 256
    else { return false }
    if draft.schemaVersion == 1 { return draft.batch == nil }
    guard draft.schemaVersion == 2, draft.operations.isEmpty, let batch = draft.batch,
      batch.items.count <= 256,
      Set(batch.items.map(\.itemID)).count == batch.items.count,
      batch.binding.allowedPaths.count <= MemoryBatchBinding.maximumAllowedPaths,
      batch.binding.allowedPaths.allSatisfy(MemoryDocument.isAllowedPath)
    else { return false }
    return true
  }

  func persist(_ draft: MemoryDraft) throws {
    try root.installReviewFile(
      DreamRunEncoding.encode(draft), name: "\(draft.draftID.uuidString)-current.json",
      isReplacing: true, fault: batchPersistenceFault)
  }

  func drafts(
    only draftID: UUID? = nil, review: MemoryReviewController? = nil,
    recoveryRequired: ((MemoryDraft, MemoryBatchRecoveryRequired) -> Void)? = nil
  ) throws -> [MemoryDraft] {
    let names = try root.names()
    var latest: [UUID: MemoryDraft] = [:]
    for name in names where name.hasSuffix("-current.json") {
      if let draftID, name != "\(draftID.uuidString)-current.json" { continue }
      let bytes = try root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes)
      let draft = try JSONDecoder().decode(MemoryDraft.self, from: bytes)
      if draft.schemaVersion == 2 {
        guard try MemoryReviewEncoding.encode(draft) == bytes else {
          throw DreamRunError.corruption
        }
      }
      guard Self.isValid(draft), draft.repositoryBinding == binding,
        name == "\(draft.draftID.uuidString)-current.json"
      else { throw DreamRunError.corruption }
      if names.contains("\(draft.draftID.uuidString)-discarded") { continue }
      if draft.batch != nil {
        let saveID = try memoryBatchDigest(draft)
        let receiptName = "batch-receipt-\(saveID).json"
        if names.contains(receiptName) {
          let receipt = try MemoryReviewEncoding.decode(
            MemoryBatchReceipt.self,
            bytes: root.read(receiptName, maximum: MemoryReviewEncoding.maximumFileBytes))
          guard receipt.saveID == saveID, receipt.draftID == draft.draftID,
            receipt.revision == draft.revision, receipt.base == draft.baseCommit
          else { throw DreamRunError.corruption }
          do {
            try verifyBatchConsumption(
              draft, receipt: receipt, review: review, isReadOnly: recoveryRequired != nil)
          } catch let failure as MemoryBatchRecoveryRequired {
            guard let recoveryRequired else { throw failure }
            recoveryRequired(draft, failure)
          }
          continue
        }
      }
      if latest[draft.draftID].map({ $0.revision < draft.revision }) ?? true {
        latest[draft.draftID] = draft
      }
    }
    return latest.values.sorted { $0.created < $1.created }
  }

  func read(_ id: UUID, revision: UInt64) throws -> MemoryDraft {
    let archived = "\(id.uuidString)-\(revision).json"
    let name = try root.isPresent(archived) ? archived : "\(id.uuidString)-current.json"
    let bytes = try root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes)
    let draft = try JSONDecoder().decode(MemoryDraft.self, from: bytes)
    if draft.schemaVersion == 2 {
      guard try MemoryReviewEncoding.encode(draft) == bytes else { throw DreamRunError.corruption }
    }
    guard Self.isValid(draft), draft.repositoryBinding == binding,
      draft.draftID == id, draft.revision == revision
    else { throw DreamRunError.corruption }
    return draft
  }

  private func current(_ id: UUID, revision: UInt64) throws -> MemoryDraft {
    guard let draft = try drafts(only: id).first, draft.revision == revision
    else {
      throw MemoryError("stale draft revision or discarded draft")
    }
    return draft
  }

  func locked<T>(_ operation: () throws -> T) throws -> T {
    let lock = try root.openLock().descriptor
    defer {
      _ = flock(lock, LOCK_UN)
      _ = close(lock)
    }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw DreamRunError.busy }
    try root.verifyLock(lock)
    return try operation()
  }
}
