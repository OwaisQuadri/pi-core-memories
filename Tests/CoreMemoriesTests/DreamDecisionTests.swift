import Darwin
import Foundation
import Testing

@testable import CoreMemories

private let decisionBlue =
  "# Memory\n\nUse blue buttons. [source: pi:one#u1/part/0; added: 2026-01-01]\n"
private let decisionKey = String(repeating: "a", count: 64)
private let decisionOtherKey = String(repeating: "b", count: 64)

private struct DecisionFixture {
  let store: Fixture
  let run: FrozenDreamRun
  let snapshot: ApprovedDecisionSnapshot

  init(
    document: String = "# Memory\n", texts: [String] = ["Use green buttons, not blue."],
    projectKeys: [String] = [], cwd: String = "/synthetic/removed-project",
    isAnswerIncluded: Bool = false, isToolEvidenceIncluded: Bool = false
  ) throws {
    store = try Fixture()
    try store.write(document, path: "MEMORY.md")
    if document != "# Memory\n" { try store.commit() }
    let sessions = store.root.appendingPathComponent("sessions")
    var lines = [dreamHeader("one", cwd: cwd, name: nil)]
    lines += texts.enumerated().map { dreamUser("u\($0.offset + 2)", nil, dreamOld, $0.element) }
    if isAnswerIncluded {
      lines.append(
        dreamResult(
          "answer", nil, call: "q", tool: "ask_user_question", "Rendered context",
          details: dreamAnswer(
            "answered",
            [
              ["type": "text", "label": "Typed preference"],
              ["type": "option", "label": "Picked context"],
              ["type": "other", "label": "Other preference"],
            ])))
    }
    if isToolEvidenceIncluded {
      lines += [
        dreamAssistant("calls", nil, dreamOld, [
          dreamText("Agent text"), dreamCall("c1", "read", ["path": "src/A.swift"]),
          dreamCall("c2", "read", ["path": "src/B.swift"]),
        ]),
        dreamResult("result", "calls", call: "c1", tool: "read", "Synthetic output"),
      ]
    }
    lines += [
      dreamAssistant("assistant", nil, dreamOld, [dreamText("Not primary")]),
      dreamJSON([
        "type": "custom_message", "id": "generated", "timestamp": dreamOld,
        "customType": "core-memories", "content": "Generated approved memory",
      ]),
      dreamResult(
        "picked", nil, call: "q", tool: "ask_user_question", "Not primary",
        details: dreamAnswer("answered", [["type": "option", "label": "Not primary"]])),
    ]
    try store.write(
      lines.joined(separator: "\n") + "\n", path: "--fixture--/one.jsonl", at: sessions)
    try store.write(
      dreamHeader("child", cwd: "/synthetic/child", parent: "one", name: nil) + "\n"
        + dreamUser("childtext", nil, dreamOld, "Not primary") + "\n",
      path: "--fixture--/child.jsonl", at: sessions)
    let batch = try SessionReader(sessions: sessions, snippets: nil, environment: [:]).prepare(
      progress: DreamProgress(), limits: DreamInputLimits(),
      isToolEvidenceIncluded: isToolEvidenceIncluded, isSourceScrubbed: isToolEvidenceIncluded)
    let base = try store.store.approvedCommit()
    let selection = try DreamSelectedCall(
      provider: "synthetic", modelID: "fixture", thinkingLevel: "off")
    let runID = "00000000-0000-4000-8000-000000000001"
    let binding = SourceDigest(bytes: Data("synthetic".utf8))
    let input = try DreamRunEncoding.input(
      runID: runID, context: DreamRunContext(selection: selection, currentApprovedBase: base),
      bindingHash: binding, progress: DreamProgress(), batch: batch, limits: DreamRunLimits())
    run = try DreamRunEncoding.frozen(
      bytes: input, runID: runID, inputHash: SourceDigest(bytes: input), bindingHash: binding,
      limits: DreamRunLimits())
    snapshot = try store.store.decisionSnapshot(base: base, projectKeys: projectKeys)
  }

  func clean() { store.clean() }

  func context(
    resolution: PinnedScopeResolution = .outsideGit(isGlobalEligible: true),
    scopes: [PinnedEvidenceScope]? = nil, owners: [PinnedOwnerInput] = [],
    date: String = "2026-01-02", limits: DreamDecisionLimits = try! DreamDecisionLimits()
  ) throws -> DreamDecisionContext {
    try DreamDecisionContext(
      run: run, snapshot: snapshot,
      scopes: scopes
        ?? run.batch.evidence.map {
          PinnedEvidenceScope(source: $0.id, projectScope: $0.projectScope, resolution: resolution)
        }, owners: owners, addedDate: date, limits: limits)
  }

