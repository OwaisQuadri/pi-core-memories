import Foundation
import Testing

@testable import CoreMemories

func queueFixture(_ fixture: TransactionFixture, sources: DreamRunStore) throws -> MemoryQueue {
  try MemoryQueue(
    sources: sources, reviewState: fixture.root.appendingPathComponent("review"),
    journal: fixture.root.appendingPathComponent("journal"), environment: [:])
}

@Test func queueRejectsConflictingStoredCandidateAliasWithoutRewritingHistory() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let queue = try queueFixture(fixture, sources: sources)
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  _ = try queue.list(request: request)
  let base = try fixture.main()
  let bytes = try queue.directory.read("queue.json", maximum: MemoryReviewEncoding.maximumFileBytes)
  var ledger = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
  var findings = try #require(ledger["findings"] as? [[String: Any]])
  findings[0]["candidateID"] = String(repeating: "f", count: 64)
  ledger["findings"] = findings
  let corrupted = try JSONSerialization.data(withJSONObject: ledger, options: [.sortedKeys])
  try queue.directory.installReviewFile(corrupted, name: "queue.json", isReplacing: true)
  #expect(throws: (any Error).self) { try queue.list(request: request) }
  #expect(
    try queue.directory.read("queue.json", maximum: MemoryReviewEncoding.maximumFileBytes)
      == corrupted)
  #expect(try fixture.main() == base)
}

@Test func queueDeferAndCancelledDisplayDoNotRepeatWithinResumedRequest() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  let later = try MemoryQueueRequest(sessionID: "session", requestID: "later")
  let queue = try queueFixture(fixture, sources: sources)
  let first = try #require(queue.list(request: request).first)
  let original = try fixture.main()
  let display = try queue.claim(revision: first.finding.revision, request: request)
  #expect(throws: (any Error).self) {
    try queue.decide(
      display, action: "approve", decisionID: "premature", responseReference: "answer")
  }
  try queue.presented(display, messageReference: "message")
  let receipt = try queue.decide(
    display, action: "defer", decisionID: "defer-1", responseReference: "answer")
  #expect(receipt.status == "deferred")
  #expect(try queue.recover(decisionID: "defer-1") == receipt)
  let reopened = try queueFixture(fixture, sources: fixture.store())
  #expect(try reopened.list(request: request).first?.blockReason == "already-presented-for-request")
  let next = try reopened.claim(revision: first.finding.revision, request: later)
  reopened.release()
  #expect(try reopened.list(request: later).first?.blockReason == "already-presented-for-request")
  #expect(throws: (any Error).self) { try reopened.presented(next, messageReference: "restored") }
  #expect(try fixture.main() == original)
}

@Test func queueExactApprovalRecoversCheckedReceiptAfterOutcomeWriteFailure() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  do {
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: sources, environment: [:])
    try review.confirmDetach(review.checkoutPreview())
  }
  let queue = try queueFixture(fixture, sources: sources)
  queue.configureReview = { review in
    review.persistenceFault = { event in
      if case .beforeWrite(let name) = event, name.hasPrefix("outcome-") {
        throw MemoryError("synthetic outcome persistence failure")
      }
    }
  }
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  let row = try #require(queue.list(request: request).first)
  let display = try queue.claim(revision: row.finding.revision, request: request)
  try queue.presented(display, messageReference: "message")
  #expect(throws: (any Error).self) {
    try queue.decide(
      display, action: "approve", decisionID: "exact-save", responseReference: "answer")
  }
  let reopened = try queueFixture(fixture, sources: fixture.store())
  let receipt = try reopened.recover(decisionID: "exact-save")
  #expect(receipt.status == "approved")
  #expect(receipt.commit == (try fixture.main()))
  #expect(receipt.displayDigest == display.displayDigest)
  #expect(try reopened.recover(decisionID: "exact-save") == receipt)
  #expect(
    try Git(repo: fixture.memory, environment: [:]).data(["show", "refs/heads/main:MEMORY.md"])
      == display.presentation.replacement)
  #expect(throws: (any Error).self) {
    try reopened.decide(
      display, action: "approve", decisionID: "exact-save", responseReference: "answer")
  }
}

