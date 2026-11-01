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
  let differentModel = try DreamSelectedCall(
    provider: fixture.selection.provider, modelID: "another-model",
    thinkingLevel: fixture.selection.thinkingLevel)
  #expect(throws: DreamRunError.replacementUnavailable) {
    try fixture.store().run(
      selection: differentModel, resume: .replaceInvalidResponse,
      recoveryTarget: DreamRecoveryTarget(
        runID: rejected.runID, requestHash: SourceDigest(bytes: originalRequest).rawValue),
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
  let interruptedState = try fixture.snapshot(fixture.state)
  for action in [DreamResumeAction.inspectOrContinue, .retryInterruptedCall] {
    let approval = try transactionPending(
      fixture.store().run(
        selection: fixture.selection, resume: action,
        prepare: transactionUncalledPrepare, call: transactionUncalled),
      reason: .recoveryApprovalRequired)
    #expect(approval.runID == rejected.runID)
    #expect(try fixture.snapshot(fixture.state) == interruptedState)
  }
  let completed = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, resume: .replaceInvalidResponse,
      recoveryTarget: DreamRecoveryTarget(
        runID: rejected.runID, requestHash: SourceDigest(bytes: originalRequest).rawValue),
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

@Test func discardingExactInvalidV5ReplyStartsFreshV6Run() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let pending = try transactionPending(
    fixture.store().run(selection: fixture.selection, prepare: { try fixture.prepare($0) }) {
      request in
      let source = (try transactionObject(request)["primaryEvidence"] as! [[String: Any]])[0]["source"]!
      return try transactionResponse(request, decisions: [[
        "kind": "noChange", "sources": [source], "reasonCode": "unresolvedScope",
        "explanation": "Synthetic invalid scope decision.",
      ]])
    }, reason: .invalidDecision)
  try freezeV5Request(fixture)
  let original = try Data(contentsOf: fixture.payload("request.json"))
  let target = try DreamRecoveryTarget(
    runID: pending.runID, requestHash: SourceDigest(bytes: original).rawValue)
  let unchanged = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.replacementUnavailable) {
    try fixture.store().run(
      selection: fixture.selection, resume: .discardInvalidResponse,
      recoveryTarget: DreamRecoveryTarget(
        runID: pending.runID, requestHash: String(repeating: "0", count: 64)),
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == unchanged)
  var fresh: DreamModelRequest?
  let completed = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, resume: .discardInvalidResponse,
      recoveryTarget: target, prepare: { try fixture.prepare($0) },
      call: { request in fresh = request; return try transactionNotes(request) }))
  #expect(completed.runID != pending.runID)
  let request = try #require(fresh)
  let payload = try transactionObject(request)
  let scopes = try #require(payload["scopes"] as? [[String: Any]])
  #expect(scopes.allSatisfy { $0["allowedNoChangeReasons"] is [String] })
  #expect(scopes.allSatisfy { $0["eligibleProposalScopes"] is [[String: Any]] })
  #expect(!FileManager.default.fileExists(
    atPath: fixture.state.appendingPathComponent("runs/\(pending.runID)").path))
  #expect(!FileManager.default.fileExists(
    atPath: fixture.state.appendingPathComponent("discard-invalid.json").path))
  #expect(try DreamInspection.read(stateRoot: fixture.state).runs.map(\.id) == [completed.runID])
  #expect(throws: DreamRunError.replacementUnavailable) {
    try fixture.store().run(
      selection: fixture.selection, resume: .discardInvalidResponse,
      recoveryTarget: target, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
}

@Test func discardRefusesUnknownFilesBeforeChangingState() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let pending = try transactionPending(
    fixture.store().run(selection: fixture.selection, prepare: { try fixture.prepare($0) }) {
      request in
      let source = (try transactionObject(request)["primaryEvidence"] as! [[String: Any]])[0]["source"]!
      return try transactionResponse(request, decisions: [[
        "kind": "noChange", "sources": [source], "reasonCode": "unresolvedScope",
        "explanation": "Synthetic invalid scope decision.",
      ]])
    }, reason: .invalidDecision)
  try freezeV5Request(fixture)
  let target = try DreamRecoveryTarget(
    runID: pending.runID,
    requestHash: SourceDigest(bytes: Data(contentsOf: fixture.payload("request.json"))).rawValue)
  let unknown = fixture.state.appendingPathComponent("runs/\(pending.runID)/other-data.json")
  try Data("do not remove".utf8).write(to: unknown)
  let unchanged = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.unsafeState) {
    try fixture.store().run(
      selection: fixture.selection, resume: .discardInvalidResponse,
      recoveryTarget: target, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == unchanged)
  #expect(!FileManager.default.fileExists(
    atPath: fixture.state.appendingPathComponent("discard-invalid.json").path))
}

