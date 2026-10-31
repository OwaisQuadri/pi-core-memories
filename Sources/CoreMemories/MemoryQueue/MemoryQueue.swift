import Darwin
import Foundation

package final class MemoryQueue {
  private let sources: DreamRunStore
  private let repository: URL
  private let reviewState: URL
  private let queueRoot: URL
  let directory: DreamStateDirectory
  private let environment: [String: String]
  private var active: ActiveReview?
  private var sequence: UInt64 = 0
  var configureReview: (MemoryReviewController) -> Void = { _ in }
  package var isCancelled: () -> Bool = { false }

  private struct ActiveReview {
    let controller: MemoryReviewController
    let preview: MemoryReviewPreview
    let checkout: MemoryReviewCheckoutPreview
    let display: MemoryQueueDisplay
    let clockDate: Date
    var messageReference: String?
  }

  package init(
    sources: DreamRunStore, reviewState: URL, journal: URL, environment: [String: String]
  ) throws {
    self.sources = sources
    repository = sources.acceptedSources.memory
    self.reviewState = reviewState
    self.environment = environment
    let queueRoot = URL(fileURLWithPath: reviewState.path + ".queue")
    self.queueRoot = queueRoot
    let protected =
      [
        repository, reviewState, journal, sources.reviewStateRoot,
        sources.acceptedSources.sessions,
      ] + sources.acceptedSources.stripping
    guard
      protected.allSatisfy({ root in
        root.path != queueRoot.path && !root.path.hasPrefix(queueRoot.path + "/")
          && !queueRoot.path.hasPrefix(root.path + "/")
      })
    else { throw DreamRunError.unsafeState }
    var ancestor = queueRoot
    while !FileManager.default.fileExists(atPath: ancestor.path) {
      ancestor.deleteLastPathComponent()
    }
    guard try Git(repo: ancestor, environment: environment).commonDirectory() == nil else {
      throw DreamRunError.unsafeState
    }
    directory = try DreamStateDirectory.openRoot(queueRoot)
  }

  func controller() throws -> MemoryReviewController {
    if let active { return active.controller }
    let review = try MemoryReviewController(
      repository: repository, stateRoot: reviewState, sources: sources, environment: environment)
    review.isCancelled = { [weak self] in self?.isCancelled() ?? true }
    configureReview(review)
    try MemoryQueueAuthority.activate(
      git: review.store.reviewGit, review: review.binding, queue: queueRoot)
    return review
  }

  func ledger<T>(
    _ review: MemoryReviewController, _ operation: (inout QueueLedger) throws -> T
  ) throws -> T {
    var held = stat()
    var named = stat()
    guard fstat(directory.descriptor, &held) == 0, lstat(queueRoot.path, &named) == 0,
      held.st_dev == named.st_dev, held.st_ino == named.st_ino
    else { throw DreamRunError.unsafeState }
    let lock = try directory.openLock().descriptor
    defer {
      _ = flock(lock, LOCK_UN)
      _ = close(lock)
    }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw DreamRunError.busy }
    try directory.verifyLock(lock)
    let binding = SourceDigest(bytes: try MemoryReviewEncoding.encode(review.binding)).rawValue
    var state =
      try directory.isPresent("queue.json")
      ? MemoryReviewEncoding.decode(
        QueueLedger.self,
        bytes: directory.read("queue.json", maximum: MemoryReviewEncoding.maximumFileBytes))
      : QueueLedger(schemaVersion: 1, binding: binding)
    guard state.schemaVersion == 1, state.binding == binding,
      state.findings.allSatisfy({ $0.revision == $0.candidateID }),
      state.intents.allSatisfy({
        $0.display.presentation.finding.revision == $0.display.presentation.finding.candidateID
      })
    else {
      throw MemoryError("queue binding conflict")
    }
    if let amendments = state.amendments {
      let revisions = Set(state.findings.map(\.revision))
      guard amendments.count <= revisions.count,
        Set(amendments.map(\.revision)).count == amendments.count,
        amendments.allSatisfy({ revisions.contains($0.revision) })
      else { throw MemoryError("invalid queue amendment binding") }
    }
    let result = try operation(&state)
    try directory.installReviewFile(
      MemoryReviewEncoding.encode(state), name: "queue.json", isReplacing: true)
    return result
  }

  private static func claimDigest(_ change: AtomicMemoryChange) -> String {
    let text = String(decoding: change.after, as: UTF8.self)
      .replacingOccurrences(of: #"\[source: [^\r\n\]]+\]"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return SourceDigest(bytes: Data(text.utf8)).rawValue
  }

  static func relatedRevisions(
    _ finding: MemoryQueueFinding, state: QueueLedger, isAcrossEpochs: Bool = false
  ) -> Set<
    String
  > {
    var groups: [String: [String]] = [:]
    var keys: [String: [String]] = [:]
    for row in state.findings {
      let identifiers =
        ["claim:" + row.claimDigest, "lineage:" + row.findingID]
        + (row.evidence + row.contradictions.compactMap(\.evidence)).flatMap {
          ["evidence:" + $0.identity, "content:" + $0.contentDigest]
        }
      keys[row.revision] = identifiers.map {
        row.path + "\0" + (isAcrossEpochs ? "all" : row.suppressionEpoch ?? "initial") + "\0" + $0
      }
      for key in keys[row.revision]! { groups[key, default: []].append(row.revision) }
    }
    var revisions: Set<String> = [finding.revision]
    var pending = [finding.revision]
    var visited: Set<String> = []
    while let revision = pending.popLast() {
      for key in keys[revision] ?? [] where visited.insert(key).inserted {
        for neighbor in groups[key] ?? [] where revisions.insert(neighbor).inserted {
          pending.append(neighbor)
        }
      }
    }
    return revisions
  }

  private func admit(_ rows: [MemoryReviewCandidate], state: inout QueueLedger) throws {
    for row in rows
    where !state.findings.contains(where: { $0.revision == row.change.id.rawValue }) {
      let change = row.change
      let evidence = try change.sources.map(MemoryQueueEvidence.init)
      let digest = Self.claimDigest(change)
      let conflicts = try change.contradictions.map(MemoryQueueConflict.init)
      let evidenceKeys = Set(
        (evidence + conflicts.compactMap(\.evidence)).flatMap { [$0.identity, $0.contentDigest] })
      let related = state.findings.filter {
        $0.path == change.path
          && ($0.claimDigest == digest || $0.revision == change.successor?.predecessorRevision
            || !Set(
              ($0.evidence + $0.contradictions.compactMap(\.evidence)).flatMap {
                [$0.identity, $0.contentDigest]
              }
            ).isDisjoint(with: evidenceKeys))
      }
      var finding = MemoryQueueFinding(
        findingID: related.first?.findingID ?? change.id.rawValue, revision: change.id.rawValue,
        candidateID: change.id.rawValue, relatedRevisions: related.map(\.revision).sorted(),
        path: change.path, operation: change.operation.rawValue, frozenBase: change.base,
        before: change.before ?? Data(), proposed: change.after, claimDigest: digest,
        reason: change.reason, evidence: evidence,
        contradictions: conflicts,
        limitations: row.frozenLimitations, inputDigest: change.inputHash.rawValue,
        contextDigest: change.contextHash.rawValue, responseDigest: change.responseHash.rawValue)
      finding.successor = change.successor
      finding.suppressionEpoch =
        related.reversed().compactMap { prior -> String? in
          guard let origin = state.findings.first(where: { $0.revision == prior.suppressionEpoch }),
            Self.isRepeatedSuccessor(finding, origin: origin)
          else { return nil }
          return origin.revision
        }.first
      let rejected = Set(rows.filter { $0.disposition == .rejected }.map { $0.change.id.rawValue })
        .union(
          state.intents.filter { $0.action == "reject" }.map {
            $0.display.presentation.finding.revision
          })
      var proposed = state
      proposed.findings.append(finding)
      let relatedRejected = Self.relatedRevisions(finding, state: proposed, isAcrossEpochs: true)
        .intersection(rejected)
      if let successor = change.successor {
        if let existing = state.findings.first(where: {
          $0.successor?.predecessorRevision == successor.predecessorRevision
            && $0.suppressionEpoch == $0.revision
        }) {
          finding.suppressionEpoch =
            Self.isRepeatedSuccessor(finding, origin: existing) ? existing.suppressionEpoch : nil
        } else if Self.successorPredecessor(finding, rejected: relatedRejected, state: state) != nil
        {
          finding.suppressionEpoch = finding.revision
          finding.successorRejections = relatedRejected.sorted()
        } else {
          finding.suppressionEpoch = nil
        }
      }
      state.findings.append(finding)
    }
    guard state.findings.count <= 10_000 else { throw DreamRunError.limitExceeded }
  }

  private func blockReason(
    _ finding: MemoryQueueFinding, request: MemoryQueueRequest, rows: [MemoryReviewCandidate],
    state: QueueLedger
  ) -> String? {
    if finding.successor != nil, finding.suppressionEpoch == nil {
      return "blocked-successor: changed-evidence proof is absent or invalid"
    }
    let revisions = Self.relatedRevisions(finding, state: state)
    let connected = Self.relatedRevisions(finding, state: state, isAcrossEpochs: true)
    let rejected = Set(rows.filter { $0.disposition == .rejected }.map { $0.change.id.rawValue })
      .union(
        state.intents.filter { $0.action == "reject" }.map {
          $0.display.presentation.finding.revision
        })
    let excluded = Set(
      state.findings.first(where: { $0.revision == finding.suppressionEpoch })?.successorRejections
        ?? [])
    if !connected.intersection(rejected).subtracting(excluded).isEmpty {
      return
        "blocked-successor: rejected evidence or claim requires a versioned changed-evidence successor"
    }
    if state.shown.contains(where: { shown in
      revisions.contains(shown.revision) && shown.request == request
        && !state.receipts.contains(where: {
          $0.displayDigest == shown.displayDigest && $0.status == "detached"
        })
    }) {
      return "already-presented-for-request"
    }
    if state.intents.contains(where: { intent in
      revisions.contains(intent.display.presentation.finding.revision)
        && !state.receipts.contains(where: { $0.decisionID == intent.decisionID })
    }) {
      return "outcome-unresolved"
    }
    return nil
  }

  package func list(request: MemoryQueueRequest) throws -> [MemoryQueueRow] {
    let review = try controller()
    return try importCandidates(review.list(), review: review, request: request)
  }

  func importCandidates(
    _ rows: [MemoryReviewCandidate], review: MemoryReviewController, request: MemoryQueueRequest
  ) throws -> [MemoryQueueRow] {
    try ledger(review) { state in
      try admit(rows, state: &state)
      return rows.map { row in
        let finding = state.findings.first { $0.revision == row.change.id.rawValue }!
        return MemoryQueueRow(
          finding: finding, disposition: row.disposition.rawValue,
          blockReason: blockReason(finding, request: request, rows: rows, state: state)
            ?? row.limitation)
      }
    }
  }

  package func claim(
    revision: String, request: MemoryQueueRequest, clockDate: Date = Date()
  ) throws -> MemoryQueueDisplay {
    guard active == nil, sequence < UInt64.max else {
      throw MemoryError("release the active review first")
    }
    let review = try controller()
    let rows = try review.list()
    let selected = try ledger(review) { state in
      try admit(rows, state: &state)
      guard let row = rows.first(where: { $0.change.id.rawValue == revision }),
        [.pending, .deferred].contains(row.disposition), row.limitation == nil,
        let finding = state.findings.first(where: { $0.revision == revision }),
        blockReason(finding, request: request, rows: rows, state: state) == nil
      else { throw MemoryError("finding is stale, blocked, or suppressed") }
      return (
        finding: finding,
        amendment: state.amendments?.first(where: { $0.revision == revision })?.amendment)
    }
    let finding = selected.finding
    let row = rows.first { $0.change.id.rawValue == revision }!
    let preview = try review.preview(
      candidateID: row.change.id, clockDate: clockDate, amendment: selected.amendment)
    let checkout = try review.checkoutPreview()
    sequence += 1
    let presentation = MemoryQueuePresentation(
      claimID: UUID().uuidString, sequence: String(sequence), request: request, finding: finding,
      previewDigest: preview.digest.rawValue, currentBase: preview.currentBase,
      before: preview.before, after: preview.after, replacement: preview.replacement,
      isDetachRequired: checkout.isDetachRequired, checkoutCommit: checkout.commit,
      checkoutDigest: checkout.digest.rawValue, amendmentReason: selected.amendment?.reason)
    let display = MemoryQueueDisplay(
      presentation: presentation,
      displayDigest: SourceDigest(bytes: try MemoryReviewEncoding.encode(presentation)).rawValue)
    try ledger(review) { state in
      state.shown.append(
        QueueShown(
          findingID: finding.findingID, revision: revision, request: request,
          displayDigest: display.displayDigest, messageReference: nil))
    }
    active = ActiveReview(
      controller: review, preview: preview, checkout: checkout, display: display,
      clockDate: clockDate)
    return display
  }

  package func amend(
    _ display: MemoryQueueDisplay, amendment: MemoryBatchAmendment, clockDate: Date = Date()
  ) throws -> MemoryQueueDisplay {
    guard let current = active, current.display == display, current.messageReference != nil,
      sequence < UInt64.max
    else { throw MemoryError("amendment requires the exact live displayed review") }
    active = nil
    let presentation = display.presentation
    let preview = try current.controller.preview(
      candidateID: current.preview.change.id, clockDate: clockDate, amendment: amendment)
    let checkout = try current.controller.checkoutPreview()
    sequence += 1
    let replacement = MemoryQueuePresentation(
      claimID: presentation.claimID, sequence: String(sequence), request: presentation.request,
      finding: presentation.finding, previewDigest: preview.digest.rawValue,
      currentBase: preview.currentBase, before: preview.before, after: preview.after,
      replacement: preview.replacement, isDetachRequired: checkout.isDetachRequired,
      checkoutCommit: checkout.commit, checkoutDigest: checkout.digest.rawValue,
      amendmentReason: amendment.reason)
    let amended = MemoryQueueDisplay(
      presentation: replacement,
      displayDigest: SourceDigest(bytes: try MemoryReviewEncoding.encode(replacement)).rawValue)
    try ledger(current.controller) { state in
      guard state.findings.contains(where: { $0.revision == presentation.finding.revision }),
        let index = state.shown.firstIndex(where: { $0.displayDigest == display.displayDigest }),
        state.shown[index].messageReference == current.messageReference,
        !state.intents.contains(where: { $0.display.displayDigest == display.displayDigest })
      else { throw MemoryError("amendment presentation is stale or already decided") }
      var amendments = state.amendments ?? []
      let draft = QueueAmendment(revision: presentation.finding.revision, amendment: amendment)
      if let previous = amendments.firstIndex(where: { $0.revision == draft.revision }) {
        amendments[previous] = draft
      } else {
        amendments.append(draft)
      }
      state.amendments = amendments
      state.shown[index] = QueueShown(
        findingID: presentation.finding.findingID, revision: presentation.finding.revision,
        request: presentation.request, displayDigest: amended.displayDigest, messageReference: nil)
    }
    active = ActiveReview(
      controller: current.controller, preview: preview, checkout: checkout, display: amended,
      clockDate: clockDate)
    return amended
  }

  package func presented(_ display: MemoryQueueDisplay, messageReference: String) throws {
    guard var current = active, current.display == display,
      MemoryQueueRequest.isIdentifier(messageReference)
    else { throw MemoryError("stale queue presentation") }
    try ledger(current.controller) { state in
      guard
        let index = state.shown.firstIndex(where: { $0.displayDigest == display.displayDigest }),
        state.shown[index].messageReference == nil
          || state.shown[index].messageReference == messageReference
      else { throw MemoryError("presentation receipt conflict") }
      state.shown[index] = QueueShown(
        findingID: display.presentation.finding.findingID,
        revision: display.presentation.finding.revision, request: display.presentation.request,
        displayDigest: display.displayDigest, messageReference: messageReference)
    }
    current.messageReference = messageReference
    active = current
  }

  package func decide(
    _ display: MemoryQueueDisplay, action: String, decisionID: String, responseReference: String
  ) throws -> MemoryQueueReceipt {
    guard let current = active, current.display == display, current.messageReference != nil,
      ["approve", "reject", "defer", "detach"].contains(action),
      MemoryQueueRequest.isIdentifier(decisionID),
      MemoryQueueRequest.isIdentifier(responseReference),
      responseReference != current.messageReference
    else { throw MemoryError("choice requires the exact live displayed review") }
    if action == "approve", current.checkout.isDetachRequired {
      throw MemoryError(
        "checkout preparation requires a separate explicit choice and fresh preview")
    }
    let intent = QueueDecisionIntent(
      decisionID: decisionID, display: display, action: action, responseReference: responseReference
    )
    try ledger(current.controller) { state in
      guard !state.intents.contains(where: { $0.decisionID == decisionID }) else {
        throw MemoryError("decision key already used; recover its receipt")
      }
      state.intents.append(intent)
    }
    defer { active = nil }
    do {
      try perform(
        action, review: current.controller, preview: current.preview, checkout: current.checkout)
    } catch DreamRunError.busy {
      let queued = intent.with(queuedClock: current.clockDate.timeIntervalSince1970)
      try ledger(current.controller) { state in
        guard let index = state.intents.firstIndex(where: { $0 == intent }) else {
          throw MemoryError("decision journal changed")
        }
        state.intents[index] = queued
      }
      return receipt(queued, status: "queued")
    }
    return try recover(decisionID: decisionID, review: current.controller)
  }

  private func perform(
    _ action: String, review: MemoryReviewController, preview: MemoryReviewPreview,
    checkout: MemoryReviewCheckoutPreview
  ) throws {
    if action == "approve" {
      _ = try review.apply(preview)
    } else if action == "reject" {
      try review.reject(candidateID: preview.change.id)
    } else if action == "defer" {
      try review.deferCandidate(candidateID: preview.change.id)
    } else {
      guard checkout.isDetachRequired else {
        throw MemoryError("checkout does not require preparation")
      }
      try review.confirmDetach(checkout)
    }
  }

  private func receipt(_ intent: QueueDecisionIntent, status: String) -> MemoryQueueReceipt {
    let finding = intent.display.presentation.finding
    return MemoryQueueReceipt(
      decisionID: intent.decisionID, findingID: finding.findingID, revision: finding.revision,
      displayDigest: intent.display.displayDigest, action: intent.action, status: status,
      commit: nil, auditRef: nil)
  }

  package func drain() throws -> (queued: Int, review: Int) {
    guard active == nil else { throw DreamRunError.busy }
    let review = try controller()
    let unresolved = { (state: QueueLedger) in
      state.intents.filter { intent in
        intent.queuedClock != nil
          && !state.receipts.contains(where: { $0.decisionID == intent.decisionID })
      }
    }
    for intent in try ledger(review, { unresolved($0) }) {
      guard try recover(decisionID: intent.decisionID, review: review).status == "queued" else {
        continue
      }
      try applyQueued(intent, review: review)
    }
    let queued = try ledger(review) { unresolved($0).count }
    let pending = try review.list().filter { $0.disposition == .pending && $0.limitation == nil }
    return (queued, pending.count)
  }

  private func applyQueued(_ intent: QueueDecisionIntent, review: MemoryReviewController) throws {
    let presentation = intent.display.presentation
    var validated: (MemoryReviewPreview, MemoryReviewCheckoutPreview)?
    do {
      let shown = try ledger(review) { state in
        (
          state.shown.first(where: { $0.displayDigest == intent.display.displayDigest }),
          state.amendments?.first(where: { $0.revision == presentation.finding.revision })?
            .amendment
        )
      }
      let candidate = try review.list().first {
        $0.change.id.rawValue == presentation.finding.revision
      }
      if let row = candidate, let reference = shown.0?.messageReference,
        reference != intent.responseReference, shown.1?.reason == presentation.amendmentReason,
        let clock = intent.queuedClock
      {
        let preview = try review.preview(
          candidateID: row.change.id, clockDate: Date(timeIntervalSince1970: clock),
          amendment: shown.1)
        let checkout = try review.checkoutPreview()
        let isExact =
          preview.digest.rawValue == presentation.previewDigest
          && preview.before == presentation.before && preview.after == presentation.after
          && preview.replacement == presentation.replacement
          && checkout.digest.rawValue == presentation.checkoutDigest
          && !(intent.action == "approve" && checkout.isDetachRequired)
        if isExact { validated = (preview, checkout) }
      }
    } catch DreamRunError.busy {
      throw DreamRunError.busy
    } catch {
      validated = nil
    }
    guard let (preview, checkout) = validated else {
      try ledger(review) { state in
        if !state.receipts.contains(where: { $0.decisionID == intent.decisionID }) {
          state.receipts.append(receipt(intent, status: "needs-decision"))
        }
      }
      return
    }
    try perform(intent.action, review: review, preview: preview, checkout: checkout)
    _ = try recover(decisionID: intent.decisionID, review: review)
  }

  package func recover(decisionID: String) throws -> MemoryQueueReceipt {
    guard MemoryQueueRequest.isIdentifier(decisionID) else {
      throw MemoryError("invalid decision key")
    }
    return try recover(decisionID: decisionID, review: controller())
  }

  private func recover(decisionID: String, review: MemoryReviewController) throws
    -> MemoryQueueReceipt
  {
    _ = try review.list()
    return try ledger(review) { state in
      guard let intent = state.intents.first(where: { $0.decisionID == decisionID }) else {
        throw MemoryError("unknown decision key")
      }
      if let previous = state.receipts.first(where: { $0.decisionID == decisionID }),
        previous.status == "needs-decision"
      {
        return previous
      }
      let presentation = intent.display.presentation
      let finding = presentation.finding
      var commit: String?
      var auditRef: String?
      var status = "outcome-unresolved"
      if intent.action == "approve", let attempt = review.approvals[finding.revision],
        attempt.previewHash == presentation.previewDigest,
        attempt.preview.before == presentation.before, attempt.preview.after == presentation.after,
        attempt.preview.replacement == presentation.replacement
      {
        commit = attempt.resultCommit
        auditRef = attempt.auditRef
        status = "approved"
      } else if intent.action == "reject" || intent.action == "defer" {
        let disposition: MemoryReviewDisposition = intent.action == "reject" ? .rejected : .deferred
        let name = "\(disposition.rawValue)-\(finding.revision).json"
        if try review.root.isPresent(name) {
          let selection = try MemoryReviewEncoding.decode(
            ReviewSelection.self,
            bytes: review.root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
          guard
            selection == ReviewSelection(candidateID: finding.revision, disposition: disposition)
          else { throw DreamRunError.corruption }
          status = disposition.rawValue
        }
      } else if intent.action == "detach" {
        let name = "detach-outcome-\(presentation.checkoutDigest).json"
        if try review.root.isPresent(name) {
          let attempt = try MemoryReviewEncoding.decode(
            ReviewDetachAttempt.self,
            bytes: review.root.read(name, maximum: MemoryReviewEncoding.maximumFileBytes))
          guard attempt.digest == presentation.checkoutDigest,
            attempt.witness.commit == presentation.checkoutCommit
          else { throw DreamRunError.corruption }
          commit = attempt.witness.commit
          auditRef = attempt.auditRef
          status = "detached"
        }
      }
      let receipt = MemoryQueueReceipt(
        decisionID: decisionID, findingID: finding.findingID, revision: finding.revision,
        displayDigest: intent.display.displayDigest, action: intent.action, status: status,
        commit: commit, auditRef: auditRef)
      if let previous = state.receipts.first(where: { $0.decisionID == decisionID }) {
        guard previous == receipt else { throw MemoryError("native receipt no longer verifies") }
        return previous
      }
      if status != "outcome-unresolved" { state.receipts.append(receipt) }
      if status == "outcome-unresolved", intent.queuedClock != nil {
        return self.receipt(intent, status: "queued")
      }
      return receipt
    }
  }

  package func release() { active = nil }
}
