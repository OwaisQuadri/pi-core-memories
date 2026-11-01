import Darwin
import Foundation
import Testing

@testable import CoreMemories

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

private func freezeV5Request(_ fixture: TransactionFixture) throws {
  let root = fixture.state
  let admissionURL = root.appendingPathComponent("admissions/0.json")
  let admission = try DreamRunEncoding.decode(
    DreamRunEncoding.Admission.self, bytes: Data(contentsOf: admissionURL))
  let directory = root.appendingPathComponent("runs/\(admission.runID)")
  let inputBytes = try Data(contentsOf: directory.appendingPathComponent("input.json"))
  let binding = SourceDigest(bytes: try Data(contentsOf: root.appendingPathComponent("root.json")))
  let frozen = try DreamRunEncoding.frozen(
    bytes: inputBytes, runID: admission.runID,
    inputHash: SourceDigest(bytes: inputBytes), bindingHash: binding, limits: DreamRunLimits())
  let context = try DreamRunEncoding.context(
    bytes: Data(contentsOf: directory.appendingPathComponent("context.json")), run: frozen)
  let requestURL = directory.appendingPathComponent("request.json")
  let request = try DreamRunEncoding.decode(
    DreamRunEncoding.Request.self, bytes: Data(contentsOf: requestURL))
  let legacy = DreamRunEncoding.Request(
    schemaVersion: 3, runID: request.runID, generation: request.generation,
    inputHash: request.inputHash, contextHash: request.contextHash,
    systemPrompt: context.systemPrompt(rendering: .priorContextV5),
    messages: try context.requestMessages(
      timestampMilliseconds: request.messages[0].timestampMilliseconds,
      rendering: .priorContextV5), renderingVersion: 5)
  let requestBytes = try DreamRunEncoding.encode(legacy)
  let changedAdmission = DreamRunEncoding.Admission(
    schemaVersion: admission.schemaVersion, bindingHash: admission.bindingHash,
    generation: admission.generation, predecessorHash: admission.predecessorHash,
    runID: admission.runID, inputHash: admission.inputHash,
    contextHash: admission.contextHash, requestHash: SourceDigest(bytes: requestBytes).rawValue,
    selection: admission.selection, base: admission.base,
    rejectedVersion: admission.rejectedVersion)
  let admissionBytes = try DreamRunEncoding.encode(changedAdmission)
  let stateURL = root.appendingPathComponent("state.json")
  let state = try DreamRunEncoding.decode(
    DreamRunEncoding.State.self, bytes: Data(contentsOf: stateURL))
  let changedState = DreamRunEncoding.State(
    schemaVersion: state.schemaVersion, generation: state.generation,
    generationHash: state.generationHash,
    admissionHash: SourceDigest(bytes: admissionBytes).rawValue, runID: state.runID)
  let callURL = directory.appendingPathComponent("call-started.json")
  let call = try DreamRunEncoding.decode(
    DreamRunEncoding.Intent.self, bytes: Data(contentsOf: callURL))
  let changedCall = DreamRunEncoding.Intent(
    schemaVersion: call.schemaVersion, admissionHash: changedState.admissionHash!,
    requestHash: changedAdmission.requestHash, selection: call.selection)
  let responseURL = directory.appendingPathComponent("response.json")
  let response = try DreamRunEncoding.decode(
    DreamRunEncoding.BoundResponse.self, bytes: Data(contentsOf: responseURL))
  let changedResponse = DreamRunEncoding.BoundResponse(
    schemaVersion: response.schemaVersion, admissionHash: changedState.admissionHash!,
    runID: response.runID, generation: response.generation, inputHash: response.inputHash,
    contextHash: response.contextHash, requestHash: changedAdmission.requestHash,
    selection: response.selection, text: response.text)
  try requestBytes.write(to: requestURL)
  try admissionBytes.write(to: admissionURL)
  try DreamRunEncoding.encode(changedState).write(to: stateURL)
  try DreamRunEncoding.encode(changedCall).write(to: callURL)
  try DreamRunEncoding.encode(changedResponse).write(to: responseURL)
}

