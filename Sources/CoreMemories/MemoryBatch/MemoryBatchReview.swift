import Foundation

func verifyMemoryBatchRepository(_ store: MemoryStore, review: MemoryReviewController?) throws {
  guard review == nil || review?.store.reviewGit.repo.path == store.reviewGit.repo.path else {
    throw MemoryError("review controller belongs to another memory repository")
  }
}

struct PreparedMemoryBatchCandidate {
  let candidate: MemoryReviewCandidate
  let intent: MemoryBatchCandidateIntent
  let effect: MemoryBatchEffect?
}

extension MemoryReviewController {
  func preparedBatchCandidates(
    snapshot: ApprovedDecisionSnapshot, date: Date, limit: Int, offset: Int, paths: [String],
    retaining: [MemoryBatchCandidateIntent] = []
  ) throws -> (rows: [PreparedMemoryBatchCandidate], catalogIDs: Set<String>, count: Int) {
    try locked {
      try refresh()
      guard try store.approvedCommit() == snapshot.base else {
        throw MemoryError("prepared base changed")
      }
      let instant = try MemoryDocument.ReviewInstant(ISO8601DateFormatter().string(from: date))
      let selectable = try candidates.keys.filter { paths.contains(candidates[$0]!.0.path) }.map {
        id in
        (id, try selection(id))
      }.sorted { left, right in
        let leftOrder = left.1 == .approved || left.1 == .rejected ? 1 : 0
        let rightOrder = right.1 == .approved || right.1 == .rejected ? 1 : 0
        return leftOrder == rightOrder ? left.0 < right.0 : leftOrder < rightOrder
      }
      for intent in retaining {
        guard let (change, admission, _) = candidates[intent.candidateID],
          paths.contains(change.path), intent.admissionHash == (try memoryBatchDigest(admission)),
          intent.identity == (try change.entryID ?? Self.assignedIdentity(intent.candidateID)),
          try selection(intent.candidateID) != .approved,
          try selection(intent.candidateID) != .rejected
        else { throw MemoryError("staged candidate context changed") }
      }
      let catalog = selectable.dropFirst(offset).prefix(limit).map(\.0)
      let catalogIDs = Set(catalog)
      let retainedIDs = Set(retaining.map(\.candidateID)).subtracting(catalogIDs).sorted()
      var frozenSnapshot: ApprovedDecisionSnapshot?
      let rows = try (catalog + retainedIDs).map { id in
        let (change, admission, limitations) = candidates[id]!
        let disposition = try selection(id)
        let retained = retaining.first { $0.candidateID == id }
        let intent = MemoryBatchCandidateIntent(
          candidateID: id, admissionHash: try memoryBatchDigest(admission), choice: .accept,
          identity: try change.entryID ?? Self.assignedIdentity(id),
          instant: retained?.instant ?? instant, amendment: nil)
        if disposition == .approved || disposition == .rejected {
          return PreparedMemoryBatchCandidate(
            candidate: MemoryReviewCandidate(
              change: change, disposition: disposition, limitation: nil,
              frozenLimitations: limitations),
            intent: intent, effect: nil)
        }
        do {
          let effect = try batchEffect(
            item: MemoryBatchItem(
              itemID: memoryBatchIdentity("candidate:\(id)"), generation: 0,
              intent: .candidate(intent)),
            intent: intent, snapshot: snapshot, frozenSnapshot: &frozenSnapshot)
          return PreparedMemoryBatchCandidate(
            candidate: MemoryReviewCandidate(
              change: change, disposition: disposition, limitation: nil,
              frozenLimitations: limitations),
            intent: intent, effect: effect)
        } catch let error as MemoryError {
          return PreparedMemoryBatchCandidate(
            candidate: MemoryReviewCandidate(
              change: change, disposition: .blocked, limitation: error.description,
              frozenLimitations: limitations),
            intent: intent, effect: nil)
        }
      }
      return (rows, catalogIDs, selectable.count)
    }
  }