@Test func queueStaleBaseCannotPublishOrRecoverIntentAsConsent() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  do {
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: sources, environment: [:])
    try review.confirmDetach(review.checkoutPreview())
  }
  let queue = try queueFixture(fixture, sources: sources)
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  let row = try #require(queue.list(request: request).first)
  let display = try queue.claim(revision: row.finding.revision, request: request)
  try queue.presented(display, messageReference: "message")
  let git = Git(repo: fixture.memory, environment: [:])
  let base = try fixture.main()
  let changed = try git.text(
    ["commit-tree", "\(base)^{tree}", "-p", base, "-m", "Synthetic intervening change"],
    additions: Git.proposalIdentity)
  _ = try git.data(["update-ref", "refs/heads/main", changed, base])
  #expect(throws: (any Error).self) {
    try queue.decide(
      display, action: "approve", decisionID: "stale-save", responseReference: "answer")
  }
  #expect(try queue.recover(decisionID: "stale-save").status == "outcome-unresolved")
  #expect(try fixture.main() == changed)
}

@Test(arguments: [false, true])
func queueRejectionBlocksRephrasedAndFreshEvidenceSuccessors(isNewEvidence: Bool) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Keep a durable preference.", "New supporting information."])
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let queue = try queueFixture(fixture, sources: sources)
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  let row = try #require(queue.list(request: request).first)
  let display = try queue.claim(revision: row.finding.revision, request: request)
  try queue.presented(display, messageReference: "message")
  _ = try queue.decide(
    display, action: "reject", decisionID: "reject-1", responseReference: "answer")
  let other = try TransactionFixture()
  defer { other.clean() }
  try other.populate(texts: ["Keep a durable preference.", "New supporting information."])
  let otherSources = try other.store()
  _ = try transactionCompleted(
    otherSources.run(
      selection: other.selection, prepare: { try other.prepare($0) },
      call: { request in
        let context = try transactionObject(request)
        let evidence = context["primaryEvidence"] as! [[String: Any]]
        let selected = evidence.filter { item in
          isNewEvidence
            || (item["source"] as! [String: Any])["entry"] as? String
              == row.finding.evidence[0].entry
        }
        var decisions: [[String: Any]] = [
          [
            "kind": "add", "scope": ["kind": "global"], "text": "Rephrased durable finding.",
            "sources": selected.map { $0["source"]! }, "reason": "Reconsider the durable finding.",
            "contradictions": [],
          ]
        ]
        if !isNewEvidence {
          decisions += evidence.filter { item in
            (item["source"] as! [String: Any])["entry"] as? String != row.finding.evidence[0].entry
          }.map {
            [
              "kind": "noChange", "sources": [$0["source"]!],
              "reasonCode": "notDurable", "explanation": "Not used in this finding.",
            ]
          }
        }
        return try transactionResponse(request, decisions: decisions)
      }))
  let otherReview = try MemoryReviewController(
    repository: other.memory, stateRoot: other.root.appendingPathComponent("review"),
    sources: otherSources, environment: [:])
  let newRows = try otherReview.list()
  let review = try queue.controller()
  let imported = try queue.importCandidates(
    newRows, review: review,
    request: MemoryQueueRequest(sessionID: "later-session", requestID: "later-request"))
  #expect(imported.first?.blockReason?.hasPrefix("blocked-successor:") == true)
  #expect(imported.first?.finding.relatedRevisions.contains(row.finding.revision) == true)
  #expect(imported.first?.finding.evidence.count == (isNewEvidence ? 2 : 1))
  #expect(imported.first?.finding.proposed != row.finding.proposed)
}

