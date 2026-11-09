import Foundation
import Testing

@testable import CoreMemories

private func distinctAdditionSources(_ fixture: TransactionFixture, texts: [String]) throws
  -> DreamRunStore
{
  try fixture.populate(texts: texts)
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        let context = try transactionObject(request)
        let evidence = context["primaryEvidence"] as! [[String: Any]]
        return try transactionResponse(
          request,
          decisions: evidence.enumerated().map { index, item in
            [
              "kind": "add", "scope": ["kind": "global"], "text": texts[index],
              "sources": [item["source"]!], "reason": "Retain a preference.", "contradictions": [],
            ] as [String: Any]
          })
      }))
  let review = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  try review.confirmDetach(review.checkoutPreview())
  return sources
}

@Test func amendedRepresentativeDoesNotSuppressItsOriginalWording() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try distinctAdditionSources(
    fixture, texts: ["Use green buttons.", "Use green buttons."])
  let queue = try queueFixture(fixture, sources: sources)
  defer { queue.release() }
  let request = try MemoryQueueRequest(sessionID: "amend", requestID: "first")
  let rows = try queue.list(request: request)
  let first = try #require(rows.first { $0.blockReason == nil })
  let second = try #require(rows.first { $0.finding.revision != first.finding.revision })
  let display = try queue.claim(revision: first.finding.revision, request: request)
  try queue.presented(display, messageReference: "original")
  let replacement =
    "Use orange buttons. "
    + MemoryDocument.sourceAnnotations(in: display.presentation.after).joined(separator: " ") + "\n"
  let amended = try queue.amend(
    display,
    amendment: MemoryBatchAmendment(replacement: replacement, reason: "Use orange instead."))
  let other = try MemoryQueueRequest(sessionID: "amend", requestID: "second")
  #expect(
    try queue.list(request: other).first {
      $0.finding.revision == second.finding.revision
    }?.blockReason == nil)
  try queue.presented(amended, messageReference: "amended")
  #expect(
    try queue.decide(
      amended, action: "approve", decisionID: "approve-orange", responseReference: "answer"
    ).status == "approved")
  #expect(
    try queue.list(request: other).first {
      $0.finding.revision == second.finding.revision
    }?.blockReason == nil)
  let remaining = try queue.claim(revision: second.finding.revision, request: other)
  #expect(try MemoryDocument.displayText(remaining.presentation.after) == "Use green buttons.")
}

@Test func amendmentCannotAddAlreadyApprovedWording() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try distinctAdditionSources(
    fixture, texts: ["Use green buttons.", "Use orange buttons."])
  let queue = try queueFixture(fixture, sources: sources)
  defer { queue.release() }
  let request = try MemoryQueueRequest(sessionID: "collision", requestID: "first")
  let rows = try queue.list(request: request)
  let green = try #require(
    rows.first {
      String(decoding: $0.finding.proposed, as: UTF8.self).hasPrefix("Use green buttons.")
    })
  let orange = try #require(rows.first { $0.finding.revision != green.finding.revision })
  let first = try queue.claim(revision: green.finding.revision, request: request)
  try queue.presented(first, messageReference: "green")
  #expect(
    try queue.decide(
      first, action: "approve", decisionID: "approve-green", responseReference: "green-answer"
    ).status == "approved")
  let base = try fixture.main()
  let second = try queue.claim(revision: orange.finding.revision, request: request)
  try queue.presented(second, messageReference: "orange")
  let replacement =
    "Use green buttons. "
    + MemoryDocument.sourceAnnotations(in: second.presentation.after).joined(separator: " ") + "\n"
  #expect(throws: (any Error).self) {
    try queue.amend(
      second,
      amendment: MemoryBatchAmendment(replacement: replacement, reason: "Use green instead."))
  }
  #expect(try fixture.main() == base)
}

@Test(arguments: [false, true])
func interruptedPublicationRetriesOnlyAtItsFrozenBase(isMemoryChanged: Bool) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  store.persistenceFault = { event in
    if event == .afterInstall("publication.json") { throw DreamRunError.persistenceFailure }
  }
  #expect(throws: (any Error).self) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) })
  }
  if isMemoryChanged { try fixture.advance() }
  let reopened = try fixture.store()
  let result = try reopened.run(
    selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  if isMemoryChanged {
    _ = try transactionPending(result, reason: .staleUnpublishedPlans)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.state.appendingPathComponent("generations/1.json").path))
  } else {
    let completed = try transactionCompleted(result)
    #expect(completed.generation == 1)
    #expect(!completed.proposals.isEmpty)
  }
}
