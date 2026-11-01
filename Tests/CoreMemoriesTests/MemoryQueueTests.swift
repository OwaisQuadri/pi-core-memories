import Foundation
import Testing

@testable import CoreMemories

func queueFixture(_ fixture: TransactionFixture, sources: DreamRunStore) throws -> MemoryQueue {
  try MemoryQueue(
    sources: sources, reviewState: fixture.root.appendingPathComponent("review"),
    journal: fixture.root.appendingPathComponent("journal"), environment: [:])
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
  let receipt = try queue.decide(
    display, action: "approve", decisionID: "stale-save", responseReference: "answer")
  #expect(receipt.status == "needs-decision")
  #expect(try queue.recover(decisionID: "stale-save").status == "needs-decision")
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
