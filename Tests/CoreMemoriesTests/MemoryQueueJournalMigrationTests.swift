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
  #expect(try queueFixture(fixture, sources: fixture.store()).recover(decisionID: "journaled") == receipt)
  #expect(try fixture.main() == commit)
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