@Test func capacityRefusalCannotLeaveAStuckDiscardMarker() throws {
  struct Marker: Encodable {
    let schemaVersion: Int
    let runID: String
    let generation: UInt64
    let requestHash: String
    let admissionHash: String
    let chainHash: String
  }
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let pending = try transactionPending(
    fixture.store().run(selection: fixture.selection, prepare: { try fixture.prepare($0) }) {
      request in
      let source = (try transactionObject(request)["primaryEvidence"] as! [[String: Any]])[0]["source"]!
      return try transactionResponse(request, decisions: [[
        "kind": "noChange", "sources": [source], "reasonCode": "unresolvedScope",
        "explanation": "Synthetic invalid scope decision.",
      ]])
    }, reason: .invalidDecision)
  try freezeV5Request(fixture)
  let requestHash = SourceDigest(bytes: try Data(contentsOf: fixture.payload("request.json"))).rawValue
  let admissionHash = SourceDigest(bytes: try Data(contentsOf:
    fixture.state.appendingPathComponent("admissions/0.json"))).rawValue
  let chainHash = SourceDigest(bytes: try Data(contentsOf:
    fixture.state.appendingPathComponent("generations/0.json"))).rawValue
  let markerSize = try DreamRunEncoding.encode(Marker(
    schemaVersion: 2, runID: pending.runID, generation: 0,
    requestHash: requestHash, admissionHash: admissionHash, chainHash: chainHash)).count
  let clearedSize = try DreamRunEncoding.encode(DreamRunEncoding.State(
    schemaVersion: 2, generation: 0, generationHash: chainHash,
    admissionHash: nil, runID: nil)).count
  let unchanged = try fixture.snapshot(fixture.state)
  let retained = unchanged.values.reduce(0) { $0 + $1.bytes.count }
  let available = markerSize + clearedSize - 1
  #expect(markerSize <= available)
  let limits = try DreamRunLimits(maximumStateBytes: retained + available)
  let target = try DreamRecoveryTarget(runID: pending.runID, requestHash: requestHash)
  #expect(throws: DreamRunError.limitExceeded) {
    try fixture.store(limits: limits).run(
      selection: fixture.selection, resume: .discardInvalidResponse,
      recoveryTarget: target, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == unchanged)
  #expect(!FileManager.default.fileExists(
    atPath: fixture.state.appendingPathComponent("discard-invalid.json").path))
}

@Test func interruptedMarkerWriteAtCapacityNeedsApprovedRetry() throws {
  struct Marker: Encodable {
    let schemaVersion: Int
    let runID: String
    let generation: UInt64
    let requestHash: String
    let admissionHash: String
    let chainHash: String
  }
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let pending = try transactionPending(
    fixture.store().run(selection: fixture.selection, prepare: { try fixture.prepare($0) }) {
      request in
      let source = (try transactionObject(request)["primaryEvidence"] as! [[String: Any]])[0]["source"]!
      return try transactionResponse(request, decisions: [[
        "kind": "noChange", "sources": [source], "reasonCode": "unresolvedScope",
        "explanation": "Synthetic invalid scope decision.",
      ]])
    }, reason: .invalidDecision)
  try freezeV5Request(fixture)
  let requestHash = SourceDigest(bytes: try Data(contentsOf: fixture.payload("request.json"))).rawValue
  let admissionHash = SourceDigest(bytes: try Data(contentsOf:
    fixture.state.appendingPathComponent("admissions/0.json"))).rawValue
  let chainHash = SourceDigest(bytes: try Data(contentsOf:
    fixture.state.appendingPathComponent("generations/0.json"))).rawValue
  let markerSize = try DreamRunEncoding.encode(Marker(
    schemaVersion: 2, runID: pending.runID, generation: 0,
    requestHash: requestHash, admissionHash: admissionHash, chainHash: chainHash)).count
  let clearedSize = try DreamRunEncoding.encode(DreamRunEncoding.State(
    schemaVersion: 2, generation: 0, generationHash: chainHash,
    admissionHash: nil, runID: nil)).count
  let retained = try fixture.snapshot(fixture.state).values.reduce(0) { $0 + $1.bytes.count }
  let limits = try DreamRunLimits(maximumStateBytes: retained + markerSize + clearedSize)
  let target = try DreamRecoveryTarget(runID: pending.runID, requestHash: requestHash)
  let store = try fixture.store(limits: limits)
  store.persistenceFault = {
    if $0 == .beforeInstall("discard-invalid.json") { throw POSIXError(.EIO) }
  }
  #expect(throws: DreamRunError.persistenceFailure) {
    try store.run(
      selection: fixture.selection, resume: .discardInvalidResponse,
      recoveryTarget: target, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(!FileManager.default.fileExists(
    atPath: fixture.state.appendingPathComponent("discard-invalid.json").path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path)
    .filter { $0.hasPrefix(".pending-discard-") }.count == 1)
  let inspection = try fixture.store(limits: limits).run(
    selection: fixture.selection, prepare: transactionUncalledPrepare,
    call: transactionUncalled)
  guard case .pending(let preserved) = inspection else {
    Issue.record("An unapproved inspection must leave the pending run intact")
    return
  }
  #expect(preserved.runID == pending.runID)
  #expect(FileManager.default.fileExists(
    atPath: fixture.state.appendingPathComponent("runs/\(pending.runID)").path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path)
    .filter { $0.hasPrefix(".pending-discard-") }.count == 1)
  #expect(throws: CancellationError.self) {
    try fixture.store(limits: limits).run(
      selection: fixture.selection, resume: .discardInvalidResponse,
      recoveryTarget: target, prepare: { _ in throw CancellationError() },
      call: transactionUncalled)
  }
  #expect(!FileManager.default.fileExists(
    atPath: fixture.state.appendingPathComponent("runs/\(pending.runID)").path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path)
    .filter { $0.hasPrefix(".pending-discard-") }.isEmpty)
}

