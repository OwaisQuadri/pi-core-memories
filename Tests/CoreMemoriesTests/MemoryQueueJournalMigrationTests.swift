import Darwin
import Foundation
import Testing

@testable import CoreMemories

private func detachedQueue(_ fixture: TransactionFixture, sources: DreamRunStore) throws
  -> MemoryQueue
{
  do {
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: sources, environment: [:])
    try review.confirmDetach(review.checkoutPreview())
  }
  return try queueFixture(fixture, sources: sources)
}

private func seedJournal(_ queue: MemoryQueue, _ decisions: [(action: String, decisionID: String)])
  throws -> [MemoryQueueDisplay]
{
  var seeded: [QueueDecisionIntent] = []
  for decision in decisions {
    queue.release()
    let request = try MemoryQueueRequest(
      sessionID: "session-\(decision.decisionID)", requestID: "request")
    let row = try #require(
      queue.list(request: request).first { row in
        row.blockReason == nil && row.disposition == "pending"
          && !seeded.contains { $0.display.presentation.finding.revision == row.finding.revision }
      })
    let clockDate = Date()
    let display = try queue.claim(
      revision: row.finding.revision, request: request, clockDate: clockDate)
    try queue.presented(display, messageReference: "message-\(decision.decisionID)")
    seeded.append(
      QueueDecisionIntent(
        decisionID: decision.decisionID, display: display, action: decision.action,
        responseReference: "answer-\(decision.decisionID)",
        queuedClock: clockDate.timeIntervalSince1970))
  }
  try queue.ledger(queue.controller()) { $0.intents.append(contentsOf: seeded) }
  queue.release()
  return seeded.map(\.display)
}

@Test func journaledApprovalIsAppliedOnceWhenTheQueueReopens() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let queue = try detachedQueue(fixture, sources: reviewCompletedSiblings(fixture))
  let display = try seedJournal(queue, [("approve", "journaled")])[0]
  let reopened = try queueFixture(fixture, sources: fixture.store())
  let receipt = try reopened.recover(decisionID: "journaled")
  #expect(receipt.status == "approved")
  #expect(receipt.commit == (try fixture.main()))
  #expect(
    try Git(repo: fixture.memory, environment: [:]).data(["show", "refs/heads/main:MEMORY.md"])
      == display.presentation.replacement)
  let again = try queueFixture(fixture, sources: fixture.store())
  #expect(try again.recover(decisionID: "journaled") == receipt)
  #expect(try fixture.main() == receipt.commit)
}

@Test func journaledDecisionReplaysAfterCrashBetweenPublicationAndReceipt() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let queue = try detachedQueue(fixture, sources: reviewCompletedSiblings(fixture))
  _ = try seedJournal(queue, [("approve", "journaled")])
  let original = try fixture.main()
  let crashing = try queueFixture(fixture, sources: fixture.store())
  crashing.configureReview = { review in
    review.persistenceFault = { event in
      if case .beforeWrite(let name) = event, name.hasPrefix("outcome-") {
        throw MemoryError("synthetic crash after publication")
      }
    }
  }
  #expect(throws: (any Error).self) { try crashing.recover(decisionID: "journaled") }
  let reopened = try queueFixture(fixture, sources: fixture.store())
  let receipt = try reopened.recover(decisionID: "journaled")
  #expect(receipt.status == "approved")
  let commit = try #require(receipt.commit)
  #expect(commit == (try fixture.main()))
  #expect(
    try Git(repo: fixture.memory, environment: [:]).text([
      "rev-list", "--count", "\(original)..\(commit)",
    ]) == "1")
}

@Test func changedProposalIsNotAppliedFromTheJournalAndNeedsAFreshDecision() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let queue = try detachedQueue(fixture, sources: reviewCompletedSiblings(fixture))
  _ = try seedJournal(queue, [("approve", "journaled")])
  try fixture.advance()
  let changed = try fixture.main()
  let reopened = try queueFixture(fixture, sources: fixture.store())
  #expect(try reopened.recover(decisionID: "journaled").status == "needs-decision")
  #expect(try fixture.main() == changed)
}