@Test func queueMigrationRetainsLegacyDraftsDecisionsAndUnfinishedRunsWithoutConsent() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let reviewState = fixture.root.appendingPathComponent("review")
  do {
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: reviewState, sources: sources, environment: [:])
    let rows = try review.list()
    try review.reject(candidateID: rows[0].change.id)
    try review.deferCandidate(candidateID: rows[1].change.id)
  }
  let journal = fixture.root.appendingPathComponent("journal")
  let drafts = try MemoryDraftStore(repository: fixture.memory, journal: journal)
  let draft = try drafts.create(operations: [
    MemoryManagementRequest(
      operation: .add, base: fixture.main(), path: "MEMORY.md",
      replacement: fact("Unfinished manual edit."), reason: "Retain unfinished intent")
  ])
  _ = try drafts.update(draftID: draft.draftID, expectedRevision: draft.revision, operations: [])
  try fixture.append(
    dreamUser("unfinished", nil, dreamOld, "Retain another durable preference.") + "\n")
  _ = try sources.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { _ in throw CancellationError() })
  let sourceBytes = try fixture.snapshot(fixture.state)
  let draftBytes = try fixture.snapshot(journal)
  let base = try fixture.main()
  let queue = try queueFixture(fixture, sources: sources)
  var configuration = MemoryConfiguration.defaults
  configuration.roots = DreamControlRoots(
    state: fixture.state.path, sessions: fixture.sessions.path, memory: fixture.memory.path,
    snippets: fixture.snippets.path, prompts: nil, globalAgents: nil)
  configuration.reviewState = reviewState.path
  configuration.journal = journal.path
  let first = try queue.inventory(configuration: configuration)
  let second = try queue.inventory(configuration: configuration)
  #expect(try MemoryReviewEncoding.encode(first) == MemoryReviewEncoding.encode(second))
  #expect(first.mode == "additive-projection")
  #expect(first.artifacts.contains { $0.source == "journal" && $0.name.hasSuffix("-current.json") })
  #expect(first.artifacts.contains { $0.name.hasPrefix("rejected-") })
  #expect(first.artifacts.contains { $0.name.hasPrefix("deferred-") })
  #expect(first.artifacts.contains { $0.source == "proposal" })
  #expect(first.runs.contains { !$0.isCompleted })
  #expect(
    first.artifacts.contains { $0.source == "dream" && $0.name.hasSuffix("call-started.json") })
  #expect(try fixture.snapshot(fixture.state) == sourceBytes)
  #expect(try fixture.snapshot(journal) == draftBytes)
  #expect(try fixture.main() == base)
}

@Test func queueAmendmentKeepsOwnershipAndRequiresFreshDisplayBeforeExactApproval() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let queue = try queueFixture(fixture, sources: sources)
  defer { queue.release() }
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  let row = try #require(queue.list(request: request).first { $0.finding.operation == "update" })
  let base = try fixture.main()
  let clock = Date()
  let original = try queue.claim(revision: row.finding.revision, request: request, clockDate: clock)
  try queue.presented(original, messageReference: "original-proposal")
  #expect(original.presentation.amendmentReason == nil)
  var seen = Set<String>()
  let annotations = (
    MemoryDocument.sourceAnnotations(in: original.presentation.after)
      + MemoryDocument.sourceAnnotations(in: original.presentation.before)
  ).filter { seen.insert($0).inserted }
  let replacement = "Use orange buttons. " + annotations.joined(separator: " ") + "\n"
  let amended = try queue.amend(
    original, amendment: MemoryBatchAmendment(replacement: replacement, reason: "Revise the wording."),
    clockDate: clock)
  #expect(amended.presentation.claimID == original.presentation.claimID)
  #expect(amended.presentation.request == original.presentation.request)
  #expect(amended.presentation.finding == original.presentation.finding)
  #expect(amended.presentation.amendmentReason == "Revise the wording.")
  #expect(amended.displayDigest != original.displayDigest)
  #expect(amended.presentation.previewDigest != original.presentation.previewDigest)
  #expect(String(decoding: amended.presentation.after, as: UTF8.self).contains("Use orange buttons."))
  #expect(throws: (any Error).self) {
    try queue.presented(original, messageReference: "stale-proposal")
  }
  #expect(throws: (any Error).self) {
    try queue.decide(
      original, action: "approve", decisionID: "stale-approval", responseReference: "old-answer")
  }
  #expect(throws: (any Error).self) {
    try queue.decide(
      amended, action: "approve", decisionID: "unshown-approval", responseReference: "early-answer")
  }
  try queue.presented(amended, messageReference: "amended-proposal")
  let explained = try queue.amend(
    amended,
    amendment: MemoryBatchAmendment(replacement: replacement, reason: "Clarify the revised wording."),
    clockDate: clock)
  #expect(explained.presentation.after == amended.presentation.after)
  #expect(explained.presentation.amendmentReason == "Clarify the revised wording.")
  #expect(explained.presentation.previewDigest != amended.presentation.previewDigest)
  #expect(explained.displayDigest != amended.displayDigest)
  let state = try MemoryReviewEncoding.decode(
    QueueLedger.self,
    bytes: queue.directory.read("queue.json", maximum: MemoryReviewEncoding.maximumFileBytes))
  #expect(state.shown.count == 1)
  #expect(state.amendments?.count == 1)
  #expect(state.intents.isEmpty)
  #expect(state.receipts.isEmpty)
  #expect(try fixture.main() == base)
  try queue.presented(explained, messageReference: "explained-proposal")
  let detached = try queue.decide(
    explained, action: "detach", decisionID: "prepare-amendment", responseReference: "prepare-answer")
  #expect(detached.status == "detached")
  #expect(try fixture.main() == base)
  let refreshed = try queue.claim(revision: row.finding.revision, request: request, clockDate: clock)
  #expect(!refreshed.presentation.isDetachRequired)
  #expect(refreshed.presentation.finding == original.presentation.finding)
  #expect(refreshed.presentation.amendmentReason == "Clarify the revised wording.")
  #expect(String(decoding: refreshed.presentation.after, as: UTF8.self).contains("Use orange buttons."))
  try queue.presented(refreshed, messageReference: "prepared-proposal")
  let approved = try queue.decide(
    refreshed, action: "approve", decisionID: "approve-amendment", responseReference: "later-answer")
  #expect(approved.status == "approved")
  #expect(approved.commit == (try fixture.main()))
  #expect(approved.displayDigest == refreshed.displayDigest)
  #expect(try queue.recover(decisionID: "approve-amendment") == approved)
  #expect(
    try Git(repo: fixture.memory, environment: [:]).data(["show", "refs/heads/main:MEMORY.md"])
      == refreshed.presentation.replacement)
}