  func response(_ decisions: [[String: Any]], context: DreamDecisionContext) throws
    -> DurableDreamResponse
  {
    let root: [String: Any] = [
      "schemaVersion": 1, "contextHash": context.contextHash.rawValue, "decisions": decisions,
    ]
    return try response(
      text: String(
        decoding: JSONSerialization.data(
          withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
  }

  func response(text: String) throws -> DurableDreamResponse {
    DurableDreamResponse(
      run: run, response: try DreamCompletedResponse(text: text),
      responseHash: SourceDigest(bytes: Data(("synthetic envelope:" + text).utf8)), isReplay: true,
      isBaseCurrent: false)
  }
}


private enum ScopeAttemptMutation: CaseIterable, Sendable {
  case feedback, feedbackHash, rejectedCall, archive, attemptNumber
  case replacementBinding, effectiveHash, responseCall, envelopeVersion, orphanResponse
}

private func scopeContractAttemptReader(
  _ fixture: DecisionFixture, mutation: ScopeAttemptMutation? = nil
) throws -> DreamAttemptReader {
  let context = try fixture.context()
  let saved = DreamRunEncoding.Request(
    schemaVersion: 3, runID: fixture.run.runID, generation: fixture.run.progress.generation,
    inputHash: fixture.run.inputHash.rawValue, contextHash: context.contextHash.rawValue,
    systemPrompt: context.systemPrompt(rendering: .scopeV2),
    messages: try context.requestMessages(timestampMilliseconds: 123, rendering: .scopeV2),
    renderingVersion: 2)
  let requestBytes = try DreamRunEncoding.encode(saved)
  let request = try saved.verifiedDomain(
    run: fixture.run, context: context, bytes: requestBytes
  ).request
  guard let canonical = realpath(fixture.store.root.path, nil) else {
    throw MemoryError("fixture root")
  }
  defer { free(canonical) }
  let folder = URL(fileURLWithPath: String(cString: canonical))
    .appendingPathComponent("scope-contract-attempts")
  let directory = try DreamStateDirectory.openRoot(folder)
  let admission = SourceDigest(bytes: Data("synthetic admission".utf8))
  let other = SourceDigest(bytes: Data("other synthetic binding".utf8)).rawValue
  let reader = DreamAttemptReader(
    directory: directory, run: fixture.run, context: context, baseline: request,
    rendering: .scopeV2, admissionHash: admission, limits: try DreamRunLimits())
  func write(_ name: String, _ bytes: Data) throws {
    let file = folder.appendingPathComponent(name)
    try bytes.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
  let baselineCall = DreamRunEncoding.Intent(
    schemaVersion: 2, admissionHash: admission.rawValue, requestHash: request.requestHash.rawValue,
    selection: DreamRunEncoding.Selection(request.selection))
  let baselineCallBytes = try DreamRunEncoding.encode(baselineCall)
  try write("call-started.json", baselineCallBytes)
  let initialResponse = DreamRunEncoding.BoundResponse(
    schemaVersion: 2, admissionHash: admission.rawValue,
    runID: fixture.run.runID, generation: fixture.run.progress.generation,
    inputHash: fixture.run.inputHash.rawValue, contextHash: context.contextHash.rawValue,
    requestHash: request.requestHash.rawValue,
    selection: DreamRunEncoding.Selection(request.selection), text: "Invalid synthetic reply")
  let responseBytes = try DreamRunEncoding.encode(initialResponse)
  try write("response.json", responseBytes)
  let rejected = try #require(reader.verify().response)
  guard
    case .failure(let rejection) = DreamDecision.assess(
      response: rejected, context: context, rendering: .scopeV2)
  else { throw DreamRunError.corruption }
  var feedback = DreamReplacementFeedback(failure: rejection.failure, rendering: .scopeV2)
  if mutation == .feedback {
    var object = try #require(
      JSONSerialization.jsonObject(with: feedback.bytes()) as? [String: Any])
    var failure = try #require(object["failure"] as? [String: Any])
    failure["code"] = DreamValidationCode.schemaVersion.rawValue
    object["failure"] = failure
    feedback = try JSONDecoder().decode(
      DreamReplacementFeedback.self,
      from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
  }
  var archive = responseBytes
  if mutation == .archive { archive.append(0x0A) }
  try write("rejected-1.json", archive)
  var replacement = DreamRunEncoding.ReplacementIntent(
    schemaVersion: 3, admissionHash: admission.rawValue,
    requestHash: request.requestHash.rawValue,
    rejectedResponseHash: SourceDigest(bytes: archive).rawValue)
  replacement.attemptNumber = mutation == .attemptNumber ? 2 : 1
  replacement.rejectedAttemptNumber = 0
  replacement.rejectedCallIntentHash =
    mutation == .rejectedCall ? other : SourceDigest(bytes: baselineCallBytes).rawValue
  replacement.feedback = feedback
  replacement.feedbackHash =
    mutation == .feedbackHash ? other : SourceDigest(bytes: try feedback.bytes()).rawValue
  let replacementBytes = try DreamRunEncoding.encode(replacement)
  let replacementHash = SourceDigest(bytes: replacementBytes)
  try write("replacement-1.json", replacementBytes)
  let selection = try DreamSelectedCall(
    provider: "synthetic", modelID: "historical-replacement", thinkingLevel: "off")
  let effective = try reader.request(
    attempt: DreamResponseAttempt(number: 1), replacement: replacement,
    replacementHash: replacementHash, selection: selection)
  let effectiveHash = mutation == .effectiveHash ? other : effective.requestHash.rawValue
  var call = DreamRunEncoding.Intent(
    schemaVersion: 3, admissionHash: admission.rawValue, requestHash: effectiveHash,
    selection: DreamRunEncoding.Selection(selection))
  call.baselineRequestHash = request.requestHash.rawValue
  call.replacementIntentHash = mutation == .replacementBinding ? other : replacementHash.rawValue
  call.attemptNumber = 1
  let callBytes = try DreamRunEncoding.encode(call)
  try write("replacement-1-call-started.json", callBytes)
  let text = try fixture.response(
    [
      [
        "kind": "noChange", "sources": context.primaryCatalogue.map { decisionSource($0.id) },
        "reasonCode": "notDurable", "explanation": "Synthetic non-durable detail.",
      ]
    ], context: context
  ).response.text
  var response = DreamRunEncoding.BoundResponse(
    schemaVersion: mutation == .envelopeVersion ? 2 : 3,
    admissionHash: admission.rawValue,
    runID: fixture.run.runID, generation: fixture.run.progress.generation,
    inputHash: fixture.run.inputHash.rawValue, contextHash: context.contextHash.rawValue,
    requestHash: effectiveHash, selection: DreamRunEncoding.Selection(selection), text: text)
  response.callIntentHash =
    mutation == .responseCall ? other : SourceDigest(bytes: callBytes).rawValue
  let finalBytes = try DreamRunEncoding.encode(response)
  try write("replacement-1-response.json", finalBytes)
  if mutation == .orphanResponse { try write("replacement-2-response.json", finalBytes) }
  return reader
}

private func decisionLimits(_ values: [String: Int]) throws -> DreamDecisionLimits {
  let defaults = try DreamDecisionLimits()
  return try DreamDecisionLimits(
    maximumResponseBytes: values["response"] ?? defaults.maximumResponseBytes,
    maximumFrozenBytes: values["frozen"] ?? defaults.maximumFrozenBytes,
    maximumLayoutEntries: values["layoutEntries"] ?? defaults.maximumLayoutEntries,
    maximumLayoutBytes: values["layoutBytes"] ?? defaults.maximumLayoutBytes,
    maximumSnapshotBytes: values["snapshot"] ?? defaults.maximumSnapshotBytes,
    maximumDocumentBytes: values["document"] ?? defaults.maximumDocumentBytes,
    maximumProjectKeys: values["projects"] ?? defaults.maximumProjectKeys,
    maximumOwners: values["owners"] ?? defaults.maximumOwners,
    maximumOwnerBytes: values["ownerTotal"] ?? defaults.maximumOwnerBytes,
    maximumSingleOwnerBytes: values["ownerSingle"] ?? defaults.maximumSingleOwnerBytes,
    maximumOwnerReferenceBytes: values["ownerReference"] ?? defaults.maximumOwnerReferenceBytes,
    maximumDecisions: values["decisions"] ?? defaults.maximumDecisions,
    maximumSources: values["sources"] ?? defaults.maximumSources,
    maximumContradictions: values["contradictions"] ?? defaults.maximumContradictions,
    maximumReferences: values["references"] ?? defaults.maximumReferences,
    maximumTextBytes: values["text"] ?? defaults.maximumTextBytes,
    maximumBeforeBytes: values["before"] ?? defaults.maximumBeforeBytes,
    maximumPlans: values["plans"] ?? defaults.maximumPlans,
    maximumReplacementBytes: values["replacement"] ?? defaults.maximumReplacementBytes,
    maximumOutputBytes: values["output"] ?? defaults.maximumOutputBytes,
    maximumMetadataBytes: values["metadata"] ?? defaults.maximumMetadataBytes)
}

private func decisionSource(_ id: PrimaryTextID) -> [String: Any] {
  ["session": id.citation.session, "entry": id.citation.entry, "part": id.part]
}

private func decisionScope(_ scope: DreamMemoryScope) -> [String: Any] {
  switch scope {
  case .global: ["kind": "global"]
  case .project(let key): ["kind": "project", "key": key]
  case .device(let key): ["kind": "device", "deviceKey": key]
  case .deviceProject(let device, let project): ["kind": "deviceProject", "deviceKey": device, "key": project]
  }
}

private func decisionAnchor(_ anchor: DreamMemoryAnchor) -> [String: Any] {
  [
    "scope": decisionScope(anchor.scope), "documentHash": anchor.documentHash.rawValue,
    "start": anchor.start, "end": anchor.end, "before": anchor.before,
  ]
}

private func decisionAdd(
  _ source: PrimaryTextID, text: String = "Use green buttons.",
  scope: DreamMemoryScope = .global
) -> [String: Any] {
  [
    "kind": "add", "scope": decisionScope(scope), "text": text,
    "sources": [decisionSource(source)], "contradictions": [], "reason": "Retain the preference.",
  ]
}

private func decisionUpdate(
  _ source: PrimaryTextID, anchor: DreamMemoryAnchor,
  text: String = "Use green buttons."
) -> [String: Any] {
  [
    "kind": "update", "scope": decisionScope(anchor.scope), "anchor": decisionAnchor(anchor),
    "text": text, "sources": [decisionSource(source)], "reason": "Apply the correction.",
    "contradictions": [
      [
        "kind": "memory", "anchor": decisionAnchor(anchor),
        "explanation": "Replace the earlier preference.",
      ]
    ],
  ]
}

private func decisionNoChange(_ sources: [PrimaryTextID], code: String = "insufficientEvidence")
  -> [String: Any]
{
  [
    "kind": "noChange", "sources": sources.map(decisionSource), "reasonCode": code,
    "explanation": "No durable preference supplied.",
  ]
}

private func decisionOwnerNote(_ source: PrimaryTextID, owner: PinnedOwnerInput) -> [String: Any] {
  [
    "kind": "ownerNote", "sources": [decisionSource(source)],
    "owner": [
      "key": owner.key, "ownerHash": owner.digest.rawValue, "start": 0,
      "end": owner.bytes.count, "before": String(decoding: owner.bytes, as: UTF8.self),
    ],
    "contradictions": [], "explanation": "The supplied owner already contains the rule.",
  ]
}

@Test(arguments: [DreamRequestRendering.legacyV1, .connectedV3])
func dreamRequestUnversionedReplayPreservesFrozenRenderingAndRawDigest(
  rendering: DreamRequestRendering
) throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let context = try fixture.context()
  let request = DreamRunEncoding.Request(
    schemaVersion: 2, runID: fixture.run.runID, generation: fixture.run.progress.generation,
    inputHash: fixture.run.inputHash.rawValue, contextHash: context.contextHash.rawValue,
    systemPrompt: context.systemPrompt(rendering: rendering),
    messages: try context.requestMessages(timestampMilliseconds: 123, rendering: rendering))
  let bytes = Data(
    (" \n" + String(decoding: try DreamRunEncoding.encode(request), as: UTF8.self)).utf8)
  let saved = try DreamRunEncoding.decode(DreamRunEncoding.Request.self, bytes: bytes)
  let replay = try saved.domain(run: fixture.run, context: context, bytes: bytes)
  #expect(replay.requestHash == SourceDigest(bytes: bytes))
  #expect(replay.systemPrompt.utf8.elementsEqual(request.systemPrompt.utf8))
  #expect(replay.messages[0].text.utf8.elementsEqual(request.messages[0].text.utf8))
  if rendering == .legacyV1 {
    #expect(
      SourceDigest(bytes: Data(request.systemPrompt.utf8)).rawValue
        == "76a60a515c0c03b8d810859056a69cb09ea2c1b6e683e149ae3c6bb42a61fd31")
    let body = try #require(
      JSONSerialization.jsonObject(with: Data(request.messages[0].text.utf8)) as? [String: Any])
    #expect(body["connectedWindowBindings"] == nil)
    let primary = try #require(body["primaryEvidence"] as? [[String: Any]])
    #expect(
      Set(try #require(primary.first).keys)
        == ["source", "kind", "text", "timestampReferenceTimeBits"])
    let schema = try #require(body["decisionSchema"] as? [String: Any])
    let properties = try #require(schema["properties"] as? [String: Any])
    let decisions = try #require(properties["decisions"] as? [String: Any])
    let items = try #require(decisions["items"] as? [String: Any])
    let variants = try #require(items["oneOf"] as? [[String: Any]])
    #expect(
      Set(try #require(variants.first?["required"] as? [String]))
        == ["kind", "scope", "text", "sources", "contradictions", "reason"])
  }
}

@Test func dreamRequestVersionMarkerRefusesMissingUnknownAndInconsistentFormats() throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let context = try fixture.context()
  for (schema, rendering) in [(3, 3), (3, nil), (3, 1), (3, 2), (2, 3), (4, 4)] as [(Int, Int?)] {
    let request = DreamRunEncoding.Request(
      schemaVersion: schema, runID: fixture.run.runID, generation: fixture.run.progress.generation,
      inputHash: fixture.run.inputHash.rawValue, contextHash: context.contextHash.rawValue,
      systemPrompt: context.savedSystemPrompt,
      messages: try context.requestMessages(timestampMilliseconds: 123), renderingVersion: rendering
    )
    let bytes = try DreamRunEncoding.encode(request)
    if schema == 3 && rendering == 3 {
      let saved = try DreamRunEncoding.decode(DreamRunEncoding.Request.self, bytes: bytes)
      #expect(
        try saved.domain(run: fixture.run, context: context, bytes: bytes).requestHash
          == SourceDigest(bytes: bytes))
    } else if schema == 3 && rendering == 2 {
      #expect(throws: DreamRunError.corruption) {
        try request.domain(run: fixture.run, context: context, bytes: bytes)
      }
    } else {
      #expect(throws: DreamRunError.unsupportedSchema) {
        try request.domain(run: fixture.run, context: context, bytes: bytes)
      }
    }
  }
}