@Test func needsDecisionReceiptDoesNotHideAPublishedDecision() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let queue = try detachedQueue(fixture, sources: reviewCompletedSiblings(fixture))
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  let row = try #require(queue.list(request: request).first)
  let display = try queue.claim(revision: row.finding.revision, request: request)
  try queue.presented(display, messageReference: "message")
  let receipt = try queue.decide(
    display, action: "approve", decisionID: "live", responseReference: "answer")
  #expect(receipt.status == "approved")
  try queue.ledger(queue.controller()) { state in
    let index = state.receipts.firstIndex { $0.decisionID == "live" }!
    let old = state.receipts[index]
    state.receipts[index] = MemoryQueueReceipt(
      decisionID: old.decisionID, findingID: old.findingID, revision: old.revision,
      displayDigest: old.displayDigest, action: old.action, status: "needs-decision",
      commit: nil, auditRef: nil)
  }
  #expect(try queue.recover(decisionID: "live") == receipt)
}

@Test func publicationBeforeTheNeedsDecisionWriteIsReceiptedAsPublished() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let queue = try detachedQueue(fixture, sources: reviewCompletedSiblings(fixture))
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  let row = try #require(queue.list(request: request).first)
  let clockDate = Date()
  let display = try queue.claim(
    revision: row.finding.revision, request: request, clockDate: clockDate)
  try queue.presented(display, messageReference: "message")
  let intent = QueueDecisionIntent(
    decisionID: "unresolved", display: display, action: "approve", responseReference: "answer")
  try queue.ledger(queue.controller()) { $0.intents.append(intent) }
  queue.release()
  let stale = try queueFixture(fixture, sources: fixture.store())
  let staleReview = try stale.controller()
  let candidate = try #require(
    try staleReview.list().first {
      $0.change.id.rawValue == intent.display.presentation.finding.revision
    })
  _ = try staleReview.apply(
    staleReview.preview(candidateID: candidate.change.id, clockDate: clockDate, amendment: nil))
  try stale.needsDecision(intent, review: staleReview)
  let written = try stale.ledger(staleReview) { state in
    state.receipts.first { $0.decisionID == "unresolved" }
  }
  #expect(written?.status == "approved")
  #expect(written?.commit == (try fixture.main()))
}

@Test func briefLedgerHoldAfterApplyStillReturnsThePublishedReceipt() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let live = try detachedQueue(fixture, sources: reviewCompletedSiblings(fixture))
  let held = DispatchSemaphore(value: 0)
  let released = DispatchSemaphore(value: 0)
  live.configureReview = { review in
    review.persistenceFault = { event in
      guard case .beforeWrite(let name) = event, name.hasPrefix("outcome-") else { return }
      let ledgerLock = try live.directory.openLock().descriptor
      Thread.detachNewThread {
        flock(ledgerLock, LOCK_EX)
        held.signal()
        usleep(2_000_000)
        flock(ledgerLock, LOCK_UN)
        close(ledgerLock)
        released.signal()
      }
      #expect(held.wait(timeout: .now() + 2) == .success)
    }
  }
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  let row = try #require(live.list(request: request).first)
  let display = try live.claim(revision: row.finding.revision, request: request)
  try live.presented(display, messageReference: "message")
  let receipt = try live.decide(
    display, action: "approve", decisionID: "held", responseReference: "answer")
  #expect(released.wait(timeout: .now() + 5) == .success)
  #expect(receipt.status == "approved")
  #expect(receipt.commit == (try fixture.main()))
}

private func presentedApproval(
  _ fixture: TransactionFixture, fault: @escaping () throws -> Void
) throws -> (MemoryQueue, MemoryQueueDisplay) {
  let queue = try detachedQueue(fixture, sources: reviewCompletedSiblings(fixture))
  var isArmed = false
  queue.configureReview = { review in
    review.persistenceFault = { event in
      if isArmed, case .beforeWrite = event {
        isArmed = false
        try fault()
      }
    }
  }
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  let row = try #require(queue.list(request: request).first)
  let display = try queue.claim(revision: row.finding.revision, request: request)
  try queue.presented(display, messageReference: "message")
  isArmed = true
  return (queue, display)
}

