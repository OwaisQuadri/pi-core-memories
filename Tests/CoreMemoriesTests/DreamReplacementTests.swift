import Darwin
import Foundation
import Testing

@testable import CoreMemories

@Test func dreamReplacementArchivesExactReplyAndKeepsFrozenBatchWithCurrentSelection() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  var original: DreamModelRequest?
  _ = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        original = request
        return try DreamCompletedResponse(text: " \nInvalid café 🌱 reply\r\n ")
      }), reason: .invalidDecision)
  let request = try #require(original)
  let frozenNames = ["input.json", "context.json", "request.json"]
  let frozen = try frozenNames.map { try Data(contentsOf: fixture.payload($0)) }
  let admission = try Data(contentsOf: fixture.state.appendingPathComponent("admissions/0.json"))
  let rejected = try Data(contentsOf: fixture.payload("response.json"))
  let memory = try fixture.snapshot(fixture.memory)
  try FileManager.default.removeItem(at: fixture.sessions)
  try FileManager.default.removeItem(at: fixture.snippets)
  let selection = try DreamSelectedCall(
    provider: "other", modelID: "current", thinkingLevel: "high")
  let report = try transactionCompleted(
    fixture.store().run(
      selection: selection, resume: .replaceInvalidResponse, prepare: transactionUncalledPrepare,
      call: { replacement in
        #expect(replacement.selection == selection)
        #expect(replacement.runID == request.runID && replacement.generation == request.generation)
        #expect(
          replacement.inputHash == request.inputHash
            && replacement.contextHash == request.contextHash)
        #expect(replacement.requestHash == request.requestHash)
        #expect(
          replacement.messages == request.messages
            && replacement.systemPrompt == request.systemPrompt)
        #expect(try Data(contentsOf: fixture.payload("rejected-1.json")) == rejected)
        #expect(try fixture.snapshot(fixture.memory) == memory)
        #expect(!FileManager.default.fileExists(atPath: try fixture.payload("decisions.json").path))
        return try transactionAdd(replacement)
      }))
  #expect(report.runID == request.runID && report.generation == 1 && report.proposals.count == 1)
  #expect(try Data(contentsOf: fixture.payload("response.json")) == rejected)
  #expect(try frozenNames.map { try Data(contentsOf: fixture.payload($0)) } == frozen)
  #expect(
    try Data(contentsOf: fixture.state.appendingPathComponent("admissions/0.json")) == admission)
  let recovered = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare, call: transactionUncalled))
  #expect(
    recovered.runID == report.runID && recovered.proposals[0].commit == report.proposals[0].commit)
  #expect(throws: DreamRunError.replacementUnavailable) {
    try fixture.store().run(
      selection: selection, resume: .replaceInvalidResponse,
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
}

@Test func dreamReplacementCannotCallForFreshInterruptedOrValidSavedReplies() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  #expect(throws: DreamRunError.replacementUnavailable) {
    try fixture.store().run(
      selection: fixture.selection, resume: .replaceInvalidResponse,
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  _ = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { _ in throw CancellationError() }), reason: .cancelled)
  #expect(throws: DreamRunError.replacementUnavailable) {
    try fixture.store().run(
      selection: fixture.selection, resume: .replaceInvalidResponse,
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  let store = try fixture.store()
  store.persistenceFault = {
    if $0 == .afterDirectorySync("response.json") { throw POSIXError(.EIO) }
  }
  #expect(throws: DreamRunError.persistenceFailure) {
    try store.run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare, call: transactionNotes)
  }
  let saved = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.replacementUnavailable) {
    try fixture.store().run(
      selection: fixture.selection, resume: .replaceInvalidResponse,
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == saved)
}

@Test func dreamReplacementCrashBoundariesNeverLoseOriginalOrCallOnInspection() throws {
  for name in [
    "rejected-1.json", "replacement-1.json", "replacement-1-call-started.json",
    "replacement-1-response.json",
  ] {
    for boundary in [
      DreamPersistenceEvent.beforeWrite(name), .afterWriteChunk(name), .afterWrite(name),
      .beforeFileSync(name), .afterFileSync(name), .beforeInstall(name), .afterInstall(name),
      .beforeDirectorySync(name), .afterDirectorySync(name),
    ] {
      let fixture = try TransactionFixture()
      defer { fixture.clean() }
      try fixture.populate()
      _ = try transactionPending(
        fixture.store().run(
          selection: fixture.selection,
          prepare: { try fixture.prepare($0) },
          call: { _ in try DreamCompletedResponse(text: "Invalid café 🌱") }),
        reason: .invalidDecision)
      let rejected = try Data(contentsOf: fixture.payload("response.json"))
      let protected = try fixture.protectedState()
      let store = try fixture.store()
      store.persistenceFault = { if $0 == boundary { throw POSIXError(.EIO) } }
      #expect(throws: DreamRunError.persistenceFailure) {
        try store.run(
          selection: fixture.selection, resume: .replaceInvalidResponse,
          prepare: transactionUncalledPrepare, call: transactionNotes)
      }
      #expect(try fixture.protectedState() == protected)
      #expect(try Data(contentsOf: fixture.payload("response.json")) == rejected)
      let inspected = try fixture.store().run(
        selection: fixture.selection,
        prepare: transactionUncalledPrepare, call: transactionUncalled)
      if case .pending(let report) = inspected {
        #expect(report.generation == 0)
        let resume: DreamResumeAction =
          report.reason == .invalidDecision
          ? .replaceInvalidResponse : .retryInterruptedCall
        let completed = try transactionCompleted(
          fixture.store().run(
            selection: fixture.selection,
            resume: resume, prepare: transactionUncalledPrepare, call: transactionNotes))
        #expect(completed.generation == 1)
      } else {
        #expect(try transactionCompleted(inspected).generation == 1)
      }
      #expect(try Data(contentsOf: fixture.payload("rejected-1.json")) == rejected)
      #expect(try Data(contentsOf: fixture.payload("response.json")) == rejected)
    }
  }
}