  func batchEffect(
    item: MemoryBatchItem, intent: MemoryBatchCandidateIntent, snapshot: ApprovedDecisionSnapshot,
    frozenSnapshot: inout ApprovedDecisionSnapshot?,
    publications: ((String, String) throws -> [VerifiedMemoryPublication])? = nil
  ) throws -> MemoryBatchEffect? {
    guard let (change, admission, _) = candidates[intent.candidateID],
      intent.admissionHash == (try memoryBatchDigest(admission)),
      change.path == change.scope.path,
      intent.identity == (try change.entryID ?? Self.assignedIdentity(intent.candidateID))
    else { throw MemoryError("candidate admission or identity changed") }
    guard intent.choice == .accept else {
      guard intent.amendment == nil else {
        throw MemoryError("only acceptance can carry an amendment")
      }
      return nil
    }
    if frozenSnapshot?.base != change.base {
      frozenSnapshot = nil
      frozenSnapshot = try store.reviewSnapshot(base: change.base)
    }
    guard let frozen = frozenSnapshot,
      frozen.documents.first(where: { $0.path == change.path })?.digest == change.documentHash
    else {
      throw MemoryError("frozen candidate document changed")
    }
    let target: Range<Int>
    let anchors: [MemoryBatchAnchor]
    let bytes = snapshot.documents.first { $0.path == change.path }?.bytes ?? Data()
    if admission.recoveryCheckpointHash != nil {
      target = try Self.recoveredTarget(change, frozen: frozen, snapshot: snapshot).range
      anchors = try change.contradictions.compactMap { contradiction in
        guard case .memory(let anchor, _) = contradiction else { return nil }
        let matches = snapshot.reviewEntries().filter {
          $0.path == anchor.scope.path && $0.entry.bytes == Data(anchor.before.utf8)
            && $0.entry.isMutable
        }
        guard matches.count == 1 else { throw MemoryError("recovered contradiction is ambiguous") }
        return MemoryBatchAnchor(
          path: anchor.scope.path, start: matches[0].entry.locator.start,
          end: matches[0].entry.locator.end, before: matches[0].entry.bytes)
      }
    } else {
      let lineage =
        try publications?(change.base, snapshot.base)
        ?? verifiedPublications(from: change.base, to: snapshot.base)
      target =
        try change.locator.map {
          try MemoryBatchComposition.transformed(
            $0.start..<$0.end, path: change.path, publications: lineage)
        } ?? bytes.count..<bytes.count
      anchors = try batchAnchors(change, snapshot: snapshot, publications: lineage)
    }
    guard target.lowerBound >= 0, target.upperBound <= bytes.count else {
      throw MemoryError("candidate target moved")
    }
    let before = Data(bytes[target])
    if change.operation == .update {
      guard before == change.before,
        let entry = snapshot.reviewEntries().first(where: {
          $0.path == change.path && $0.entry.locator.start == target.lowerBound
            && $0.entry.locator.end == target.upperBound
        })?.entry, entry.isMutable, entry.identity == change.entryID
      else { throw MemoryError("candidate target changed or is ambiguous") }
    }
    guard
      !snapshot.reviewEntries().contains(where: {
        $0.entry.identity == intent.identity
          && !($0.path == change.path && $0.entry.locator.start == target.lowerBound
            && $0.entry.locator.end == target.upperBound)
      })
    else { throw MemoryError("candidate identity is already in use") }
    let original = try MemoryDocument.reviewedBytes(
      change.after, identity: intent.identity, instant: intent.instant)
    let after = try Self.amendedBatchBytes(intent, proposal: original, before: before)
    return MemoryBatchEffect(
      itemID: item.itemID, path: change.path, start: target.lowerBound, end: target.upperBound,
      before: before, after: after, identity: intent.identity, originalReviewedProposal: original,
      additionStyle: .candidate, readAnchors: anchors)
  }