@Test func queueAmendmentSurvivesOwnerReleaseAndOldCanonicalReaderRejectsIt() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let queue = try queueFixture(fixture, sources: sources)
  defer { queue.release() }
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  let row = try #require(queue.list(request: request).first { $0.finding.operation == "update" })
  let base = try fixture.main()
  let originalBytes = try queue.directory.read(
    "queue.json", maximum: MemoryReviewEncoding.maximumFileBytes)
  _ = try MemoryReviewEncoding.decode(QueueLedgerBeforeAmendment.self, bytes: originalBytes)
  let display = try queue.claim(revision: row.finding.revision, request: request)
  try queue.presented(display, messageReference: "original-proposal")
  var seen = Set<String>()
  let annotations = (
    MemoryDocument.sourceAnnotations(in: display.presentation.after)
      + MemoryDocument.sourceAnnotations(in: display.presentation.before)
  ).filter { seen.insert($0).inserted }
  let replacement = "Use orange buttons. " + annotations.joined(separator: " ") + "\n"
  _ = try queue.amend(
    display, amendment: MemoryBatchAmendment(replacement: replacement, reason: "Retain the draft."))
  let amendedBytes = try queue.directory.read(
    "queue.json", maximum: MemoryReviewEncoding.maximumFileBytes)
  #expect(throws: (any Error).self) {
    try MemoryReviewEncoding.decode(QueueLedgerBeforeAmendment.self, bytes: amendedBytes)
  }
  queue.release()
  let reopened = try queueFixture(fixture, sources: fixture.store())
  defer { reopened.release() }
  let later = try MemoryQueueRequest(sessionID: "later-session", requestID: "later-request")
  let restored = try reopened.claim(revision: row.finding.revision, request: later)
  #expect(restored.presentation.finding == display.presentation.finding)
  #expect(restored.presentation.amendmentReason == "Retain the draft.")
  #expect(String(decoding: restored.presentation.after, as: UTF8.self).contains("Use orange buttons."))
  #expect(try fixture.main() == base)
  #expect(throws: (any Error).self) {
    try reopened.decide(
      restored, action: "approve", decisionID: "restored-unshown", responseReference: "old-answer")
  }
  #expect(try fixture.main() == base)
}

private struct QueueLedgerBeforeAmendment: Codable {
  let schemaVersion: Int
  let binding: String
  let findings: [MemoryQueueFinding]
  let shown: [QueueShown]
  let intents: [QueueDecisionIntent]
  let receipts: [MemoryQueueReceipt]
}
