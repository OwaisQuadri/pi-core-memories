import Darwin
import Foundation
import Testing

@testable import CoreMemories

private func proposalRefs(_ fixture: TransactionFixture) throws -> String {
  try Git(repo: fixture.memory, environment: [:]).text([
    "for-each-ref", "--format=%(refname)", "refs/heads/proposals/",
  ])
}

@Test(arguments: ["approve", "reject"])
func foregroundApprovalDuringDreamCallCommitsAndDropsTheBatch(action: String) throws {
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
  let queueRequest = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  _ = try queue.list(request: queueRequest)
  let original = try fixture.main()
  let refs = try proposalRefs(fixture)
  try fixture.append(dreamUser("next", nil, dreamOld, "Prefer short replies.") + "\n")
  let store = try fixture.store()
  var receipt: MemoryQueueReceipt?
  let result = try store.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { request in
      let row = try #require(
        queue.list(request: queueRequest).first {
          $0.blockReason == nil && $0.disposition == "pending"
        })
      let display = try queue.claim(revision: row.finding.revision, request: queueRequest)
      try queue.presented(display, messageReference: "message")
      receipt = try queue.decide(
        display, action: action, decisionID: "live", responseReference: "answer")
      return try transactionAdd(request)
    })
  #expect(receipt?.status == (action == "approve" ? "approved" : "rejected"))
  #expect(try fixture.main() == (action == "approve" ? receipt?.commit : original))
  let dropped = try transactionPending(result, reason: .droppedBatch)
  #expect(dropped.proposals.isEmpty)
  #expect(try proposalRefs(fixture) == refs)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("admissions/\(dropped.generation).json").path))
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("runs/\(dropped.runID)/completion.json").path))
  let readmitted = try transactionCompleted(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionNotes($0) }))
  #expect(readmitted.predecessorGeneration == dropped.generation)
  #expect(readmitted.runID != dropped.runID)
  #expect(readmitted.approvedBase == (try fixture.main()))
}

@Test func secondDreamIsBlockedByTheRunLockWhileTheModelCallLeavesTheWriterLockFree() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  let other = try fixture.store()
  _ = try transactionCompleted(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        let writer = open(
          fixture.state.appendingPathComponent("writer.lock").path, O_RDONLY | O_CLOEXEC)
        defer { close(writer) }
        #expect(flock(writer, LOCK_EX | LOCK_NB) == 0)
        flock(writer, LOCK_UN)
        #expect(throws: DreamRunError.busy) {
          try other.run(
            selection: fixture.selection, prepare: transactionUncalledPrepare,
            call: transactionUncalled)
        }
        return try transactionNotes(request)
      }))
}