@Test func dreamRequestMixedHistoricalPromptAndMessageFormatsRemainCorrupt() throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let context = try fixture.context()
  for (prompt, message) in [
    (DreamRequestRendering.legacyV1, DreamRequestRendering.connectedV3),
    (.connectedV3, .legacyV1), (.legacyV1, .scopeV2), (.scopeV2, .legacyV1),
    (.scopeV2, .connectedV3), (.connectedV3, .scopeV2),
  ] {
    let request = DreamRunEncoding.Request(
      schemaVersion: 2, runID: fixture.run.runID, generation: fixture.run.progress.generation,
      inputHash: fixture.run.inputHash.rawValue, contextHash: context.contextHash.rawValue,
      systemPrompt: context.systemPrompt(rendering: prompt),
      messages: try context.requestMessages(timestampMilliseconds: 123, rendering: message))
    #expect(throws: DreamRunError.corruption) {
      try request.domain(
        run: fixture.run, context: context, bytes: DreamRunEncoding.encode(request))
    }
  }
}

@Test func dreamRequestLegacyRenderingCannotOmitToolEvidence() throws {
  let fixture = try DecisionFixture(isToolEvidenceIncluded: true)
  defer { fixture.clean() }
  let context = try fixture.context()
  #expect(throws: DreamRunError.corruption) {
    try context.requestMessages(timestampMilliseconds: 123, rendering: .legacyV1)
  }
}


@Test func dreamScopeContractRequestReplaysExactVersionedBytes() throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let context = try fixture.context()
  for (schema, marker) in [(2, nil), (3, 2)] as [(Int, Int?)] {
    let saved = DreamRunEncoding.Request(
      schemaVersion: schema, runID: fixture.run.runID, generation: fixture.run.progress.generation,
      inputHash: fixture.run.inputHash.rawValue, contextHash: context.contextHash.rawValue,
      systemPrompt: context.systemPrompt(rendering: .scopeV2),
      messages: try context.requestMessages(timestampMilliseconds: 123, rendering: .scopeV2),
      renderingVersion: marker)
    let bytes = try DreamRunEncoding.encode(saved)
    let decoded = try DreamRunEncoding.decode(DreamRunEncoding.Request.self, bytes: bytes)
    let verified = try decoded.verifiedDomain(run: fixture.run, context: context, bytes: bytes)
    #expect(verified.rendering == .scopeV2)
    #expect(verified.request.requestHash == SourceDigest(bytes: bytes))
    #expect(verified.request.systemPrompt == saved.systemPrompt)
    #expect(verified.request.messages == saved.messages)
    let body = try #require(
      JSONSerialization.jsonObject(with: Data(saved.messages[0].text.utf8)) as? [String: Any])
    let scopes = try #require(body["scopes"] as? [[String: Any]])
    let reasons = try #require(scopes.first?["allowedNoChangeReasons"] as? [String])
    #expect(Set(reasons) == ["alreadyRepresented", "notDurable", "insufficientEvidence"])
    let destinations = try #require(scopes.first?["eligibleProposalScopes"] as? [[String: Any]])
    #expect(destinations.count == 1 && destinations.first?["kind"] as? String == "global")
    #expect(body["connectedWindowBindings"] == nil)
  }
}

@Test func dreamScopeContractFeedbackChainReplaysWithoutChangingArtifacts() throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let reader = try scopeContractAttemptReader(fixture)
  let before = try fixture.store.snapshot(fixture.store.root)
  var attempts: [Int] = []
  let verified = try reader.verify { attempts.append($0.attempt.number) }
  #expect(attempts == [0, 1])
  #expect(verified.attempt.number == 1)
  #expect(verified.selection?.modelID == "historical-replacement")
  let response = try #require(verified.response)
  switch DreamDecision.assess(
    response: response, context: reader.context, rendering: .scopeV2)
  {
  case .success(let result):
    #expect(result.plans.isEmpty && result.notes.count == 1)
  case .failure(let rejection):
    throw rejection.error
  }
  let replacement = try #require(verified.replacement)
  let effective = try reader.request(
    attempt: verified.attempt, replacement: replacement,
    replacementHash: verified.replacementHash, selection: try #require(verified.selection))
  #expect(effective.messages.count == 2)
  #expect(effective.messages[0] == reader.baseline.messages[0])
  #expect(
    effective.messages[1].text
      == String(
        decoding: try #require(replacement.feedback).bytes(), as: UTF8.self))
  #expect(try fixture.store.snapshot(fixture.store.root) == before)
}

@Test(arguments: ScopeAttemptMutation.allCases)
private func dreamScopeContractChainRejectsReboundTamperingWithoutWrites(
  mutation: ScopeAttemptMutation
) throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let reader = try scopeContractAttemptReader(fixture, mutation: mutation)
  let before = try fixture.store.snapshot(fixture.store.root)
  #expect(throws: DreamRunError.corruption) { try reader.verify() }
  #expect(try fixture.store.snapshot(fixture.store.root) == before)
}

@Test func dreamDecisionCorrectsBlueToGreenWithExactBytesAndMetadata() throws {
  let fixture = try DecisionFixture(document: decisionBlue)
  defer { fixture.clean() }
  let context = try fixture.context()
  let anchor = try #require(context.memoryCatalogue.first { $0.isEligible })
  #expect(anchor.start == 10 && anchor.end == decisionBlue.utf8.count)
  let source = context.primaryCatalogue[0].id
  let response = try fixture.response([decisionUpdate(source, anchor: anchor)], context: context)
  let before = try fixture.store.snapshot(fixture.store.root)
  let result = try DreamDecision.validate(response: response, context: context)
  let plan = try #require(result.plans.first)
  #expect(result.plans.count == 1 && result.notes.isEmpty)
  #expect(
    plan.replacement
      == Data("# Memory\n\nUse green buttons. [source: pi:one#u2/part/0; added: 2026-01-02]\n".utf8)
  )
  #expect(plan.base == fixture.run.approvedBase && plan.path == "MEMORY.md")
  #expect(plan.beforeDigest == SourceDigest(bytes: Data(decisionBlue.utf8)))
  #expect(plan.afterDigest == SourceDigest(bytes: plan.replacement))
  #expect(plan.anchors == [anchor] && plan.sources == [source])
  #expect(plan.contradictions.contains(anchor.documentHash.rawValue))
  #expect(plan.contradictions.contains("Replace the earlier preference."))
  #expect(!plan.reason.contains("removed-project") && !plan.reason.contains("rawRecordHash"))
  #expect(
    result.responseHash == response.responseHash
      && result.responseHash != SourceDigest(bytes: Data(response.response.text.utf8)))
  let replay = try DreamDecision.validate(response: response, context: context)
  #expect(replay.plans[0].replacement == plan.replacement)
  #expect(
    replay.plans[0].reason == plan.reason && replay.plans[0].contradictions == plan.contradictions)
  #expect(try fixture.store.snapshot(fixture.store.root) == before)
  #expect(MemoryDocument.failures(in: plan.replacement).isEmpty)
}

