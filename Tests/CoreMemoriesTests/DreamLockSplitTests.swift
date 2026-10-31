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

@Test func dropBatchSurvivesCrashBetweenStateSaveAndAdmissionRemoval() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  let original = try fixture.main()
  #expect(throws: DreamRunError.persistenceFailure) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        try fixture.advance()
        store.persistenceFault = { event in
          if event == .afterDirectorySync("state.json") {
            throw MemoryError("synthetic crash after the drop saved state")
          }
        }
        return try transactionAdd(request)
      })
  }
  store.persistenceFault = nil
  let admission = fixture.state.appendingPathComponent("admissions/0.json")
  #expect(FileManager.default.fileExists(atPath: admission.path))
  let dropped = try transactionPending(
    store.run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled),
    reason: .droppedBatch)
  #expect(dropped.approvedBase == original)
  #expect(!FileManager.default.fileExists(atPath: admission.path))
  let readmitted = try transactionCompleted(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionNotes($0) }))
  #expect(readmitted.predecessorGeneration == 0)
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

private func protectedRun(
  _ store: DreamRunStore, _ fixture: TransactionFixture,
  protect: @escaping ([String]) throws -> Void = { _ in },
  call: (DreamModelRequest) throws -> DreamCompletedResponse
) throws -> DreamTransactionResult {
  try store.run(
    selection: fixture.selection,
    sourceRoles: DreamSourceRoles(isSnippetsPresent: true, isPromptsPresent: false),
    protect: protect,
    prepare: { progress, sources in
      try SessionReader(sessions: sources.sessions, snippets: sources.snippets).prepareProtected(
        progress: progress, limits: DreamInputLimits(), protect: { _ in }, admit: { $0 },
        priorViews: sources.admittedViews)
    }, call: call)
}

private func rejectFirstPending(_ queue: MemoryQueue) throws -> String {
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "reject")
  let row = try #require(
    queue.list(request: request).first { $0.blockReason == nil && $0.disposition == "pending" })
  let display = try queue.claim(revision: row.finding.revision, request: request)
  try queue.presented(display, messageReference: "message")
  let receipt = try queue.decide(
    display, action: "reject", decisionID: "reject", responseReference: "answer")
  #expect(receipt.status == "rejected")
  return row.finding.revision
}

@Test func busyReviewLockDuringAdmissionLeavesNoRunDirectory() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  _ = try transactionCompleted(protectedRun(store, fixture, call: { try transactionAdd($0) }))
  let rejected = try rejectFirstPending(queueFixture(fixture, sources: store))
  try fixture.append(dreamUser("next", nil, dreamOld, "Prefer short replies.") + "\n")
  let runs = fixture.state.appendingPathComponent("runs")
  let before = try FileManager.default.contentsOfDirectory(atPath: runs.path)
  let reviewLock = open(
    fixture.root.appendingPathComponent("review/writer.lock").path, O_RDONLY | O_CLOEXEC)
  defer { close(reviewLock) }
  var isPredecessorProtected = false
  #expect(throws: DreamRunError.busy) {
    try protectedRun(
      store, fixture,
      protect: { pieces in
        guard pieces.contains(rejected) else { return }
        isPredecessorProtected = true
        #expect(flock(reviewLock, LOCK_EX | LOCK_NB) == 0)
      }, call: transactionUncalled)
  }
  #expect(isPredecessorProtected)
  #expect(try FileManager.default.contentsOfDirectory(atPath: runs.path) == before)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("admissions/1.json").path))
}