  static func amendedBatchBytes(_ intent: MemoryBatchCandidateIntent, proposal: Data, before: Data)
    throws -> Data
  {
    guard let amendment = intent.amendment else { return proposal }
    guard !amendment.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      amendment.reason.utf8.count <= 16_384, !amendment.reason.contains("\0"),
      amendment.replacement.utf8.count <= 262_144, !amendment.replacement.contains("\0")
    else { throw MemoryError("invalid bounded native amendment") }
    let bytes = Data(amendment.replacement.utf8)
    let sources = MemoryDocument.sourceAnnotations(in: bytes)
    guard
      (MemoryDocument.sourceAnnotations(in: proposal) + MemoryDocument.sourceAnnotations(in: before))
        .allSatisfy(sources.contains)
    else {
      throw MemoryError("amendment must retain exact proposal and replaced-entry sources")
    }
    let revised = try MemoryDocument.revisedBytes(
      bytes, previous: MemoryDocument.entries(in: before).first, identity: intent.identity,
      instant: intent.instant)
    var after = try MemoryDocument.reviewedBytes(
      revised, identity: intent.identity, instant: intent.instant)
    if before.last == 10, after.last != 10 {
      after.append(before.suffix(2) == Data([13, 10]) ? Data([13, 10]) : Data([10]))
    }
    return after
  }

  func batchAnchors(
    _ change: AtomicMemoryChange, snapshot: ApprovedDecisionSnapshot,
    publications: [VerifiedMemoryPublication]
  ) throws -> [MemoryBatchAnchor] {
    try change.contradictions.compactMap { contradiction in
      guard case .memory(let anchor, _) = contradiction else { return nil }
      let range = try MemoryBatchComposition.transformed(
        anchor.start..<anchor.end, path: anchor.scope.path, publications: publications)
      guard let bytes = snapshot.documents.first(where: { $0.path == anchor.scope.path })?.bytes,
        range.lowerBound >= 0, range.upperBound <= bytes.count,
        Data(bytes[range]) == Data(anchor.before.utf8),
        snapshot.reviewEntries().contains(where: {
          $0.path == anchor.scope.path && $0.entry.isMutable
            && $0.entry.locator.start == range.lowerBound
            && $0.entry.locator.end == range.upperBound
        })
      else { throw MemoryError("required memory contradiction changed or is ambiguous") }
      return MemoryBatchAnchor(
        path: anchor.scope.path, start: range.lowerBound, end: range.upperBound,
        before: Data(anchor.before.utf8))
    }
  }

  func verifiedPublications(from base: String, to current: String) throws
    -> [VerifiedMemoryPublication]
  {
    try publicationChain(from: base, to: current) { commit in self.batchPublications[commit] }
  }

  func publicationChain(
    from base: String, to current: String,
    batch: (String) throws -> VerifiedMemoryPublication?
  ) throws -> [VerifiedMemoryPublication] {
    var cursor = current
    var reverse: [VerifiedMemoryPublication] = []
    var visited: Set<String> = []
    while cursor != base {
      guard visited.insert(cursor).inserted, visited.count <= 10_000 else {
        throw DreamRunError.corruption
      }
      guard let publication = try batch(cursor) ?? legacyPublications[cursor] else {
        throw MemoryError("main contains changes outside verified memory publications")
      }
      reverse.append(publication)
      cursor = publication.base
    }
    return reverse.reversed()
  }

  func indexLegacyPublications() throws {
    let manager = try MemoryManagement(
      repository: repository, environment: store.reviewGit.environment)
    var index = try manager.verifiedDirectPublications()
    for attempt in approvals.values {
      guard index[attempt.resultCommit] == nil else { throw DreamRunError.corruption }
      let payload = attempt.preview
      let effect = MemoryBatchEffect(
        itemID: memoryBatchIdentity("legacy:\(payload.candidateID)"), path: payload.path,
        start: payload.start, end: payload.end, before: payload.before, after: payload.after,
        identity: payload.identity, originalReviewedProposal: payload.after,
        additionStyle: .candidate, readAnchors: [])
      index[attempt.resultCommit] = VerifiedMemoryPublication(
        base: payload.currentBase, commit: attempt.resultCommit, effects: [effect])
    }
    legacyPublications = index
  }

