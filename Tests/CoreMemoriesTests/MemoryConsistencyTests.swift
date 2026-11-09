import Foundation
import Testing

@testable import CoreMemories

@Test func integrityInspectionPreservesSavedStateAndReportsInvalidRuns() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let queue = try queueFixture(fixture, sources: sources)
  _ = try queue.list(request: MemoryQueueRequest(sessionID: "inspection", requestID: "inspection"))
  queue.release()
  let config = try MemoryConfiguration.load(from: queueWorkerConfig(fixture))
  let original = try fixture.main()
  let before = try MemoryQueueMigration.retained(config.stateURL, source: "dream")
  let report = try MemoryIntegrityReport.inspect(configuration: config)
  #expect(report.isValid)
  #expect(try fixture.main() == original)
  #expect(try MemoryQueueMigration.retained(config.stateURL, source: "dream") == before)
  let run = try #require(DreamInspection.read(stateRoot: config.stateURL).runs.first)
  let input = config.stateURL.appendingPathComponent("runs/\(run.id)/input.json")
  try Data("{}".utf8).write(to: input)
  let invalid = try MemoryIntegrityReport.inspect(configuration: config)
  #expect(!invalid.isValid)
  #expect(invalid.checks.contains { $0.component == "dream-saved-runs" && $0.status == "blocked" })
  #expect(try Data(contentsOf: input) == Data("{}".utf8))
}

@Test func safeMemoryDiagnosticsDistinguishBindingsWithoutPrivateText() {
  #expect(
    MemoryFailureDiagnostic.code(MemoryError("queue binding conflict")) == "queue-binding-conflict")
  #expect(
    MemoryFailureDiagnostic.code(
      MemoryError("repository review profile differs from its native queue binding"))
      == "review-profile-conflict")
  #expect(MemoryFailureDiagnostic.code(DreamRunError.busy) == "writer-busy")
  #expect(MemoryFailureDiagnostic.code(MemoryError("/private/payload")) == "validation-failed")
}

@Test func openProposalAllowsReadsAndIndependentClaimsButExcludesItsFinding() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Keep green buttons.", "Use large text."])
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
              "kind": "add", "scope": ["kind": "global"],
              "text": index == 0 ? "Keep green buttons." : "Use large text.",
              "sources": [item["source"]!], "reason": "Retain distinct preferences.",
              "contradictions": [],
            ] as [String: Any]
          })
      }))
  let first = try queueFixture(fixture, sources: sources)
  let second = try queueFixture(fixture, sources: sources)
  let third = try queueFixture(fixture, sources: sources)
  defer {
    first.release()
    second.release()
    third.release()
  }
  let request = try MemoryQueueRequest(sessionID: "first", requestID: "first")
  let other = try MemoryQueueRequest(sessionID: "second", requestID: "second")
  let rows = try first.list(request: request).filter { $0.blockReason == nil }
  let row = try #require(rows.first)
  let display = try first.claim(revision: row.finding.revision, request: request)
  try first.presented(display, messageReference: "displayed")
  #expect(!(try second.list(request: other)).isEmpty)
  #expect(throws: DreamRunError.busy) {
    try second.claim(revision: row.finding.revision, request: other)
  }
  let independent = try #require(rows.first { $0.finding.findingID != row.finding.findingID })
  _ = try third.claim(revision: independent.finding.revision, request: other)
  first.release()
  _ = try second.claim(revision: row.finding.revision, request: other)
}

@Test func sameClaimKeepsEvidenceButHasOneSelectableProposal() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Use green buttons.", "Use green buttons."])
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let queue = try queueFixture(fixture, sources: sources)
  defer { queue.release() }
  let request = try MemoryQueueRequest(sessionID: "first", requestID: "first")
  let rows = try queue.list(request: request)
  #expect(rows.count == 2)
  #expect(rows.filter { $0.blockReason == nil }.count == 1)
  let blocked = try #require(
    rows.first { $0.blockReason?.hasPrefix("equivalent-pending:") == true })
  #expect(throws: (any Error).self) {
    try queue.claim(revision: blocked.finding.revision, request: request)
  }
}

@Test func approvalPreventsAnEquivalentAddOnAnotherRequest() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Use green buttons.", "Use green buttons."])
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let review = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  try review.confirmDetach(review.checkoutPreview())
  let queue = try queueFixture(fixture, sources: sources)
  let request = try MemoryQueueRequest(sessionID: "first", requestID: "first")
  let rows = try queue.list(request: request)
  let row = try #require(rows.first { $0.blockReason == nil })
  let display = try queue.claim(revision: row.finding.revision, request: request)
  try queue.presented(display, messageReference: "proposal")
  let receipt = try queue.decide(
    display, action: "approve", decisionID: "save", responseReference: "answer")
  #expect(receipt.status == "approved")
  let other = try MemoryQueueRequest(sessionID: "second", requestID: "second")
  let later = try queue.list(request: other)
  #expect(later.allSatisfy { $0.disposition == "approved" || $0.blockReason != nil })
  let duplicate = try #require(rows.first { $0.finding.revision != row.finding.revision })
  #expect(throws: (any Error).self) {
    try queue.claim(revision: duplicate.finding.revision, request: other)
  }
}

@Test func savedNoChangeDecisionsDoNotConsumeEvidenceAfterMemoryChanges() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  store.persistenceFault = { event in
    if event == .afterInstall("decisions.json") { throw DreamRunError.persistenceFailure }
  }
  #expect(throws: (any Error).self) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes)
  }
  try fixture.advance()
  let reopened = try fixture.store()
  _ = try transactionPending(
    reopened.run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled),
    reason: .droppedBatch)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
}

@Test func enrolledNoChangeCompletionSurvivesAnApprovedMemoryChange() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  store.persistenceFault = { event in
    if event == .afterInstall("completion.json") { throw DreamRunError.persistenceFailure }
  }
  #expect(throws: (any Error).self) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes)
  }
  try fixture.advance()
  let reopened = try fixture.store()
  let completed = try transactionCompleted(
    reopened.run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled))
  #expect(completed.generation == 1)
  #expect(completed.isRecovered)
}
