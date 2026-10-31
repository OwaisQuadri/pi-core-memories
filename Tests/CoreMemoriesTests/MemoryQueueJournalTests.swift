import Darwin
import Foundation
import Testing

@testable import CoreMemories

private func holdDreamLock(_ fixture: TransactionFixture) throws -> Int32 {
  let lock = open(fixture.state.appendingPathComponent("writer.lock").path, O_RDWR | O_CLOEXEC)
  #expect(lock >= 0)
  #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
  return lock
}

private func journaledApproval(_ fixture: TransactionFixture) throws -> MemoryQueueDisplay {
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
  let lock = try holdDreamLock(fixture)
  defer { close(lock) }
  let original = try fixture.main()
  let receipt = try queue.decide(
    display, action: "approve", decisionID: "journaled", responseReference: "answer")
  #expect(receipt.status == "queued")
  #expect(try fixture.main() == original)
  #expect(throws: (any Error).self) { try queue.drain() }
  return display
}

@Test func busyDreamLockJournalsTheExactReplyAndTheNextDrainAppliesIt() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let display = try journaledApproval(fixture)
  let reopened = try queueFixture(fixture, sources: fixture.store())
  #expect(try reopened.recover(decisionID: "journaled").status == "queued")
  #expect(try reopened.drain().queued == 0)
  let receipt = try reopened.recover(decisionID: "journaled")
  #expect(receipt.status == "approved")
  #expect(receipt.commit == (try fixture.main()))
  #expect(
    try Git(repo: fixture.memory, environment: [:]).data(["show", "refs/heads/main:MEMORY.md"])
      == display.presentation.replacement)
  #expect(try reopened.drain().queued == 0)
  #expect(try reopened.recover(decisionID: "journaled") == receipt)
}

@Test func journaledDecisionReplaysAfterCrashBetweenPublicationAndReceipt() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try journaledApproval(fixture)
  let crashing = try queueFixture(fixture, sources: fixture.store())
  crashing.configureReview = { review in
    review.persistenceFault = { event in
      if case .beforeWrite(let name) = event, name.hasPrefix("outcome-") {
        throw MemoryError("synthetic crash after publication")
      }
    }
  }
  #expect(throws: (any Error).self) { try crashing.drain() }
  let reopened = try queueFixture(fixture, sources: fixture.store())
  #expect(try reopened.drain().queued == 0)
  let receipt = try reopened.recover(decisionID: "journaled")
  #expect(receipt.status == "approved")
  #expect(receipt.commit == (try fixture.main()))
}

@Test func changedProposalIsNotAppliedFromJournalAndNeedsAFreshDecision() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try journaledApproval(fixture)
  try fixture.advance()
  let changed = try fixture.main()
  let reopened = try queueFixture(fixture, sources: fixture.store())
  #expect(try reopened.drain().needsDecision.map(\.decisionID) == ["journaled"])
  #expect(try reopened.recover(decisionID: "journaled").status == "needs-decision")
  #expect(try fixture.main() == changed)
}

private func independentAdds(_ fixture: TransactionFixture) throws -> DreamRunStore {
  try fixture.populate(texts: ["Use green buttons.", "Prefer short replies."])
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        let context = try transactionObject(request)
        let evidence = context["primaryEvidence"] as! [[String: Any]]
        return try transactionResponse(
          request,
          decisions: ["Use green buttons.", "Prefer short replies."].enumerated().map {
            [
              "kind": "add", "scope": ["kind": "global"], "text": $0.element,
              "sources": [evidence[$0.offset]["source"]!], "reason": "Separate evidence.",
              "contradictions": [],
            ]
          })
      }))
  return sources
}

private func journaledRejectAndDefer(_ fixture: TransactionFixture) throws {
  let sources = try independentAdds(fixture)
  do {
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: sources, environment: [:])
    try review.confirmDetach(review.checkoutPreview())
  }
  let queue = try queueFixture(fixture, sources: sources)
  for action in ["reject", "defer"] {
    let request = try MemoryQueueRequest(sessionID: "session-\(action)", requestID: "request")
    let rows = try queue.list(request: request)
    let row = try #require(
      rows.first { $0.blockReason == nil && $0.disposition == "pending" },
      "\(rows.map { ($0.disposition, $0.blockReason ?? "-") })")
    let display = try queue.claim(revision: row.finding.revision, request: request)
    try queue.presented(display, messageReference: "message-\(action)")
    let lock = try holdDreamLock(fixture)
    defer { close(lock) }
    let receipt = try queue.decide(
      display, action: action, decisionID: action, responseReference: "answer-\(action)")
    #expect(receipt.status == "queued")
  }
}

@Test func multipleJournaledRejectAndDeferDecisionsApplyInOneDrain() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try journaledRejectAndDefer(fixture)
  let reopened = try queueFixture(fixture, sources: fixture.store())
  let drained = try reopened.drain()
  #expect(drained.queued == 0)
  #expect(drained.needsDecision.isEmpty)
  #expect(try reopened.recover(decisionID: "reject").status == "rejected")
  #expect(try reopened.recover(decisionID: "defer").status == "deferred")
}

@Test func failedJournaledDecisionNeedsADecisionWithoutBlockingLaterOnes() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try journaledRejectAndDefer(fixture)
  let failing = try queueFixture(fixture, sources: fixture.store())
  failing.configureReview = { review in
    review.persistenceFault = { event in
      if case .beforeWrite(let name) = event, name.hasPrefix("rejected-") {
        throw MemoryError("synthetic selection write failure")
      }
    }
  }
  let drained = try failing.drain()
  #expect(drained.queued == 0)
  #expect(drained.needsDecision.map(\.decisionID) == ["reject"])
  #expect(try failing.recover(decisionID: "reject").status == "needs-decision")
  #expect(try failing.recover(decisionID: "defer").status == "deferred")
}