@Test func decisionStrandedAfterItsIntentWriteReturnsForANewDecision() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let held = DispatchSemaphore(value: 0)
  let finished = DispatchSemaphore(value: 0)
  let released = DispatchSemaphore(value: 0)
  let (queue, display) = try presentedApproval(fixture) {
    let ledgerLock = open(
      fixture.root.appendingPathComponent("review.queue/writer.lock").path, O_RDONLY | O_CLOEXEC)
    Thread.detachNewThread {
      flock(ledgerLock, LOCK_EX)
      held.signal()
      finished.wait()
      close(ledgerLock)
      released.signal()
    }
    held.wait()
    throw MemoryError("synthetic worker death before apply")
  }
  let original = try fixture.main()
  #expect(throws: DreamRunError.busy) {
    try queue.decide(
      display, action: "approve", decisionID: "stranded", responseReference: "answer")
  }
  finished.signal()
  released.wait()
  let reopened = try queueFixture(fixture, sources: fixture.store())
  #expect(try reopened.recover(decisionID: "stranded").status == "needs-decision")
  #expect(try fixture.main() == original)
  let again = try MemoryQueueRequest(sessionID: "session", requestID: "again")
  let returned = try #require(
    reopened.list(request: again).first {
      $0.finding.revision == display.presentation.finding.revision
    })
  #expect(returned.blockReason == nil)
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

@Test func failedJournaledDecisionNeedsADecisionWithoutBlockingLaterOnes() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let queue = try detachedQueue(fixture, sources: independentAdds(fixture))
  _ = try seedJournal(queue, [("reject", "reject"), ("defer", "defer")])
  let failing = try queueFixture(fixture, sources: fixture.store())
  failing.configureReview = { review in
    review.persistenceFault = { event in
      if case .beforeWrite(let name) = event, name.hasPrefix("rejected-") {
        throw MemoryError("synthetic selection write failure")
      }
    }
  }
  let unapplied = try failing.recover(decisionID: "reject")
  #expect(unapplied.status == "needs-decision")
  #expect(try failing.recover(decisionID: "defer").status == "deferred")
  let reopened = try queueFixture(fixture, sources: fixture.store())
  let request = try MemoryQueueRequest(sessionID: "session-reject", requestID: "again")
  let row = try #require(
    try reopened.list(request: request).first { $0.finding.revision == unapplied.revision })
  #expect(row.blockReason == nil)
  let display = try reopened.claim(revision: row.finding.revision, request: request)
  try reopened.presented(display, messageReference: "message-again")
  let receipt = try reopened.decide(
    display, action: "reject", decisionID: "again", responseReference: "answer-again")
  #expect(receipt.status == "rejected")
}

@Test func journaledDecisionWaitsForALaterOpenWhileTheDreamWriterLockIsHeld() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let queue = try detachedQueue(fixture, sources: reviewCompletedSiblings(fixture))
  _ = try seedJournal(queue, [("approve", "journaled")])
  let original = try fixture.main()
  let reopened = try queueFixture(fixture, sources: fixture.store())
  let writer = open(fixture.state.appendingPathComponent("writer.lock").path, O_RDONLY | O_CLOEXEC)
  #expect(flock(writer, LOCK_EX | LOCK_NB) == 0)
  let started = ContinuousClock.now
  #expect(throws: DreamRunError.busy) {
    try reopened.list(request: MemoryQueueRequest(sessionID: "session", requestID: "busy"))
  }
  #expect(started.duration(to: .now) < .seconds(1))
  close(writer)
  #expect(try fixture.main() == original)
  let receipt = try reopened.recover(decisionID: "journaled")
  #expect(receipt.status == "approved")
  #expect(receipt.commit == (try fixture.main()))
}
