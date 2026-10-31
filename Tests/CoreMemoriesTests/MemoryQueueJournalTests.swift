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
  _ = try reopened.drain()
  #expect(try reopened.recover(decisionID: "journaled").status == "needs-decision")
  #expect(try fixture.main() == changed)
}