@Test func dreamDecisionAddsExactGlobalAndAbsentProjectPlansInPathOrder() throws {
  let fixture = try DecisionFixture(projectKeys: [decisionKey])
  defer { fixture.clean() }
  let context = try fixture.context(resolution: .project(key: decisionKey, isGlobalEligible: true))
  let source = context.primaryCatalogue[0].id
  let decisions = [decisionAdd(source, scope: .project(decisionKey)), decisionAdd(source)]
  let result = try DreamDecision.validate(
    response: fixture.response(decisions, context: context), context: context)
  #expect(result.plans.map(\.path) == ["MEMORY.md", "projects/\(decisionKey).md"])
  let expected = Data(
    "# Memory\n\n\nUse green buttons. [source: pi:one#u2/part/0; added: 2026-01-02]\n".utf8)
  #expect(result.plans.allSatisfy { $0.replacement == expected && $0.contradictions.isEmpty })
  #expect(result.plans[1].beforeDigest == nil)
  #expect(result.plans.allSatisfy { $0.base == fixture.run.approvedBase })
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.store.repo.appendingPathComponent("projects").path))
}

@Test func dreamDecisionUsesOriginalOffsetsForMultipleAndDuplicateTextBlocks() throws {
  let block = "Use blue buttons. [source: pi:one#u1/part/0; added: 2026-01-01]\n"
  let original = "# Memory\n\n" + block + "\n" + block
  let fixture = try DecisionFixture(document: original)
  defer { fixture.clean() }
  let context = try fixture.context()
  let anchors = context.memoryCatalogue.filter(\.isEligible)
  try #require(anchors.count == 2 && anchors[0].before == anchors[1].before)
  let source = context.primaryCatalogue[0].id
  let secondOnly = try DreamDecision.validate(
    response: fixture.response([decisionUpdate(source, anchor: anchors[1])], context: context),
    context: context
  ).plans[0]
  #expect(
    secondOnly.replacement
      == Data(
        ("# Memory\n\n" + block
          + "\nUse green buttons. [source: pi:one#u2/part/0; added: 2026-01-02]\n").utf8))
  let multiple = try DreamDecision.validate(
    response: fixture.response(
      [
        decisionUpdate(source, anchor: anchors[0], text: "First replacement is longer."),
        decisionUpdate(source, anchor: anchors[1], text: "Second."),
      ], context: context), context: context
  ).plans[0]
  #expect(
    multiple.replacement
      == Data(
        "# Memory\n\nFirst replacement is longer. [source: pi:one#u2/part/0; added: 2026-01-02]\n\nSecond. [source: pi:one#u2/part/0; added: 2026-01-02]\n"
          .utf8))
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(
      response: fixture.response(
        [decisionUpdate(source, anchor: anchors[0]), decisionUpdate(source, anchor: anchors[0])],
        context: context), context: context)
  }
}

@Test(arguments: [
  "hash", "before", "start", "end", "empty", "partialUnicode", "heading", "missingConflict",
  "duplicateConflict",
])
func dreamDecisionRejectsInvalidAnchorsAndContradictions(kind: String) throws {
  let fixture = try DecisionFixture(
    document: decisionBlue.replacingOccurrences(of: "blue", with: "blué"))
  defer { fixture.clean() }
  let context = try fixture.context()
  let anchor = try #require(context.memoryCatalogue.first { $0.isEligible })
  var decision = decisionUpdate(context.primaryCatalogue[0].id, anchor: anchor)
  var wire = decision["anchor"] as! [String: Any]
  switch kind {
  case "hash": wire["documentHash"] = String(repeating: "0", count: 64)
  case "before": wire["before"] = "Wrong"
  case "start": wire["start"] = anchor.start + 1
  case "end": wire["end"] = anchor.end - 1
  case "empty":
    wire["end"] = anchor.start
    wire["before"] = ""
  case "partialUnicode":
    wire["start"] = 30
    wire["before"] = "é"
  case "heading": wire = decisionAnchor(context.memoryCatalogue.first { !$0.isEligible }!)
  case "missingConflict": decision["contradictions"] = []
  default:
    let conflicts = decision["contradictions"] as! [[String: Any]]
    decision["contradictions"] = conflicts + conflicts
  }
  decision["anchor"] = wire
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(
      response: fixture.response([decision], context: context), context: context)
  }
}

@Test(arguments: [
  "missing", "duplicate", "cwdMismatch", "badKey", "extraProject", "missingProject",
])
func dreamDecisionContextRejectsScopeCatalogueMismatch(kind: String) throws {
  let fixture = try DecisionFixture(projectKeys: kind == "extraProject" ? [decisionKey] : [])
  defer { fixture.clean() }
  let evidence = fixture.run.batch.evidence[0]
  let normal = PinnedEvidenceScope(
    source: evidence.id, projectScope: evidence.projectScope,
    resolution: .outsideGit(isGlobalEligible: true))
  let scopes: [PinnedEvidenceScope]
  switch kind {
  case "missing": scopes = []
  case "duplicate": scopes = [normal, normal]
  case "cwdMismatch":
    scopes = [
      PinnedEvidenceScope(source: evidence.id, projectScope: "/wrong", resolution: .unresolved)
    ]
  case "badKey":
    scopes = [
      PinnedEvidenceScope(
        source: evidence.id, projectScope: evidence.projectScope,
        resolution: .project(key: evidence.projectScope!, isGlobalEligible: true))
    ]
  case "missingProject":
    scopes = [
      PinnedEvidenceScope(
        source: evidence.id, projectScope: evidence.projectScope,
        resolution: .project(key: decisionKey, isGlobalEligible: true))
    ]
  default: scopes = [normal]
  }
  #expect(throws: (any Error).self) { try fixture.context(scopes: scopes) }
}

@Test func dreamDecisionScopeEligibilityHasNoGlobalFallback() throws {
  let fixture = try DecisionFixture(projectKeys: [decisionKey])
  defer { fixture.clean() }
  let context = try fixture.context(resolution: .project(key: decisionKey, isGlobalEligible: false))
  let source = context.primaryCatalogue[0].id
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(
      response: fixture.response([decisionAdd(source)], context: context), context: context)
  }
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(
      response: fixture.response(
        [decisionAdd(source, scope: .project(decisionOtherKey))], context: context),
      context: context)
  }
  #expect(
    try DreamDecision.validate(
      response: fixture.response(
        [decisionAdd(source, scope: .project(decisionKey))], context: context), context: context
    ).plans.count == 1)
  let outside = try DecisionFixture()
  defer { outside.clean() }
  let denied = try outside.context(resolution: .outsideGit(isGlobalEligible: false))
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(
      response: outside.response([decisionAdd(denied.primaryCatalogue[0].id)], context: denied),
      context: denied)
  }
  let unresolved = try outside.context(resolution: .unresolved)
  let unresolvedSource = unresolved.primaryCatalogue[0].id
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(
      response: outside.response([decisionAdd(unresolvedSource)], context: unresolved),
      context: unresolved)
  }
  #expect(
    try DreamDecision.validate(
      response: outside.response(
        [decisionNoChange([unresolvedSource], code: "unresolvedScope")], context: unresolved),
      context: unresolved
    ).plans.isEmpty)
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(
      response: outside.response([decisionNoChange([unresolvedSource])], context: unresolved),
      context: unresolved)
  }
}

@Test func dreamDecisionRejectsNonPrimarySupport() throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let context = try fixture.context()
  for kind in ["picked", "generated", "assistant", "child", "unknown", "owner", "part"] {
    var decision = decisionAdd(context.primaryCatalogue[0].id)
    decision["sources"] = [
      [
        "session": kind == "child" ? "child" : "one",
        "entry": kind == "part" ? "u2" : kind == "child" ? "childtext" : kind,
        "part": kind == "part" ? 1 : 0,
      ]
    ]
    #expect(throws: (any Error).self, "case: \(kind)") {
      try DreamDecision.validate(
        response: fixture.response([decision], context: context), context: context)
    }
  }
}

@Test func dreamDecisionCoverageRequiresOneTerminalDispositionOrProposals() throws {
  let fixture = try DecisionFixture(texts: ["First", "Second"])
  defer { fixture.clean() }
  let context = try fixture.context()
  let sources = context.primaryCatalogue.map(\.id)
  for decisions in [
    [], [decisionAdd(sources[0])], [decisionNoChange([])],
    [decisionNoChange(sources), decisionAdd(sources[0])],
    [decisionAdd(sources[0]), decisionNoChange(sources)],
    [decisionNoChange(sources), decisionNoChange([sources[0]])],
  ] {
    #expect(throws: (any Error).self) {
      try DreamDecision.validate(
        response: fixture.response(decisions, context: context), context: context)
    }
  }
  let noChange = try DreamDecision.validate(
    response: fixture.response([decisionNoChange(sources)], context: context), context: context)
  #expect(noChange.plans.isEmpty && noChange.notes.count == 1)
  #expect(fixture.run.progress.generation == 0 && fixture.run.progress.positions.isEmpty)
  let empty = try DecisionFixture(texts: [])
  defer { empty.clean() }
  let emptyContext = try empty.context()
  let result = try DreamDecision.validate(
    response: empty.response([], context: emptyContext), context: emptyContext)
  #expect(result.plans.isEmpty && result.notes.isEmpty && empty.run.progress.generation == 0)
}

