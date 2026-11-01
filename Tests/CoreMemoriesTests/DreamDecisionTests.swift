import Darwin
import Foundation
import Testing

@testable import CoreMemories

private let decisionBlue =
  "# Memory\n\nUse blue buttons. [source: pi:one#u1/part/0; added: 2026-01-01]\n"
private let decisionKey = String(repeating: "a", count: 64)
private let decisionOtherKey = String(repeating: "b", count: 64)
private let decisionRootBinding = Data(#"{"schemaVersion":2}"#.utf8)

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
    let binding = SourceDigest(bytes: decisionRootBinding)
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
  for (schema, rendering) in [
    (3, 5), (3, nil), (3, 1), (3, 2), (3, 3), (3, 4), (2, 3), (3, 6), (4, 4),
  ] as [(Int, Int?)]
  {
    let request = DreamRunEncoding.Request(
      schemaVersion: schema, runID: fixture.run.runID, generation: fixture.run.progress.generation,
      inputHash: fixture.run.inputHash.rawValue, contextHash: context.contextHash.rawValue,
      systemPrompt: context.savedSystemPrompt,
      messages: try context.requestMessages(timestampMilliseconds: 123), renderingVersion: rendering
    )
    let bytes = try DreamRunEncoding.encode(request)
    if schema == 3 && rendering == 5 {
      let saved = try DreamRunEncoding.decode(DreamRunEncoding.Request.self, bytes: bytes)
      #expect(
        try saved.domain(run: fixture.run, context: context, bytes: bytes).requestHash
          == SourceDigest(bytes: bytes))
    } else if schema == 3 && [2, 3, 4].contains(rendering) {
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

@Test(arguments: [DreamRequestRendering.connectedV3, .stuckDetectionV4])
func dreamRequestSavedV3AndV4StillVerifyWithoutPriorContextSections(
  rendering: DreamRequestRendering
) throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let context = try fixture.context()
  let saved = DreamRunEncoding.Request(
    schemaVersion: 3, runID: fixture.run.runID, generation: fixture.run.progress.generation,
    inputHash: fixture.run.inputHash.rawValue, contextHash: context.contextHash.rawValue,
    systemPrompt: context.systemPrompt(rendering: rendering),
    messages: try context.requestMessages(timestampMilliseconds: 123, rendering: rendering),
    renderingVersion: rendering.rawValue)
  let bytes = try DreamRunEncoding.encode(saved)
  let decoded = try DreamRunEncoding.decode(DreamRunEncoding.Request.self, bytes: bytes)
  let verified = try decoded.verifiedDomain(run: fixture.run, context: context, bytes: bytes)
  #expect(verified.rendering == rendering)
  #expect(verified.request.requestHash == SourceDigest(bytes: bytes))
  #expect(!saved.systemPrompt.contains("priorDreamNotesNotPrimaryEvidence"))
  let body = try #require(
    JSONSerialization.jsonObject(with: Data(saved.messages[0].text.utf8)) as? [String: Any])
  #expect(body["priorDreamNotesNotPrimaryEvidence"] == nil)
  #expect(body["priorFindingsNotPrimaryEvidence"] == nil)
}