  func recoverBatches() throws {
    let git = store.reviewGit
    let main = try store.approvedCommit()
    let refs = try git.text(["for-each-ref", "--format=%(refname)", "refs/memory-batches/"]).split(
      separator: "\n"
    ).map(String.init)
    guard refs.count <= 10_000 else { throw DreamRunError.limitExceeded }
    var manifests: [String: MemoryBatchManifest] = [:]
    var retainedBytes = 0
    for ref in refs {
      guard let commit = try MemoryBatchReplay.directCommit(ref, git: git),
        try MemoryBatchReplay.isAncestor(commit, of: main, git: git)
      else { throw DreamRunError.corruption }
      let manifest = try MemoryBatchReplay.read(commit, git: git)
      guard ref == "refs/memory-batches/\(manifest.saveID)", manifests[commit] == nil else {
        throw DreamRunError.corruption
      }
      retainedBytes += try MemoryReviewEncoding.encode(manifest).count
      guard retainedBytes <= MemoryReviewEncoding.maximumStateBytes else {
        throw DreamRunError.limitExceeded
      }
      manifests[commit] = manifest
    }
    var verified: [String: VerifiedMemoryPublication] = [:]
    let manager = try MemoryManagement(repository: repository)
    var frozenSnapshot: ApprovedDecisionSnapshot?
    func verify(_ commit: String, manifest: MemoryBatchManifest) throws {
      let snapshot = try store.reviewSnapshot(base: manifest.draft.baseCommit)
      let composition = try MemoryBatchComposition.prepare(
        manifest.draft, snapshot: snapshot, manager: manager
      ) { item, intent in
        guard manifest.draft.batch?.binding.reviewBinding == (try memoryBatchDigest(self.binding))
        else {
          throw MemoryError("batch review binding changed")
        }
        return try self.batchEffect(
          item: item, intent: intent, snapshot: snapshot, frozenSnapshot: &frozenSnapshot
        ) { base, current in
          try self.publicationChain(from: base, to: current) { verified[$0] }
        }
      }
      try MemoryBatchReplay.validate(
        manifest, composition: composition, commit: commit, store: store)
      let publication = VerifiedMemoryPublication(
        base: snapshot.base, commit: commit, effects: composition.effects)
      verified[commit] = publication
    }
    var parents = legacyPublications.mapValues(\.base)
    for (commit, manifest) in manifests {
      guard parents[commit] == nil else { throw DreamRunError.corruption }
      parents[commit] = manifest.draft.baseCommit
    }
    var processed: Set<String> = []
    for commit in manifests.keys {
      var trail: [String] = []
      var visiting: Set<String> = []
      var cursor = commit
      while !processed.contains(cursor), let parent = parents[cursor] {
        guard visiting.insert(cursor).inserted, visiting.count <= 20_000 else {
          throw DreamRunError.corruption
        }
        trail.append(cursor)
        cursor = parent
      }
      for ancestor in trail.reversed() {
        if let manifest = manifests[ancestor] { try verify(ancestor, manifest: manifest) }
        processed.insert(ancestor)
      }
    }
    batchPublications = verified
    var selections: [String: MemoryReviewDisposition] = [:]
    var terminal: Set<String> = Set(approvals.keys)
    for (id, _) in candidates {
      if try root.isPresent("rejected-\(id).json") { terminal.insert(id) }
    }
    func fold(_ manifest: MemoryBatchManifest) throws {
      for item in manifest.draft.batch!.items {
        guard case .candidate(let candidate) = item.intent else { continue }
        let disposition: MemoryReviewDisposition =
          candidate.choice == .accept
          ? .approved : candidate.choice == .reject ? .rejected : .deferred
        if disposition != .deferred {
          guard terminal.insert(candidate.candidateID).inserted else {
            throw DreamRunError.corruption
          }
          selections[candidate.candidateID] = disposition
        } else if !terminal.contains(candidate.candidateID),
          selections[candidate.candidateID] == nil
        {
          selections[candidate.candidateID] = .deferred
        }
      }
    }
    for manifest in manifests.values { try fold(manifest) }
    let names = try root.names()
    if names.contains("batch-format.json") {
      guard try root.read("batch-format.json", maximum: 256) == Data("memory-batch-v1\n".utf8)
      else { throw DreamRunError.corruption }
    }
    for name in names where name.hasPrefix("batch-decisions-") {
      guard names.contains("batch-format.json") else { throw DreamRunError.corruption }
      let manifest = try MemoryReviewEncoding.decode(
        MemoryBatchManifest.self,
        bytes: root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
      guard name == "batch-decisions-\(manifest.saveID).json",
        manifest.draft.batch?.binding.reviewBinding == (try memoryBatchDigest(binding))
      else { throw DreamRunError.corruption }
      let snapshot = try store.reviewSnapshot(base: manifest.draft.baseCommit)
      let composition = try MemoryBatchComposition.prepare(
        manifest.draft, snapshot: snapshot, manager: manager
      ) { item, intent in
        try self.batchEffect(
          item: item, intent: intent, snapshot: snapshot, frozenSnapshot: &frozenSnapshot)
      }
      try MemoryBatchReplay.validate(manifest, composition: composition, commit: nil, store: store)
      try fold(manifest)
    }
    for (id, disposition) in selections {
      if approvals[id] != nil, disposition == .rejected { throw DreamRunError.corruption }
      if try root.isPresent("rejected-\(id).json"), disposition == .approved {
        throw DreamRunError.corruption
      }
    }
    frozenSnapshot = nil
    let publisher = MemoryBatchPublisher(root: root, store: store, review: self)
    for name in names where name.hasPrefix("batch-attempt-") {
      guard names.contains("batch-format.json") else { throw DreamRunError.corruption }
      let attempt = try publisher.readAttempt(name)
      let composed = try publisher.composition(attempt.manifest.draft)
      try MemoryBatchReplay.validate(
        attempt.manifest, composition: composed, commit: attempt.commit, store: store)
    }
    for name in names where name.hasPrefix("batch-draft-") {
      guard names.contains("batch-format.json") else { throw DreamRunError.corruption }
      let draft = try MemoryReviewEncoding.decode(
        MemoryDraft.self, bytes: root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
      guard draft.schemaVersion == 2, draft.batch != nil,
        name == "batch-draft-\(draft.draftID)-\(draft.revision).json"
      else { throw DreamRunError.corruption }
    }
    for name in names where name.hasPrefix("batch-receipt-") {
      let receipt = try MemoryReviewEncoding.decode(
        MemoryBatchReceipt.self,
        bytes: root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
      guard name == "batch-receipt-\(receipt.saveID).json",
        let commit = receipt.commit, manifests[commit]?.saveID == receipt.saveID
      else { throw DreamRunError.corruption }
    }
    batchSelections = selections
  }

  func validateBatchChoices(_ draft: MemoryDraft) throws {
    for item in draft.batch!.items {
      guard case .candidate(let candidate) = item.intent else { continue }
      guard candidates[candidate.candidateID] != nil,
        try selection(candidate.candidateID) != .approved,
        try selection(candidate.candidateID) != .rejected
      else { throw MemoryError("candidate is no longer selectable") }
    }
  }

  func installBatchDecisions(_ manifest: MemoryBatchManifest) throws {
    try root.installReviewFile(
      Data("memory-batch-v1\n".utf8), name: "batch-format.json", fault: persistenceFault, io: fileIO
    )
    try root.installReviewFile(
      MemoryReviewEncoding.encode(manifest), name: "batch-decisions-\(manifest.saveID).json",
      fault: persistenceFault, io: fileIO)
  }
}