@Test func dreamReplacementMissingIntentCannotRestartInterruptedCallOrChangeState() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  _ = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { _ in try DreamCompletedResponse(text: "Invalid café 🌱") }),
    reason: .invalidDecision)
  _ = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, resume: .replaceInvalidResponse,
      prepare: transactionUncalledPrepare, call: { _ in throw CancellationError() }),
    reason: .cancelled)
  try FileManager.default.removeItem(at: fixture.payload("replacement-1.json"))
  let saved = try fixture.snapshot(fixture.root)
  var calls = 0
  for resume in [
    DreamResumeAction.inspectOrContinue, .retryInterruptedCall, .replaceInvalidResponse,
  ] {
    #expect(throws: DreamRunError.corruption) {
      try fixture.store().run(
        selection: fixture.selection, resume: resume, prepare: transactionUncalledPrepare,
        call: { _ in
          calls += 1
          throw CancellationError()
        })
    }
    #expect(calls == 0)
    #expect(try fixture.snapshot(fixture.root) == saved)
  }
}

@Test func dreamReplacementOrphanAndGappedPayloadNamesCannotCallOrChangeState() throws {
  for name in [
    "replacement-1-response.json", "replacement-2-call-started.json",
    "replacement-2-response.json", "replacement-33-call-started.json",
    "replacement-01-response.json", "replacement-0-call-started.json",
  ] {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    try fixture.populate()
    _ = try transactionPending(
      fixture.store().run(
        selection: fixture.selection, prepare: { try fixture.prepare($0) },
        call: { _ in try DreamCompletedResponse(text: "Invalid café 🌱") }),
      reason: .invalidDecision)
    let source = name.hasSuffix("-response.json") ? "response.json" : "call-started.json"
    let payload = try fixture.payload(name)
    try Data(contentsOf: fixture.payload(source)).write(to: payload)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path)
    let saved = try fixture.snapshot(fixture.root)
    for resume in [
      DreamResumeAction.inspectOrContinue, .retryInterruptedCall, .replaceInvalidResponse,
    ] {
      #expect(throws: DreamRunError.corruption) {
        try fixture.store().run(
          selection: fixture.selection, resume: resume,
          prepare: transactionUncalledPrepare, call: transactionUncalled)
      }
      #expect(try fixture.snapshot(fixture.root) == saved)
    }
  }
}

@Test func dreamReplacementChangedArchiveBlocksRetryWithoutWrites() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  _ = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { _ in try DreamCompletedResponse(text: "Invalid café 🌱") }),
    reason: .invalidDecision)
  _ = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, resume: .replaceInvalidResponse,
      prepare: transactionUncalledPrepare, call: { _ in throw CancellationError() }),
    reason: .cancelled)
  let archive = try fixture.payload("rejected-1.json")
  var bytes = try Data(contentsOf: archive)
  bytes.append(32)
  try bytes.write(to: archive)
  let saved = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.corruption) {
    try fixture.store().run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == saved)
}

@Test func dreamReplacementRepeatedInvalidRepliesStayStrictAndArchivesAreFinite() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let invalid: (DreamModelRequest) throws -> DreamCompletedResponse = { _ in
    try DreamCompletedResponse(text: "Invalid café 🌱")
  }
  _ = try transactionPending(
    fixture.store().run(
      selection: fixture.selection,
      prepare: { try fixture.prepare($0) }, call: invalid), reason: .invalidDecision)
  let protected = try fixture.snapshot(fixture.memory)
  for number in 1...32 {
    let priorName = number == 1 ? "response.json" : "replacement-\(number - 1)-response.json"
    let prior = try Data(contentsOf: fixture.payload(priorName))
    _ = try transactionPending(
      fixture.store().run(
        selection: fixture.selection,
        resume: .replaceInvalidResponse, prepare: transactionUncalledPrepare, call: invalid),
      reason: .invalidDecision)
    #expect(try Data(contentsOf: fixture.payload("rejected-\(number).json")) == prior)
    for resume in [DreamResumeAction.inspectOrContinue, .retryInterruptedCall] {
      _ = try transactionPending(
        fixture.store().run(
          selection: fixture.selection, resume: resume,
          prepare: transactionUncalledPrepare, call: transactionUncalled), reason: .invalidDecision)
    }
  }
  #expect(throws: DreamRunError.limitExceeded) {
    try fixture.store().run(
      selection: fixture.selection, resume: .replaceInvalidResponse,
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.memory) == protected)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
}