@Test func dreamRequestOnlyV5RendersPriorHistoryAfterTheStuckDetectionPrompt() throws {
  let fixture = try DecisionFixture()
  defer { fixture.clean() }
  let plain = try fixture.context()
  let note = DreamPriorNote(
    generation: 1, kind: "noChange", reasonCode: "notDurable", explanation: "Earlier note.",
    sessions: ["one"])
  let prior = try #require(
    try DreamPriorContext(
      newestNotes: [DreamPriorCandidate(item: note, sessions: ["one"], sourcePaths: ["a/b.jsonl"])],
      olderNoteCount: 0, newestFindings: [], excludedSessionIDs: [], isVerified: { _ in true }))
  let context = try DreamDecisionContext(
    run: fixture.run, snapshot: fixture.snapshot,
    scopes: fixture.run.batch.evidence.map {
      PinnedEvidenceScope(
        source: $0.id, projectScope: $0.projectScope,
        resolution: .outsideGit(isGlobalEligible: true))
    }, owners: [], addedDate: "2026-01-02", priorContext: prior)
  for rendering in [DreamRequestRendering.connectedV3, .stuckDetectionV4] {
    #expect(throws: DreamRunError.corruption) {
      try context.requestMessages(timestampMilliseconds: 123, rendering: rendering)
    }
  }
  #expect(
    Data(context.systemPrompt(rendering: .priorContextV5).utf8).starts(
      with: Data((plain.systemPrompt(rendering: .stuckDetectionV4) + "\n").utf8)))
  let body = try #require(
    JSONSerialization.jsonObject(
      with: Data(try context.requestMessages(timestampMilliseconds: 123)[0].text.utf8))
      as? [String: Any])
  let notes = try #require(body["priorDreamNotesNotPrimaryEvidence"] as? [String: Any])
  #expect((notes["notes"] as? [[String: Any]])?.first?["explanation"] as? String == "Earlier note.")
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
  for (marker, prompt, message) in [
    (DreamRequestRendering.connectedV3, DreamRequestRendering.stuckDetectionV4,
      DreamRequestRendering.connectedV3),
    (.connectedV3, .connectedV3, .priorContextV5),
    (.stuckDetectionV4, .connectedV3, .stuckDetectionV4),
    (.stuckDetectionV4, .stuckDetectionV4, .priorContextV5),
    (.stuckDetectionV4, .priorContextV5, .stuckDetectionV4),
    (.priorContextV5, .stuckDetectionV4, .priorContextV5),
    (.priorContextV5, .priorContextV5, .stuckDetectionV4),
  ] {
    let request = DreamRunEncoding.Request(
      schemaVersion: 3, runID: fixture.run.runID, generation: fixture.run.progress.generation,
      inputHash: fixture.run.inputHash.rawValue, contextHash: context.contextHash.rawValue,
      systemPrompt: context.systemPrompt(rendering: prompt),
      messages: try context.requestMessages(timestampMilliseconds: 123, rendering: message),
      renderingVersion: marker.rawValue)
    #expect(throws: DreamRunError.corruption) {
      try request.domain(
        run: fixture.run, context: context, bytes: DreamRunEncoding.encode(request))
    }
  }
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

@Test func dreamStuckDetectionPromptAddsGuidanceAndSavedConnectedRequestsStillReplay() throws {
  let fixture = try DecisionFixture(isToolEvidenceIncluded: true)
  defer { fixture.clean() }
  let context = try fixture.context()
  let guidance = DreamDecisionContext.stuckDetectionGuidance
  #expect(guidance.contains("guard refusal"))
  #expect(guidance.contains("at least 2 occurrences"))
  #expect(guidance.contains("Tool fix suggestion: <tool> \u{2014} <failure> (seen N times)"))
  #expect(context.savedSystemPrompt.contains(guidance))
  #expect(!context.systemPrompt(rendering: .connectedV3).contains(guidance))
  let connected = try context.requestMessages(timestampMilliseconds: 123, rendering: .connectedV3)
  #expect(
    try context.requestMessages(timestampMilliseconds: 123, rendering: .stuckDetectionV4)
      == connected)
  let saved = DreamRunEncoding.Request(
    schemaVersion: 3, runID: fixture.run.runID, generation: fixture.run.progress.generation,
    inputHash: fixture.run.inputHash.rawValue, contextHash: context.contextHash.rawValue,
    systemPrompt: context.systemPrompt(rendering: .connectedV3), messages: connected,
    renderingVersion: DreamRequestRendering.connectedV3.rawValue)
  let bytes = try DreamRunEncoding.encode(saved)
  let verified = try DreamRunEncoding.decode(DreamRunEncoding.Request.self, bytes: bytes)
    .verifiedDomain(run: fixture.run, context: context, bytes: bytes)
  #expect(verified.rendering == .connectedV3)
  #expect(verified.request.requestHash == SourceDigest(bytes: bytes))
  #expect(verified.request.systemPrompt == saved.systemPrompt)
}