@Test func dreamDecisionOwnerNoteUsesPinnedBytesAndCreatesNoPlan() throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let bytes = Data("Booleans use names with an is prefix.".utf8)
  let owner = try PinnedOwnerInput(
    key: "code-style", reference: "docs/code-style.md", scope: .global, bytes: bytes)
  let context = try fixture.context(owners: [owner])
  let before = try fixture.store.snapshot(fixture.store.root)
  let result = try DreamDecision.validate(
    response: fixture.response(
      [decisionOwnerNote(context.primaryCatalogue[0].id, owner: owner)], context: context),
    context: context)
  #expect(result.plans.isEmpty && result.notes.count == 1)
  #expect(result.notes[0].ownerReference == owner.reference)
  #expect(result.notes[0].owner?.before == String(decoding: bytes, as: UTF8.self))
  #expect(owner.bytes == bytes && context.owners[0].bytes == bytes)
  #expect(try fixture.store.snapshot(fixture.store.root) == before)
  #expect(throws: (any Error).self) { try fixture.context(owners: [owner, owner]) }
  for reference in ["", "bad;name", "bad[name]", "bad\nname"] {
    #expect(throws: (any Error).self) {
      try PinnedOwnerInput(key: reference, reference: "safe", scope: .global, bytes: bytes)
    }
  }
}

@Test(arguments: ["ownerNote", "contradiction"])
func dreamDecisionReportsOwnerSliceByteMismatchWithoutRepair(kind: String) throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let text = "# Synthetic owner"
  let owner = try PinnedOwnerInput(
    key: "style", reference: "docs/style.md", scope: .global,
    bytes: Data((text + "\n\nKeep this rule.\n").utf8))
  let context = try fixture.context(owners: [owner])
  let source = context.primaryCatalogue[0].id
  var anchor = decisionOwnerNote(source, owner: owner)["owner"] as! [String: Any]
  anchor["before"] = text
  func decision(_ end: Int) -> [String: Any] {
    var slice = anchor
    slice["end"] = end
    if kind == "ownerNote" {
      var note = decisionOwnerNote(source, owner: owner)
      note["owner"] = slice
      return note
    }
    var add = decisionAdd(source)
    add["contradictions"] = [
      ["kind": "owner", "anchor": slice, "explanation": "The owner contains the rule."]
    ]
    return add
  }
  let valid = try DreamDecision.validate(
    response: fixture.response([decision(text.utf8.count)], context: context), context: context)
  #expect(kind == "ownerNote" ? valid.notes.count == 1 : valid.plans.count == 1)
  for end in [text.utf8.count - 1, text.utf8.count + 2] {
    #expect(throws: DreamDecisionError.decision(
      index: 0, category: "owner anchor bytes do not match pinned slice")) {
      try DreamDecision.validate(
        response: fixture.response([decision(end)], context: context), context: context)
    }
  }
}

@Test(arguments: ["key", "hash", "before", "range", "scope", "path"])
func dreamDecisionRejectsForgedOwnerReferences(kind: String) throws {
  let fixture = try DecisionFixture(projectKeys: [decisionKey])
  defer { fixture.clean() }
  let owner = try PinnedOwnerInput(
    key: "style", reference: "docs/style.md",
    scope: kind == "scope" ? .project(decisionKey) : .global, bytes: Data("Exact é owner".utf8))
  let context = try fixture.context(
    resolution: .project(key: decisionKey, isGlobalEligible: true), owners: [owner])
  var decision = decisionOwnerNote(context.primaryCatalogue[0].id, owner: owner)
  var anchor = decision["owner"] as! [String: Any]
  switch kind {
  case "key": anchor["key"] = "missing"
  case "hash": anchor["ownerHash"] = String(repeating: "0", count: 64)
  case "before": anchor["before"] = "Wrong"
  case "range": anchor["start"] = 7
  case "path": anchor["path"] = "docs/new-owner.md"
  default: decision["sources"] = [["session": "outside", "entry": "u", "part": 0]]
  }
  decision["owner"] = anchor
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(
      response: fixture.response([decision], context: context), context: context)
  }
}

private func decisionUnknownFields(_ value: Any) -> [Any] {
  if let object = value as? [String: Any] {
    var changed = object
    changed["forged"] = "unsupported"
    var variants: [Any] = [changed]
    for (key, child) in object {
      for replacement in decisionUnknownFields(child) {
        var changed = object
        changed[key] = replacement
        variants.append(changed)
      }
    }
    return variants
  }
  if let array = value as? [Any] {
    return array.indices.flatMap { index in
      decisionUnknownFields(array[index]).map { child in
        var changed = array
        changed[index] = child
        return changed as Any
      }
    }
  }
  return []
}

@Test func dreamDecisionClosedSchemaRejectsUnknownFieldsAtEveryObjectDepth() throws {
  let fixture = try DecisionFixture(document: decisionBlue)
  defer { fixture.clean() }
  let owner = try PinnedOwnerInput(
    key: "style", reference: "docs/style.md", scope: .global, bytes: Data("Rule".utf8))
  let context = try fixture.context(owners: [owner])
  let source = context.primaryCatalogue[0].id
  let anchor = context.memoryCatalogue.first { $0.isEligible }!
  var add = decisionAdd(source)
  add["contradictions"] = [
    [
      "kind": "primary", "source": decisionSource(source), "explanation": "Known primary conflict.",
    ],
    ["kind": "memory", "anchor": decisionAnchor(anchor), "explanation": "Known memory conflict."],
    [
      "kind": "owner", "anchor": decisionOwnerNote(source, owner: owner)["owner"]!,
      "explanation": "Known owner conflict.",
    ],
  ]
  for decision in [
    add, decisionUpdate(source, anchor: anchor), decisionNoChange([source]),
    decisionOwnerNote(source, owner: owner),
  ] {
    let root: [String: Any] = [
      "schemaVersion": 1, "contextHash": context.contextHash.rawValue, "decisions": [decision],
    ]
    for invalid in decisionUnknownFields(root) {
      let text = String(
        decoding: try JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)
      #expect(throws: (any Error).self) {
        try DreamDecision.validate(response: fixture.response(text: text), context: context)
      }
    }
  }
}

@Test func dreamDecisionRejectsMalformedClosedResponses() throws {
  let fixture = try DecisionFixture(document: decisionBlue)
  defer { fixture.clean() }
  let context = try fixture.context()
  let source = context.primaryCatalogue[0].id
  let anchor = context.memoryCatalogue.first { $0.isEligible }!
  for kind in [
    "duplicate", "escapedDuplicate", "trailing", "fence", "null", "version", "float", "negative",
    "kind", "scope", "emptySources", "sourceDate", "deep",
  ] {
    var response = try fixture.response([decisionUpdate(source, anchor: anchor)], context: context)
      .response.text
    switch kind {
    case "duplicate":
      response = response.replacingOccurrences(
        of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1")
    case "escapedDuplicate":
      response = response.replacingOccurrences(
        of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schema\\u0056ersion\":1")
    case "trailing": response += " {}"
    case "fence": response = "```json\n" + response + "\n```"
    case "null":
      response = response.replacingOccurrences(
        of: "\"text\":\"Use green buttons.\"", with: "\"text\":null")
    case "version":
      response = response.replacingOccurrences(
        of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
    case "float":
      response = response.replacingOccurrences(of: "\"start\":10", with: "\"start\":10.0")
    case "negative":
      response = response.replacingOccurrences(of: "\"start\":10", with: "\"start\":-1")
    case "kind":
      response = response.replacingOccurrences(
        of: "\"kind\":\"update\"", with: "\"kind\":\"approved\"")
    case "scope":
      response = response.replacingOccurrences(
        of: "\"kind\":\"global\"", with: "\"kind\":\"unknown\"")
    case "emptySources":
      var decision = decisionAdd(source)
      decision["sources"] = []
      response = try fixture.response([decision], context: context).response.text
    case "sourceDate":
      var decision = decisionAdd(source)
      decision["addedDate"] = "2026-01-02"
      response = try fixture.response([decision], context: context).response.text
    default: response = String(repeating: "[", count: 20) + "0" + String(repeating: "]", count: 20)
    }
    #expect(throws: (any Error).self, "case: \(kind)") {
      try DreamDecision.validate(response: fixture.response(text: response), context: context)
    }
  }
}

@Test func dreamDecisionRejectsUnsafeModelProse() throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let context = try fixture.context()
  for (kind, text) in [
    ("LF", "line\nnext"), ("CR", "line\rnext"), ("separator", "line\u{2028}next"),
    ("NUL", "NUL\0"), ("source", "[SOURCE: forged]"),
    ("date", "[added: 2026-01-01]"), ("empty", " "), ("tab", "tab\there"),
  ] {
    #expect(throws: (any Error).self, "case: \(kind)") {
      try DreamDecision.validate(
        response: fixture.response(
          [decisionAdd(context.primaryCatalogue[0].id, text: text)], context: context),
        context: context)
    }
  }
}

