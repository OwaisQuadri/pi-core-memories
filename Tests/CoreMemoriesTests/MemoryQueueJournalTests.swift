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
  let drained = try reopened.drain(sessionID: "session")
  #expect(drained.notices.map(\.decisionID) == ["journaled"])
  #expect(drained.needsDecision == 1)
  #expect(try reopened.drain(sessionID: "other").notices.isEmpty)
  #expect(try reopened.recover(decisionID: "journaled").status == "needs-decision")
  #expect(try fixture.main() == changed)
}

@Test func concurrentDrainCannotMislabelAnAppliedDecision() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try journaledApproval(fixture)
  let stale = try queueFixture(fixture, sources: fixture.store())
  let intent = try stale.ledger(stale.controller()) { $0.intents.first! }
  let crashing = try queueFixture(fixture, sources: fixture.store())
  crashing.configureReview = { review in
    review.persistenceFault = { event in
      if case .beforeWrite(let name) = event, name.hasPrefix("outcome-") {
        throw MemoryError("synthetic stop after publication")
      }
    }
  }
  #expect(throws: (any Error).self) { try crashing.drain() }
  try stale.needsDecision(intent, review: stale.controller())
  let receipt = try stale.recover(decisionID: "journaled")
  #expect(receipt.status == "approved")
  #expect(receipt.commit == (try fixture.main()))
  #expect(try stale.drain(sessionID: "session").notices.isEmpty)
}

@Test func needsDecisionReceiptDoesNotHideAPublishedDecision() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try journaledApproval(fixture)
  let queue = try queueFixture(fixture, sources: fixture.store())
  _ = try queue.drain()
  try queue.ledger(queue.controller()) { state in
    let index = state.receipts.firstIndex { $0.decisionID == "journaled" }!
    let old = state.receipts[index]
    state.receipts[index] = MemoryQueueReceipt(
      decisionID: old.decisionID, findingID: old.findingID, revision: old.revision,
      displayDigest: old.displayDigest, action: old.action, status: "needs-decision",
      commit: nil, auditRef: nil)
  }
  #expect(try queue.recover(decisionID: "journaled").status == "approved")
}

@Test func publicationBeforeTheNeedsDecisionWriteIsReceiptedAsPublished() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try journaledApproval(fixture)
  let stale = try queueFixture(fixture, sources: fixture.store())
  let intent = try stale.ledger(stale.controller()) { $0.intents.first! }
  let staleReview = try stale.controller()
  let ledgerLock = try stale.directory.openLock().descriptor
  defer { close(ledgerLock) }
  #expect(flock(ledgerLock, LOCK_EX) == 0)
  let done = DispatchSemaphore(value: 0)
  var writeError: (any Error)?
  Thread.detachNewThread {
    do { try stale.needsDecision(intent, review: staleReview) } catch { writeError = error }
    done.signal()
  }
  usleep(50_000)
  let candidate = try #require(
    try staleReview.list().first {
      $0.change.id.rawValue == intent.display.presentation.finding.revision
    })
  _ = try staleReview.apply(
    staleReview.preview(
      candidateID: candidate.change.id,
      clockDate: Date(timeIntervalSince1970: intent.queuedClock!), amendment: nil))
  flock(ledgerLock, LOCK_UN)
  done.wait()
  #expect(writeError == nil)
  let written = try stale.ledger(staleReview) { state in
    state.receipts.first { $0.decisionID == "journaled" }
  }
  #expect(written?.status == "approved")
  #expect(written?.commit == (try fixture.main()))
}

@Test func briefLedgerHoldAfterApplyStillReturnsThePublishedReceipt() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  do {
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: sources, environment: [:])
    try review.confirmDetach(review.checkoutPreview())
  }
  let live = try queueFixture(fixture, sources: sources)
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
  let sources = try reviewCompletedSiblings(fixture)
  do {
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: sources, environment: [:])
    try review.confirmDetach(review.checkoutPreview())
  }
  let queue = try queueFixture(fixture, sources: sources)
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

@Test func replyInterruptedAfterItsJournalWriteIsDrainedNotStranded() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let (queue, display) = try presentedApproval(fixture) {
    throw MemoryError("synthetic worker death after journal write")
  }
  #expect(throws: (any Error).self) {
    try queue.decide(
      display, action: "approve", decisionID: "interrupted", responseReference: "answer")
  }
  let reopened = try queueFixture(fixture, sources: fixture.store())
  #expect(try reopened.recover(decisionID: "interrupted").status == "queued")
  #expect(try reopened.drain().queued == 0)
  let receipt = try reopened.recover(decisionID: "interrupted")
  #expect(receipt.status == "approved")
  #expect(receipt.commit == (try fixture.main()))
}

@Test func drainDuringLiveReplyCannotApplyItTwice() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  var racing: MemoryQueue?
  var isDrainBusy = false
  let (queue, display) = try presentedApproval(fixture) {
    do { _ = try racing?.drain() } catch DreamRunError.busy { isDrainBusy = true }
  }
  let original = try fixture.main()
  racing = try queueFixture(fixture, sources: fixture.store())
  let receipt = try queue.decide(
    display, action: "approve", decisionID: "live", responseReference: "answer")
  #expect(isDrainBusy)
  #expect(receipt.status == "approved")
  let drained = try #require(racing)
  #expect(try drained.drain().queued == 0)
  #expect(try drained.recover(decisionID: "live") == receipt)
  #expect(
    try Git(repo: fixture.memory, environment: [:]).text([
      "rev-list", "--count", "\(original)..\(receipt.commit!)",
    ]) == "1")
}

@Test func busyLedgerDuringDecisionStillJournalsTheReply() throws {
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
  let ledgerLock = try queue.directory.openLock().descriptor
  defer { close(ledgerLock) }
  let done = DispatchSemaphore(value: 0)
  Thread.detachNewThread {
    for _ in 0..<20 {
      flock(ledgerLock, LOCK_EX)
      usleep(30_000)
      flock(ledgerLock, LOCK_UN)
      usleep(1_000)
    }
    done.signal()
  }
  usleep(5_000)
  let lock = try holdDreamLock(fixture)
  let receipt = try queue.decide(
    display, action: "approve", decisionID: "journaled", responseReference: "answer")
  close(lock)
  done.wait()
  #expect(receipt.status == "queued")
  let reopened = try queueFixture(fixture, sources: fixture.store())
  #expect(try reopened.drain().queued == 0)
  #expect(try reopened.recover(decisionID: "journaled").status == "approved")
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
  #expect(drained.needsDecision == 0)
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
  #expect(drained.needsDecision == 1)
  #expect(try failing.drain(sessionID: "session-reject").notices.map(\.decisionID) == ["reject"])
  let unapplied = try failing.recover(decisionID: "reject")
  #expect(unapplied.status == "needs-decision")
  #expect(try failing.recover(decisionID: "defer").status == "deferred")
  let queue = try queueFixture(fixture, sources: fixture.store())
  let request = try MemoryQueueRequest(sessionID: "session-reject", requestID: "again")
  let row = try #require(
    try queue.list(request: request).first { $0.finding.revision == unapplied.revision })
  #expect(row.blockReason == nil)
  let display = try queue.claim(revision: row.finding.revision, request: request)
  try queue.presented(display, messageReference: "message-again")
  let receipt = try queue.decide(
    display, action: "reject", decisionID: "again", responseReference: "answer-again")
  #expect(receipt.status == "rejected")
  #expect(try queue.drain().needsDecision == 0)
}