@Test func interruptedStateWriteAtCapacityCanFinishDiscard() throws {
  struct Marker: Encodable {
    let schemaVersion: Int
    let runID: String
    let generation: UInt64
    let requestHash: String
    let admissionHash: String
    let chainHash: String
  }
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let pending = try transactionPending(
    fixture.store().run(selection: fixture.selection, prepare: { try fixture.prepare($0) }) {
      request in
      let source = (try transactionObject(request)["primaryEvidence"] as! [[String: Any]])[0]["source"]!
      return try transactionResponse(request, decisions: [[
        "kind": "noChange", "sources": [source], "reasonCode": "unresolvedScope",
        "explanation": "Synthetic invalid scope decision.",
      ]])
    }, reason: .invalidDecision)
  try freezeV5Request(fixture)
  let requestHash = SourceDigest(bytes: try Data(contentsOf: fixture.payload("request.json"))).rawValue
  let admissionHash = SourceDigest(bytes: try Data(contentsOf:
    fixture.state.appendingPathComponent("admissions/0.json"))).rawValue
  let chainHash = SourceDigest(bytes: try Data(contentsOf:
    fixture.state.appendingPathComponent("generations/0.json"))).rawValue
  let markerSize = try DreamRunEncoding.encode(Marker(
    schemaVersion: 2, runID: pending.runID, generation: 0,
    requestHash: requestHash, admissionHash: admissionHash, chainHash: chainHash)).count
  let clearedSize = try DreamRunEncoding.encode(DreamRunEncoding.State(
    schemaVersion: 2, generation: 0, generationHash: chainHash,
    admissionHash: nil, runID: nil)).count
  let retained = try fixture.snapshot(fixture.state).values.reduce(0) { $0 + $1.bytes.count }
  let store = try fixture.store(limits: DreamRunLimits(
    maximumStateBytes: retained + markerSize + clearedSize))
  let target = try DreamRecoveryTarget(runID: pending.runID, requestHash: requestHash)
  store.persistenceFault = {
    if $0 == .beforeInstall("state.json") { throw POSIXError(.EIO) }
  }
  #expect(throws: DreamRunError.persistenceFailure) {
    try store.run(
      selection: fixture.selection, resume: .discardInvalidResponse,
      recoveryTarget: target, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(FileManager.default.fileExists(
    atPath: fixture.state.appendingPathComponent("discard-invalid.json").path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path)
    .filter { $0.hasPrefix(".pending-state-") }.count == 1)
  #expect(throws: CancellationError.self) {
    try fixture.store(limits: DreamRunLimits(
      maximumStateBytes: retained + markerSize + clearedSize)).run(
        selection: fixture.selection, prepare: { _ in throw CancellationError() },
        call: transactionUncalled)
  }
  #expect(!FileManager.default.fileExists(
    atPath: fixture.state.appendingPathComponent("runs/\(pending.runID)").path))
  #expect(!FileManager.default.fileExists(
    atPath: fixture.state.appendingPathComponent("discard-invalid.json").path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path)
    .filter { $0.hasPrefix(".pending-state-") }.isEmpty)
}

@Test func interruptedDiscardFinishesBeforeFreshRun() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let pending = try transactionPending(
    fixture.store().run(selection: fixture.selection, prepare: { try fixture.prepare($0) }) {
      request in
      let source = (try transactionObject(request)["primaryEvidence"] as! [[String: Any]])[0]["source"]!
      return try transactionResponse(request, decisions: [[
        "kind": "noChange", "sources": [source], "reasonCode": "unresolvedScope",
        "explanation": "Synthetic invalid scope decision.",
      ]])
    }, reason: .invalidDecision)
  try freezeV5Request(fixture)
  let target = try DreamRecoveryTarget(
    runID: pending.runID,
    requestHash: SourceDigest(bytes: Data(contentsOf: fixture.payload("request.json"))).rawValue)
  let store = try fixture.store()
  store.persistenceFault = {
    if $0 == .afterDirectorySync("state.json") { throw POSIXError(.EIO) }
  }
  #expect(throws: DreamRunError.persistenceFailure) {
    try store.run(
      selection: fixture.selection, resume: .discardInvalidResponse,
      recoveryTarget: target, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(FileManager.default.fileExists(
    atPath: fixture.state.appendingPathComponent("discard-invalid.json").path))
  let completed = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: transactionNotes))
  #expect(completed.runID != pending.runID)
  #expect(!FileManager.default.fileExists(
    atPath: fixture.state.appendingPathComponent("runs/\(pending.runID)").path))
  #expect(!FileManager.default.fileExists(
    atPath: fixture.state.appendingPathComponent("discard-invalid.json").path))
}