@Test func dreamDecisionEscapesMarkdownAndDoesNotTrimProse() throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let context = try fixture.context()
  let result = try DreamDecision.validate(
    response: fixture.response(
      [decisionAdd(context.primaryCatalogue[0].id, text: "  # Use [green]* <buttons> & more.  ")],
      context: context), context: context)
  #expect(
    String(decoding: result.plans[0].replacement, as: UTF8.self).contains(
      "&#32;&#32;\\# Use \\[green\\]\\* \\<buttons\\> \\& more.   [source:"))
}

@Test func dreamDecisionContextChangesBlockSavedResponse() throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let context = try fixture.context()
  let response = try fixture.response(
    [decisionAdd(context.primaryCatalogue[0].id)], context: context)
  let owner = try PinnedOwnerInput(
    key: "style", reference: "docs/style.md", scope: .global, bytes: Data("Rule".utf8))
  for changed in [
    try fixture.context(date: "2026-01-03"),
    try fixture.context(resolution: .outsideGit(isGlobalEligible: false)),
    try fixture.context(owners: [owner]),
    try fixture.context(limits: DreamDecisionLimits(maximumDecisions: 255)),
  ] {
    #expect(changed.contextHash != context.contextHash)
    #expect(throws: (any Error).self) {
      try DreamDecision.validate(response: response, context: changed)
    }
  }
  #expect(try fixture.context().contextHash == context.contextHash)
  for date in ["2026-02-29", "2026-01-02\n", "0000-01-01"] {
    #expect(throws: (any Error).self) { try fixture.context(date: date) }
  }
}

@Test(arguments: ["\n", "\r\n", "\r", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"])
func dreamDecisionNativeBlockRangesKeepOriginalLineEndings(ending: String) throws {
  let raw =
    ("# Memory\n\n" + fact("> First 🐢\nlazy continuation") + "\n"
    + fact("- Item\n  continuation\nlazy continuation") + "\n[rule]: docs/owner.md\n  \"Title\"\n")
    .replacingOccurrences(of: "\n", with: ending)
  let fixture = try DecisionFixture(document: raw)
  defer { fixture.clean() }
  let context = try fixture.context()
  #expect(context.snapshot.documents[0].diagnostics.isEmpty)
  let anchors = context.memoryCatalogue.filter(\.isEligible)
  try #require(anchors.count == 2)
  #expect(anchors[0].before.hasPrefix("> First") && anchors[1].before.hasPrefix("- Item"))
  let anchor = anchors[0]
  let plan = try DreamDecision.validate(
    response: fixture.response(
      [decisionUpdate(context.primaryCatalogue[0].id, anchor: anchor)], context: context),
    context: context
  ).plans[0]
  let original = Data(raw.utf8)
  let inserted = Data(
    ("Use green buttons. [source: pi:one#u2/part/0; added: 2026-01-02]" + ending).utf8)
  let expected =
    Data(original.prefix(anchor.start)) + inserted
    + Data(original.suffix(original.count - anchor.end))
  #expect(plan.replacement == expected)
}

@Test func dreamDecisionNativeCatalogueReportsUnsupportedAndOverlappingRanges() throws {
  let raw =
    "Setext\n===\n\n[rule]: docs/owner.md\n  \"A multiline\n  title\"\n\n<!-- Invisible -->\n\n```\nCode\n```\n\n"
    + fact("> Outer\n>> Nested\n> outer continuation")
  let fixture = try DecisionFixture(document: raw)
  defer { fixture.clean() }
  let context = try fixture.context()
  #expect(context.memoryCatalogue.contains { $0.before == "Setext\n===\n" && !$0.isEligible })
  #expect(context.memoryCatalogue.contains { $0.before.hasPrefix("[rule]:") && !$0.isEligible })
  #expect(context.memoryCatalogue.contains { $0.before.contains("Invisible") && !$0.isEligible })
  #expect(
    context.memoryCatalogue.filter(\.isEligible).allSatisfy { anchor in
      !context.memoryCatalogue.contains { other in
        anchor != other && (anchor.start..<anchor.end).overlaps(other.start..<other.end)
      }
    })
  for anchor in context.memoryCatalogue.filter({ !$0.isEligible }) {
    #expect(throws: (any Error).self) {
      try DreamDecision.validate(
        response: fixture.response(
          [decisionUpdate(context.primaryCatalogue[0].id, anchor: anchor)], context: context),
        context: context)
    }
  }
}

@Test func dreamDecisionAcceptsTypedSkillArgumentsAndTypedAnswerPartsOnly() throws {
  let fixture = try DecisionFixture(
    texts: [
      "<skill name=\"test\" location=\"/synthetic/test/SKILL.md\">\nSkill body\n</skill>\n\nExact arguments"
    ], isAnswerIncluded: true)
  defer { fixture.clean() }
  let context = try fixture.context()
  #expect(
    Set(context.primaryCatalogue.map { $0.kind.rawValue })
      == Set(["typedSkillArguments", "answered"]))
  let answered = context.primaryCatalogue.filter { $0.kind == .answered }
  #expect(answered.map { $0.id.part } == [0, 2])
  let decisions = context.primaryCatalogue.map { decisionAdd($0.id) }
  let result = try DreamDecision.validate(
    response: fixture.response(decisions, context: context), context: context)
  #expect(result.plans.count == 1 && result.plans[0].sources.count == 3)
  var forged = decisions
  forged[0]["sources"] = [["session": "one", "entry": "answer", "part": 1]]
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(
      response: fixture.response(forged, context: context), context: context)
  }
}

@Test func dreamDecisionPinnedLinkedProjectKeyIsNotTheSourceDirectory() throws {
  let projectFixture = try Fixture()
  defer { projectFixture.clean() }
  let project = try projectFixture.project("project")
  let linked = projectFixture.root.appendingPathComponent("linked")
  _ = try projectFixture.git(["worktree", "add", "--detach", linked.path], at: project)
  let key = try #require(try MemoryStore.projectKey(cwd: linked))
  #expect(try MemoryStore.projectKey(cwd: project) == key)
  let fixture = try DecisionFixture(projectKeys: [key], cwd: linked.path)
  defer { fixture.clean() }
  let context = try fixture.context(resolution: .project(key: key, isGlobalEligible: false))
  let result = try DreamDecision.validate(
    response: fixture.response(
      [
        decisionAdd(context.primaryCatalogue[0].id, scope: .project(key))
      ], context: context), context: context)
  #expect(result.plans[0].path == "projects/\(key).md")
  #expect(context.scopes[0].projectScope == linked.path)
  #expect(!result.plans[0].reason.contains(linked.path))
}

@Test func dreamDecisionExactBeforeBytesRejectCanonicalUnicodeEquivalence() throws {
  let fixture = try DecisionFixture(
    document: decisionBlue.replacingOccurrences(of: "blue", with: "blué"))
  defer { fixture.clean() }
  let context = try fixture.context()
  let anchor = context.memoryCatalogue.first { $0.isEligible }!
  var decision = decisionUpdate(context.primaryCatalogue[0].id, anchor: anchor)
  var wire = decision["anchor"] as! [String: Any]
  let decomposed = anchor.before.replacingOccurrences(of: "é", with: "e\u{0301}")
  #expect(decomposed == anchor.before && Data(decomposed.utf8) != Data(anchor.before.utf8))
  wire["before"] = decomposed
  decision["anchor"] = wire
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(
      response: fixture.response([decision], context: context), context: context)
  }
}

@Test func dreamDecisionOwnerAndContradictionScopesCannotCrossProjects() throws {
  let fixture = try DecisionFixture(
    document: decisionBlue, texts: ["One", "Two"], projectKeys: [decisionKey, decisionOtherKey])
  defer { fixture.clean() }
  let scopes = fixture.run.batch.evidence.enumerated().map { index, evidence in
    PinnedEvidenceScope(
      source: evidence.id, projectScope: evidence.projectScope,
      resolution: .project(key: index == 0 ? decisionKey : decisionOtherKey, isGlobalEligible: true)
    )
  }
  let owner = try PinnedOwnerInput(
    key: "project-owner", reference: "docs/project-owner.md", scope: .project(decisionKey),
    bytes: Data("Pinned rule".utf8))
  let context = try fixture.context(scopes: scopes, owners: [owner])
  let sources = context.primaryCatalogue.map(\.id)
  let otherNote = decisionOwnerNote(sources[1], owner: owner)
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(
      response: fixture.response([decisionNoChange([sources[0]]), otherNote], context: context),
      context: context)
  }
  let ownerConflict: [String: Any] = [
    "kind": "owner", "anchor": decisionOwnerNote(sources[0], owner: owner)["owner"]!,
    "explanation": "Known conflict.",
  ]
  for scope in [DreamMemoryScope.global, .project(decisionOtherKey)] {
    var add = decisionAdd(sources[0], scope: scope)
    add["contradictions"] = [ownerConflict]
    #expect(throws: (any Error).self) {
      try DreamDecision.validate(
        response: fixture.response([add, decisionNoChange([sources[1]])], context: context),
        context: context)
    }
  }
  var projectAdd = decisionAdd(sources[0], scope: .project(decisionKey))
  projectAdd["contradictions"] = [
    ["kind": "primary", "source": decisionSource(sources[1]), "explanation": "Wrong project."]
  ]
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(
      response: fixture.response([projectAdd, decisionNoChange([sources[1]])], context: context),
      context: context)
  }
}