@Test func dreamV5InvalidReplyGetsBoundV6SuccessorWithoutRewritingOldReply() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let rejected = try transactionPending(
    fixture.store().run(selection: fixture.selection, prepare: { try fixture.prepare($0) }) {
      request in
      let source = (try transactionObject(request)["primaryEvidence"] as! [[String: Any]])[0]["source"]!
      return try transactionResponse(request, decisions: [[
        "kind": "noChange", "sources": [source], "reasonCode": "unresolvedScope",
        "explanation": "Synthetic invalid scope decision.",
      ]])
    }, reason: .invalidDecision)
  try freezeV5Request(fixture)
  let originalRequest = try Data(contentsOf: fixture.payload("request.json"))
  let originalReply = try Data(contentsOf: fixture.payload("response.json"))
  let baseline = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare,
      call: transactionUncalled), reason: .invalidDecision)
  #expect(baseline.runID == rejected.runID)
  let unchanged = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.replacementUnavailable) {
    try fixture.store().run(
      selection: fixture.selection, resume: .replaceInvalidResponse,
      recoveryTarget: DreamRecoveryTarget(
        runID: rejected.runID, requestHash: String(repeating: "0", count: 64)),
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == unchanged)
  var successor: DreamModelRequest?
  let interrupted = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, resume: .replaceInvalidResponse,
      recoveryTarget: DreamRecoveryTarget(
        runID: rejected.runID, requestHash: SourceDigest(bytes: originalRequest).rawValue),
      prepare: transactionUncalledPrepare,
      call: { request in successor = request; throw CancellationError() }), reason: .cancelled)
  #expect(interrupted.runID == rejected.runID)
  let request = try #require(successor)
  let payload = try transactionObject(request)
  let scopes = try #require(payload["scopes"] as? [[String: Any]])
  #expect(scopes.allSatisfy { $0["allowedNoChangeReasons"] is [String] })
  #expect(scopes.allSatisfy { $0["eligibleProposalScopes"] is [[String: Any]] })
  #expect(request.messages.count == 1)
  #expect(request.requestHash.rawValue != SourceDigest(bytes: originalRequest).rawValue)
  #expect(try Data(contentsOf: fixture.payload("request.json")) == originalRequest)
  #expect(try Data(contentsOf: fixture.payload("response.json")) == originalReply)
  #expect(try Data(contentsOf: fixture.payload("rejected-1.json")) == originalReply)
  let intent = try DreamRunEncoding.decode(
    DreamRunEncoding.ReplacementIntent.self,
    bytes: Data(contentsOf: fixture.payload("replacement-1.json")))
  #expect(intent.schemaVersion == 4)
  #expect(intent.targetRenderingVersion == 6)
  let intentURL = try fixture.payload("replacement-1.json")
  let originalIntent = try Data(contentsOf: intentURL)
  var altered = intent
  altered.targetRenderingVersion = 5
  try DreamRunEncoding.encode(altered).write(to: intentURL)
  #expect(throws: DreamRunError.corruption) {
    try fixture.store().run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  try originalIntent.write(to: intentURL)
  let completed = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare,
      call: { repeated in
        #expect(repeated.requestHash == request.requestHash)
        #expect(repeated.messages == request.messages)
        return try transactionNotes(repeated)
      }))
  #expect(completed.runID == rejected.runID)
  #expect(try Data(contentsOf: fixture.payload("request.json")) == originalRequest)
  #expect(try Data(contentsOf: fixture.payload("response.json")) == originalReply)
  let inspected = try DreamInspection.read(stateRoot: fixture.state)
  let saved = try #require(inspected.runs.first { $0.id == rejected.runID })
  #expect(saved.attempts.map(\.status) == ["Rejected reply", "Reply valid"])
}