@Test(arguments: [false, true])
func resumedDreamDropsTheWholeBatchAfterARejection(isPartlyPublished: Bool) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let project = fixture.root.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
  _ = try Git(repo: project, environment: [:]).data(["init", "--template="])
  try fixture.populate(cwd: project.path)
  let store = try fixture.store()
  _ = try transactionCompleted(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0, isProject: true) }))
  let queue = try queueFixture(fixture, sources: store)
  _ = try queue.list(request: MemoryQueueRequest(sessionID: "session", requestID: "request"))
  try fixture.append(dreamUser("next", nil, dreamOld, "Prefer short replies.") + "\n")
  let admittedRefs = try proposalRefs(fixture)
  if isPartlyPublished {
    store.beforePublication = { path in
      if path.hasPrefix("projects/") { throw CancellationError() }
    }
  } else {
    store.persistenceFault = { event in
      if event == .afterDirectorySync("decisions.json") {
        throw MemoryError("synthetic crash after decisions")
      }
    }
  }
  #expect(throws: (any Error).self) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0, isProject: true) })
  }
  store.beforePublication = nil
  store.persistenceFault = nil
  #expect((try proposalRefs(fixture) != admittedRefs) == isPartlyPublished)
  _ = try rejectFirstPending(queue)
  let refs = try proposalRefs(fixture)
  let dropped = try transactionPending(
    store.run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled),
    reason: .droppedBatch)
  #expect(dropped.proposals.isEmpty)
  #expect(try proposalRefs(fixture) == refs)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("admissions/\(dropped.generation).json").path))
}

@Test func dreamAfterOnlyAQueueCountReadsTheBoundQueue() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  _ = try queueFixture(fixture, sources: sources).reviewCount()
  try fixture.append(dreamUser("next", nil, dreamOld, "Prefer short replies.") + "\n")
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
}

@Test func queueAdmittingAnAlreadyRejectedFindingKeepsTheDreamBatch() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let rejected: String
  do {
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: sources, environment: [:])
    try review.confirmDetach(review.checkoutPreview())
    let candidate = try #require(review.list().first).change.id
    try review.reject(candidateID: candidate)
    rejected = candidate.rawValue
  }
  let queue = try queueFixture(fixture, sources: sources)
  try queue.ledger(queue.controller()) { #expect($0.findings.isEmpty) }
  try fixture.append(dreamUser("next", nil, dreamOld, "Prefer short replies.") + "\n")
  let report = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        let rows = try queue.list(
          request: MemoryQueueRequest(sessionID: "session", requestID: "request"))
        #expect(rows.contains { $0.finding.revision == rejected })
        return try transactionAdd(request)
      }))
  #expect(!report.proposals.isEmpty)
}

@Test func foregroundDecisionStopsWaitingForTheDreamWriterLockAtItsBound() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  do {
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: sources, environment: [:])
    try review.confirmDetach(review.checkoutPreview())
  }
  sources.writerLockWaitLimit = .seconds(2)
  let queue = try queueFixture(fixture, sources: sources)
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "request")
  let row = try #require(
    queue.list(request: request).first { $0.blockReason == nil && $0.disposition == "pending" })
  let display = try queue.claim(revision: row.finding.revision, request: request)
  try queue.presented(display, messageReference: "message")
  let original = try fixture.main()
  let writer = open(fixture.state.appendingPathComponent("writer.lock").path, O_RDONLY | O_CLOEXEC)
  #expect(flock(writer, LOCK_EX | LOCK_NB) == 0)
  let started = ContinuousClock.now
  #expect(throws: DreamRunError.busy) {
    try queue.decide(display, action: "approve", decisionID: "live", responseReference: "answer")
  }
  #expect(started.duration(to: .now) < .milliseconds(3500))
  close(writer)
  #expect(try queue.recover(decisionID: "live").status == "needs-decision")
  #expect(try fixture.main() == original)
}

@Test func queueListDuringTheDreamWriterLockFailsFastAsBusy() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  sources.writerLockWaitLimit = .seconds(2)
  let queue = try queueFixture(fixture, sources: sources)
  let writer = open(fixture.state.appendingPathComponent("writer.lock").path, O_RDONLY | O_CLOEXEC)
  defer { close(writer) }
  #expect(flock(writer, LOCK_EX | LOCK_NB) == 0)
  let started = ContinuousClock.now
  #expect(throws: DreamRunError.busy) {
    try queue.list(request: MemoryQueueRequest(sessionID: "session", requestID: "request"))
  }
  #expect(started.duration(to: .now) < .seconds(1))
}