@Test func dreamDecisionRunAndSnapshotBindingsRejectChangedInput() throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let context = try fixture.context()
  let response = try fixture.response(
    [decisionAdd(context.primaryCatalogue[0].id)], context: context)
  let differentSelection = try DreamSelectedCall(
    provider: "synthetic", modelID: "other", thinkingLevel: "off")
  let bindingHash = SourceDigest(bytes: Data("synthetic".utf8))
  let changedInput = try DreamRunEncoding.input(
    runID: fixture.run.runID,
    context: DreamRunContext(
      selection: differentSelection, currentApprovedBase: fixture.run.approvedBase),
    bindingHash: bindingHash, progress: fixture.run.progress, batch: fixture.run.batch,
    limits: DreamRunLimits())
  #expect(throws: DreamRunError.corruption) {
    try DreamRunEncoding.frozen(
      bytes: changedInput, runID: fixture.run.runID, inputHash: fixture.run.inputHash,
      bindingHash: bindingHash, limits: DreamRunLimits())
  }
  let otherRun = try DreamRunEncoding.frozen(
    bytes: changedInput, runID: fixture.run.runID, inputHash: SourceDigest(bytes: changedInput),
    bindingHash: bindingHash, limits: DreamRunLimits())
  let changed = DurableDreamResponse(
    run: otherRun, response: response.response,
    responseHash: response.responseHash, isReplay: true, isBaseCurrent: false)
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(response: changed, context: context)
  }
  let owner1 = try PinnedOwnerInput(
    key: "style", reference: "docs/style.md", scope: .global, bytes: Data("Old".utf8))
  let owner2 = try PinnedOwnerInput(
    key: "style", reference: "docs/style.md", scope: .global, bytes: Data("New".utf8))
  #expect(
    try fixture.context(owners: [owner1]).contextHash
      != fixture.context(owners: [owner2]).contextHash)
  try fixture.store.write(fact("Different snapshot"), path: "MEMORY.md")
  try fixture.store.commit()
  let snapshot = try fixture.store.store.decisionSnapshot(
    base: fixture.store.store.approvedCommit(), projectKeys: [])
  #expect(throws: (any Error).self) {
    try DreamDecisionContext(
      run: fixture.run, snapshot: snapshot, scopes: context.scopes,
      owners: [], addedDate: context.addedDate)
  }
}

@Test func dreamDecisionNamedBoundsAcceptExactAndRejectOneOverWithoutTrimming() throws {
  let fixture = try DecisionFixture(
    document: decisionBlue, texts: ["First", "Second"],
    projectKeys: [decisionKey, decisionOtherKey])
  defer { fixture.clean() }
  let scopes = fixture.run.batch.evidence.enumerated().map { index, evidence in
    PinnedEvidenceScope(
      source: evidence.id, projectScope: evidence.projectScope,
      resolution: .project(key: index == 0 ? decisionKey : decisionOtherKey, isGlobalEligible: true)
    )
  }
  let owners = try ["one", "two"].map {
    try PinnedOwnerInput(
      key: $0, reference: "docs/owner-\($0).md", scope: .global, bytes: Data("Owner \($0)".utf8))
  }
  let context = try fixture.context(scopes: scopes, owners: owners)
  let source = context.primaryCatalogue[0].id
  let anchor = context.memoryCatalogue.first { $0.isEligible }!
  var update = decisionUpdate(source, anchor: anchor)
  update["sources"] = context.primaryCatalogue.map { decisionSource($0.id) }
  var conflicts = update["contradictions"] as! [[String: Any]]
  conflicts += [
    [
      "kind": "primary", "source": decisionSource(source), "explanation": "Known primary conflict.",
    ],
    [
      "kind": "owner", "anchor": decisionOwnerNote(source, owner: owners[0])["owner"]!,
      "explanation": "Known owner conflict.",
    ],
  ]
  update["contradictions"] = conflicts
  let decisions = [update, decisionAdd(source, scope: .project(decisionKey))]
  let response = try fixture.response(decisions, context: context)
  let result = try DreamDecision.validate(response: response, context: context)
  let batch = fixture.run.batch
  let recordBytes = batch.exactSourceRecords.reduce(0) { $0 + ($1.bytes?.count ?? 0) }
  let frozenBytes =
    recordBytes
    + batch.evidence.reduce(0) {
      $0 + $1.exactText.utf8.count + ($1.agentContext?.utf8.count ?? 0)
        + ($1.projectScope?.utf8.count ?? 0)
    }
    + batch.selections.reduce(0) {
      $0 + $1.question.utf8.count + $1.agentWrittenSelectedLabels.reduce(0) { $0 + $1.utf8.count }
    }
  let maxima: [String: Int] = [
    "response": response.response.text.utf8.count, "frozen": frozenBytes,
    "layoutBytes": fixture.snapshot.layoutByteCount,
    "snapshot": decisionBlue.utf8.count, "document": decisionBlue.utf8.count,
    "projects": 2, "owners": 2, "ownerTotal": owners.reduce(0) { $0 + $1.bytes.count },
    "ownerSingle": owners.map { $0.bytes.count }.max()!,
    "ownerReference": owners.map { $0.reference.utf8.count }.max()!,
    "decisions": 2, "sources": 2, "contradictions": 3, "references": 7,
    "text": "Replace the earlier preference.".utf8.count, "before": anchor.before.utf8.count,
    "plans": 2, "replacement": result.plans.map { $0.replacement.count }.max()!,
    "output": result.plans.reduce(0) { $0 + $1.replacement.count },
    "metadata": result.plans.flatMap { [$0.reason.utf8.count, $0.contradictions.utf8.count] }
      .max()!,
  ]
  for (name, maximum) in maxima {
    let exactContext = try fixture.context(
      scopes: scopes, owners: owners, limits: decisionLimits([name: maximum]))
    let exactResponse = try fixture.response(decisions, context: exactContext)
    let exact = try DreamDecision.validate(response: exactResponse, context: exactContext)
    #expect(exact.plans.map(\.replacement) == result.plans.map(\.replacement), "\(name)")
    #expect(throws: (any Error).self) {
      let overContext = try fixture.context(
        scopes: scopes, owners: owners, limits: decisionLimits([name: maximum - 1]))
      return try DreamDecision.validate(
        response: fixture.response(decisions, context: overContext), context: overContext)
    }
  }
  for name in [
    "layoutEntries", "layoutBytes", "snapshot", "document", "projects", "owners", "ownerTotal",
    "ownerSingle", "ownerReference", "decisions", "sources", "contradictions", "references", "text",
    "before", "plans", "replacement", "output", "metadata", "response", "frozen",
  ] {
    #expect(throws: (any Error).self) { try decisionLimits([name: 0]) }
  }
}

@Test func dreamDecisionGeneratedRangesAreRootParagraphsWithoutTrimming() throws {
  let fixture = try DecisionFixture(document: decisionBlue)
  defer { fixture.clean() }
  let context = try fixture.context()
  let source = context.primaryCatalogue[0].id
  let anchor = try #require(context.memoryCatalogue.first { $0.isEligible })
  for text in [
    "    Use green buttons.", "     Use green buttons.  ", "  1. Use green buttons.",
    "   1) Use green buttons.", "    1. Use green buttons.", "     1) Use green buttons.",
    "1. Use green buttons.", "1) Use green buttons.", "\u{00A0}Use green buttons.",
    "\u{2003}Use green buttons.  ",
  ] {
    for decision in [
      decisionAdd(source, text: text), decisionUpdate(source, anchor: anchor, text: text),
    ] {
      let plan = try DreamDecision.validate(
        response: fixture.response([decision], context: context), context: context
      ).plans[0]
      let blocks = MemoryDocument.nativeBlockRanges(in: plan.replacement)
      let generated = try #require(blocks.last)
      #expect(generated.isRootParagraph, "text: \(text)")
      let parsed = try AttributedString(
        markdown: String(decoding: plan.replacement.subdata(in: generated.range), as: UTF8.self))
      #expect(String(parsed.characters) == text + " [source: pi:one#u2/part/0; added: 2026-01-02]")
      #expect(plan.reason.contains("text"))
      #expect(MemoryDocument.failures(in: plan.replacement).isEmpty)
    }
  }
}

@Test func dreamDecisionRejectsAdditionsAbsorbedByUnclosedNativeFences() throws {
  let identical = "Use green buttons. [source: pi:one#u2/part/0; added: 2026-01-02]\n"
  for fence in ["```", "~~~"] {
    let raw =
      "# Memory\n\n" + identical + "\n" + fence
      + "\nExisting code [source: owner; added: 2026-01-01]\n"
    let fixture = try DecisionFixture(document: raw)
    defer { fixture.clean() }
    let context = try fixture.context()
    #expect(context.snapshot.documents[0].diagnostics.isEmpty)
    #expect(throws: (any Error).self, "fence: \(fence)") {
      try DreamDecision.validate(
        response: fixture.response([decisionAdd(context.primaryCatalogue[0].id)], context: context),
        context: context)
    }
  }
}

@Test func dreamDecisionGeneratedRangesStayOutsideAdjacentContainers() throws {
  for raw in [
    "# Memory\n\n" + fact("> Quoted") + "\n" + decisionBlue.dropFirst(10),
    "# Memory\n\n" + fact("- Listed") + "\n" + decisionBlue.dropFirst(10),
    "# Memory\n\n```\nCode [source: owner; added: 2026-01-01]\n```\n\n"
      + decisionBlue.dropFirst(10),
  ] {
    let fixture = try DecisionFixture(document: raw)
    defer { fixture.clean() }
    let context = try fixture.context()
    let anchor = try #require(context.memoryCatalogue.last { $0.isEligible })
    let source = context.primaryCatalogue[0].id
    let plan = try DreamDecision.validate(
      response: fixture.response(
        [
          decisionUpdate(source, anchor: anchor), decisionAdd(source, text: "    Another rule."),
        ], context: context), context: context
    ).plans[0]
    #expect(plan.replacement.prefix(anchor.start) == Data(raw.utf8).prefix(anchor.start))
    #expect(
      MemoryDocument.nativeBlockRanges(in: plan.replacement).suffix(2).allSatisfy {
        $0.isRootParagraph
      }
    )
  }
}

@Test func memoryDocumentOverlapFlagsMatchLiteralPairwiseReference() {
  let candidates = (0...5).flatMap { start in (start...6).map { start..<$0 } }
  var sets: [[Range<Int>]] = [[], candidates, [0..<0, 0..<0], [0..<4, 2..<2, 4..<5]]
  for first in candidates {
    for second in candidates { sets.append([first, second]) }
  }
  for seed in 0..<64 {
    sets.append((0..<32).map { candidates[(seed * 17 + $0 * 11) % candidates.count] })
  }
  for ranges in sets {
    let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
    let expected = sorted.indices.map { index in
      sorted.indices.contains { $0 != index && sorted[$0].overlaps(sorted[index]) }
    }
    #expect(MemoryDocument.overlapFlags(in: sorted) == expected, "ranges: \(sorted)")
  }
}

@Test func dreamDecisionScopeLookupKeepsReorderedCoverageAndExactDirectoryBytes() throws {
  let fixture = try DecisionFixture(texts: ["One", "Two", "Three"], cwd: "/synthetic/café")
  defer { fixture.clean() }
  let scopes = fixture.run.batch.evidence.map {
    PinnedEvidenceScope(
      source: $0.id, projectScope: $0.projectScope,
      resolution: .outsideGit(isGlobalEligible: true))
  }
  let context = try fixture.context(scopes: Array(scopes.reversed()))
  #expect(context.contextHash == (try fixture.context(scopes: scopes)).contextHash)
  #expect(
    try DreamDecision.validate(
      response: fixture.response(
        context.primaryCatalogue.map { decisionAdd($0.id) }, context: context),
      context: context
    ).plans[0].sources.count == 3)
  var changed = scopes
  let decomposed = "/synthetic/cafe\u{0301}"
  #expect(decomposed == scopes[0].projectScope)
  #expect(Data(decomposed.utf8) != Data(scopes[0].projectScope!.utf8))
  changed[0] = PinnedEvidenceScope(
    source: scopes[0].source, projectScope: decomposed,
    resolution: scopes[0].resolution)
  #expect(throws: (any Error).self) { try fixture.context(scopes: changed) }
}

@Test func dreamDecisionRepairsInvalidAnnotationButRejectsUntouchedInvalidBlock() throws {
  for isUntouchedInvalid in [false, true] {
    let raw =
      "# Memory\n\nBroken [source: invalid]\n"
      + (isUntouchedInvalid ? "\nUntouched without annotation\n" : "")
    let fixture = try DecisionFixture(document: raw)
    defer { fixture.clean() }
    let context = try fixture.context()
    #expect(!context.snapshot.documents[0].diagnostics.isEmpty)
    let anchor = context.memoryCatalogue.first { $0.isEligible }!
    let response = try fixture.response(
      [decisionUpdate(context.primaryCatalogue[0].id, anchor: anchor)], context: context)
    if isUntouchedInvalid {
      #expect(throws: (any Error).self) {
        try DreamDecision.validate(response: response, context: context)
      }
    } else {
      #expect(try DreamDecision.validate(response: response, context: context).plans.count == 1)
    }
  }
}

@Test func dreamDecisionRelatedWindowsSharePinnedCatalogueAndRetainConditionalConflicts() throws {
  let fixture = try DecisionFixture(texts: ["Use green unless offline."])
  defer { fixture.clean() }
  let prior = try DecisionFixture(texts: ["Use green unless offline.", "Use blue when offline."])
  defer { prior.clean() }
  let scopes = prior.run.batch.evidence.map {
    PinnedEvidenceScope(source: $0.id, projectScope: $0.projectScope,
      resolution: .outsideGit(isGlobalEligible: true))
  }
  let context = try DreamDecisionContext(run: fixture.run, snapshot: fixture.snapshot,
    scopes: scopes, owners: [], addedDate: "2026-01-02", relatedBatches: [prior.run.batch])
  #expect(context.primaryCatalogue.count == 2)
  let restored = try DreamRunEncoding.context(bytes: context.canonicalBytes, run: fixture.run)
  #expect(restored.contextHash == context.contextHash)
  #expect(restored.primaryCatalogue.map(\.witness) == context.primaryCatalogue.map(\.witness))
  #expect(context.contextHash != (try fixture.context()).contextHash)
  let source = context.primaryCatalogue[0].id
  let conflict = context.primaryCatalogue[1].id
  var proposal = decisionAdd(source, text: "Use green unless offline.")
  proposal["conditions"] = [["source": decisionSource(source), "explanation": "Unless offline."]]
  proposal["contradictions"] = [["kind": "primary", "source": decisionSource(conflict),
    "explanation": "Offline is a distinct condition, not an unconditional green preference."]]
  var other = decisionAdd(conflict, text: "Use blue when offline.")
  other["conditions"] = [["source": decisionSource(conflict), "explanation": "When offline."]]
  let response = try fixture.response([proposal, other], context: context)
  let result = try DreamDecision.validate(response: response, context: context)
  #expect(result.plans.count == 1)
  #expect(result.plans[0].sources.count == 2)
  #expect(result.plans[0].reason.contains("conditions"))
  #expect(result.plans[0].contradictions.contains("Offline is a distinct condition"))
  let message = try #require(try context.requestMessages(timestampMilliseconds: 0).first)
  let payload = try #require(try JSONSerialization.jsonObject(with: Data(message.text.utf8))
    as? [String: Any])
  #expect((payload["primaryEvidence"] as? [[String: Any]])?.count == 2)
  #expect((payload["connectedWindowBindings"] as? [String])?.count == 2)
  #expect(throws: (any Error).self) {
    try DreamDecisionContext(run: fixture.run, snapshot: fixture.snapshot,
      scopes: Array(scopes.prefix(1)), owners: [], addedDate: "2026-01-02",
      relatedBatches: [prior.run.batch])
  }
  proposal["conditions"] = [["source": decisionSource(conflict), "explanation": "Wrong support."]]
  #expect(throws: (any Error).self) {
    try DreamDecision.validate(response: fixture.response([proposal, other], context: context),
      context: context)
  }
}

@Test func dreamDecisionFrozenToolEvidenceRetainsKindAndIsLabeledAsToolActivity() throws {
  let fixture = try DecisionFixture(isToolEvidenceIncluded: true)
  defer { fixture.clean() }
  #expect(fixture.run.batch.evidence.filter { $0.kind == .toolCall }.map { $0.id.part } == [1, 2])
  #expect(fixture.run.batch.evidence.filter { $0.kind == .toolResult }.count == 1)
  let context = try fixture.context()
  let message = try #require(try context.requestMessages(timestampMilliseconds: 0).first)
  let payload = try #require(try JSONSerialization.jsonObject(with: Data(message.text.utf8))
    as? [String: Any])
  let evidence = try #require(payload["primaryEvidence"] as? [[String: Any]])
  let tools = evidence.filter { ["toolCall", "toolResult"].contains($0["kind"] as? String ?? "") }
  #expect(tools.count == 3)
  #expect(tools.allSatisfy { $0["isToolActivity"] as? Bool == true && $0["locator"] != nil })
  #expect(DreamDecisionContext.systemPrompt.contains("do not require repetition"))
  #expect(DreamDecisionContext.systemPrompt.contains("never human instructions"))
  let decisions = context.primaryCatalogue.map { decisionAdd($0.id) }
  let result = try DreamDecision.validate(
    response: fixture.response(decisions, context: context), context: context)
  #expect(result.plans[0].sources.count == context.primaryCatalogue.count)
}
