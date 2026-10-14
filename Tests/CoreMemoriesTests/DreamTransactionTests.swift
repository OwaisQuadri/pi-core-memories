import Darwin
import Foundation
import Testing

@testable import CoreMemories

struct TransactionFileState: Equatable {
  let bytes: Data
  let modified: Date?
}

struct TransactionFixture {
  let root: URL
  let sessions: URL
  let memory: URL
  let snippets: URL
  let state: URL
  let source: URL
  let selection: DreamSelectedCall

  init(root supplied: URL? = nil, isCreating: Bool = true) throws {
    let temporary = try supplied ?? temporaryDirectory()
    guard let path = realpath(temporary.path, nil) else { throw MemoryError("fixture root") }
    defer { free(path) }
    root = URL(fileURLWithPath: String(cString: path))
    sessions = root.appendingPathComponent("sessions")
    memory = root.appendingPathComponent("memory")
    snippets = root.appendingPathComponent("snippets")
    state = root.appendingPathComponent("state")
    source = sessions.appendingPathComponent("--fixture--/one.jsonl")
    selection = try DreamSelectedCall(
      provider: "synthetic", modelID: "fixture", thinkingLevel: "off")
    if isCreating {
      for directory in [sessions, snippets] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      }
      try MemoryStore.initialize(repo: memory, environment: [:])
      try write(
        "---\nname: synthetic\n---\n\nSynthetic stripping body\n",
        file: snippets.appendingPathComponent("strip.md"))
    }
  }

  func clean() { try? FileManager.default.removeItem(at: root) }

  func write(_ text: String, file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }

  func populate(texts: [String] = ["Use green buttons, not blue."], cwd: String? = nil) throws {
    let lines =
      [dreamHeader("one", cwd: cwd ?? root.path, name: nil)]
      + texts.enumerated().map { dreamUser("u\($0.offset)", nil, dreamOld, $0.element) }
    try write(lines.joined(separator: "\n") + "\n", file: source)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: source.path)
  }

  func append(_ line: String) throws {
    let file = try FileHandle(forWritingTo: source)
    defer { try? file.close() }
    try file.seekToEnd()
    try file.write(contentsOf: Data(line.utf8))
  }

  func store(limits: DreamRunLimits? = nil, state: URL? = nil, globalAgents: URL? = nil) throws
    -> DreamRunStore
  {
    try DreamRunStore(
      stateRoot: state ?? self.state, sessionsRoot: sessions, memoryRepository: memory,
      strippingRoots: [snippets], globalAgents: globalAgents, limits: limits ?? DreamRunLimits())
  }

  func prepare(_ progress: DreamProgress, records: Int = 1_000) throws -> PreparedSessionBatch {
    try SessionReader(sessions: sessions, snippets: snippets, environment: [:]).prepare(
      progress: progress, limits: DreamInputLimits(maximumBatchRecords: records))
  }

  func payload(_ name: String, generation: UInt64 = 0) throws -> URL {
    let bytes = try Data(contentsOf: state.appendingPathComponent("admissions/\(generation).json"))
    let admission = try DreamRunEncoding.decode(DreamRunEncoding.Admission.self, bytes: bytes)
    return state.appendingPathComponent("runs/\(admission.runID)/\(name)")
  }

  func snapshot(_ directory: URL) throws -> [String: TransactionFileState] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
    var files: [String: TransactionFileState] = [:]
    let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
    while let file = enumerator?.nextObject() as? URL {
      let values = try file.resourceValues(forKeys: [
        .isRegularFileKey, .contentModificationDateKey,
      ])
      if values.isRegularFile == true {
        files[file.path] = TransactionFileState(
          bytes: try Data(contentsOf: file), modified: values.contentModificationDate)
      }
    }
    return files
  }

  func protectedState() throws -> [String: TransactionFileState] {
    var files = try snapshot(sessions).merging(snapshot(snippets)) { _, new in new }
    for (path, value) in try snapshot(memory) {
      let relative = String(path.dropFirst(memory.path.count + 1))
      if !relative.hasPrefix(".git/objects/") && !relative.hasPrefix(".git/refs/heads/proposals/")
        && !relative.hasPrefix(".git/logs/refs/heads/proposals/")
      {
        files[path] = value
      }
    }
    return files
  }

  func main() throws -> String { try MemoryStore(repo: memory, environment: [:]).approvedCommit() }

  func advance() throws {
    _ = try Git(repo: memory, environment: [:]).data(
      ["commit", "--allow-empty", "-m", "Synthetic human advance"], additions: Git.proposalIdentity)
  }
}

func transactionObject(_ request: DreamModelRequest) throws -> [String: Any] {
  try JSONSerialization.jsonObject(with: Data(request.messages[0].text.utf8)) as! [String: Any]
}

func transactionResponse(_ request: DreamModelRequest, decisions: [[String: Any]]) throws
  -> DreamCompletedResponse
{
  let bytes = try JSONSerialization.data(
    withJSONObject: [
      "schemaVersion": 1, "contextHash": request.contextHash.rawValue, "decisions": decisions,
    ], options: [.sortedKeys, .withoutEscapingSlashes])
  return try DreamCompletedResponse(text: String(decoding: bytes, as: UTF8.self))
}

func transactionNotes(_ request: DreamModelRequest) throws -> DreamCompletedResponse {
  let context = try transactionObject(request)
  let primary = context["primaryEvidence"] as! [[String: Any]]
  let scopes = context["scopes"] as! [[String: Any]]
  return try transactionResponse(
    request,
    decisions: primary.map { entry in
      let source = entry["source"] as! [String: Any]
      let mapping = scopes.first { ($0["source"] as! NSDictionary) == (source as NSDictionary) }!
      let resolution = mapping["resolution"] as! [String: Any]
      return [
        "kind": "noChange", "sources": [source],
        "reasonCode": resolution["kind"] as! String == "unresolved"
          ? "unresolvedScope" : "notDurable", "explanation": "No durable preference supplied.",
      ]
    })
}

func transactionAdd(_ request: DreamModelRequest, isProject: Bool = false) throws
  -> DreamCompletedResponse
{
  let context = try transactionObject(request)
  let primary = context["primaryEvidence"] as! [[String: Any]]
  var decisions: [[String: Any]] = []
  for entry in primary {
    let source = entry["source"]!
    decisions.append([
      "kind": "add", "scope": ["kind": "global"], "text": "Use green buttons.", "sources": [source],
      "contradictions": [], "reason": "Retain the preference.",
    ])
    if isProject {
      let scopes = context["scopes"] as! [[String: Any]]
      let resolution = scopes.first!["resolution"] as! [String: Any]
      decisions.append([
        "kind": "add", "scope": ["kind": "project", "key": resolution["key"]!],
        "text": "Use project green buttons.", "sources": [source], "contradictions": [],
        "reason": "Retain the project preference.",
      ])
    }
  }
  return try transactionResponse(request, decisions: decisions)
}

func transactionCompleted(_ result: DreamTransactionResult) throws -> DreamCompletionReport {
  guard case .completed(let report) = result else {
    throw MemoryError("expected completed transaction")
  }
  return report
}

func transactionPending(_ result: DreamTransactionResult, reason: DreamPendingReason) throws
  -> DreamPendingReport
{
  guard case .pending(let report) = result, report.reason == reason else {
    throw MemoryError("expected pending transaction: \(reason)")
  }
  return report
}

func transactionUncalledPrepare(_ progress: DreamProgress) throws -> PreparedSessionBatch {
  Issue.record("replay must not prepare sources")
  throw MemoryError("unexpected preparation")
}

func transactionUncalled(_ request: DreamModelRequest) throws -> DreamCompletedResponse {
  Issue.record("replay must not call the model")
  throw MemoryError("unexpected model call")
}

@Test func dreamTransactionBlueToGreenPublishesOneExactRefAndProgress() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let blue = "# Memory\n\nUse blue buttons. [source: pi:one#old/part/0; added: 2026-01-01]\n"
  try fixture.write(blue, file: fixture.memory.appendingPathComponent("MEMORY.md"))
  let git = Git(repo: fixture.memory, environment: [:])
  _ = try git.data(["add", "MEMORY.md"])
  _ = try git.data(["commit", "-m", "Synthetic blue"], additions: Git.proposalIdentity)
  try fixture.write(
    "Staged synthetic bytes", file: fixture.memory.appendingPathComponent("MEMORY.md"))
  _ = try git.data(["add", "MEMORY.md"])
  try fixture.write(
    "Dirty synthetic bytes", file: fixture.memory.appendingPathComponent("MEMORY.md"))
  try fixture.populate()
  let before = try fixture.protectedState()
  let base = try fixture.main()
  let store = try fixture.store()
  store.clock = { Date(timeIntervalSince1970: 1_767_312_000) }
  var calls = 0
  let report = try transactionCompleted(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        calls += 1
        let context = try transactionObject(request)
        let anchor = (context["eligibleMemoryAnchors"] as! [[String: Any]])[0]
        let source = (context["primaryEvidence"] as! [[String: Any]])[0]["source"]!
        return try transactionResponse(
          request,
          decisions: [
            [
              "kind": "update", "scope": ["kind": "global"], "anchor": anchor,
              "text": "Use green buttons.", "sources": [source], "reason": "Apply the correction.",
              "contradictions": [
                [
                  "kind": "memory", "anchor": anchor,
                  "explanation": "Replace the earlier preference.",
                ]
              ],
            ]
          ])
      }))
  #expect(calls == 1 && report.generation == 1 && report.predecessorGeneration == 0)
  #expect(report.proposals.count == 1 && report.notes.isEmpty && !report.isRecovered)
  let receipt = report.proposals[0]
  #expect(receipt.base == base && receipt.path == "MEMORY.md")
  #expect(receipt.contradictions.contains("Use blue buttons."))
  let replacement = try git.data(["show", "\(receipt.commit):MEMORY.md"])
  #expect(
    String(decoding: replacement, as: UTF8.self).contains(
      "Use green buttons. [source: pi:one#u0/part/0; added: 2026-01-02]"))
  #expect(try fixture.main() == base)
  #expect(try fixture.protectedState() == before)
  let generation = try DreamRunEncoding.decode(
    DreamRunEncoding.Generation.self,
    bytes: Data(contentsOf: fixture.state.appendingPathComponent("generations/1.json")))
  #expect(
    try generation.progress.domain().positions == fixture.prepare(DreamProgress()).positionsAfter)
  let runs = try FileManager.default.contentsOfDirectory(
    atPath: fixture.state.appendingPathComponent("runs").path)
  let repeatResult = try fixture.store().run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
  guard case .noNewRecords(let current, _) = repeatResult else {
    throw MemoryError("expected no delta")
  }
  #expect(current == 1 && calls == 1)
  #expect(
    try FileManager.default.contentsOfDirectory(
      atPath: fixture.state.appendingPathComponent("runs").path) == runs)
}

@Test func dreamTransactionNotesOwnersAndPinnedRetryDoNotReadRemovedRoots() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let owner = fixture.root.appendingPathComponent("code-style.md")
  try fixture.write("Use is-prefixed Boolean names.\n", file: owner)
  try fixture.populate(
    texts: ["The instruction owner is code-style.md.", "A temporary task."], cwd: fixture.root.path)
  let ownerBefore = try Data(contentsOf: owner)
  let store = try fixture.store()
  var original: DreamModelRequest?
  _ = try transactionPending(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        original = request
        throw CancellationError()
      }), reason: .cancelled)
  let sealed = try #require(original)
  #expect(try transactionObject(sealed)["limitations"] as? [String] != [])
  try FileManager.default.removeItem(at: fixture.sessions)
  try FileManager.default.removeItem(at: fixture.snippets)
  try FileManager.default.removeItem(at: owner)
  let replay = try fixture.store()
  replay.clock = {
    Issue.record("replay clock read")
    return Date()
  }
  _ = try transactionPending(
    replay.run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled),
    reason: .interruptedCall)
  var calls = 0
  let result = try transactionCompleted(
    replay.run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare,
      call: { request in
        calls += 1
        #expect(request.messages == sealed.messages && request.systemPrompt == sealed.systemPrompt)
        #expect(
          request.requestHash == sealed.requestHash && request.contextHash == sealed.contextHash)
        let context = try transactionObject(request)
        let primary = context["primaryEvidence"] as! [[String: Any]]
        let anchor = (context["ownerAnchorsNotPrimaryEvidence"] as! [[String: Any]])[0]
        #expect(anchor["before"] as? String == String(decoding: ownerBefore, as: UTF8.self))
        return try transactionResponse(
          request,
          decisions: [
            [
              "kind": "ownerNote", "sources": [primary[0]["source"]!], "owner": anchor,
              "contradictions": [], "explanation": "The owner contains the rule.",
            ],
            [
              "kind": "noChange", "sources": [primary[1]["source"]!], "reasonCode": "notDurable",
              "explanation": "A temporary task.",
            ],
          ])
      }))
  #expect(
    result.notes.count == 2 && result.proposals.isEmpty && result.generation == 1 && calls == 1)
}

@Test func dreamTransactionSkippedRecordsAreNotStoredAndReplayCompletes() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let header = dreamHeader("one", cwd: fixture.root.path, name: nil) + "\n"
  let before = dreamUser("before", nil, dreamOld, "First retained preference.") + "\n"
  let excluded =
    dreamResult(
      "excluded", "before", call: "c", tool: "read", String(repeating: "x", count: 4_500_000))
    + "\n"
  let after = dreamUser("after", "excluded", dreamOld, "Later retained preference.") + "\n"
  try fixture.write(header + before + excluded + after, file: fixture.source)
  let protected = try fixture.protectedState()
  func prepare(_ progress: DreamProgress) throws -> PreparedSessionBatch {
    let batch = try fixture.prepare(progress)
    try SessionReader.verifyPreparation(batch)
    return batch
  }
  var original: DreamModelRequest?
  _ = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, prepare: prepare,
      call: { request in
        original = request
        throw CancellationError()
      }), reason: .cancelled)
  let admission = try DreamRunEncoding.decode(
    DreamRunEncoding.Admission.self,
    bytes: Data(contentsOf: fixture.state.appendingPathComponent("admissions/0.json")))
  let input = try Data(contentsOf: fixture.payload("input.json"))
  #expect(input.count < 65_536)
  let frozen = try DreamRunEncoding.frozen(
    bytes: input, runID: admission.runID, inputHash: SourceDigest(admission.inputHash),
    bindingHash: SourceDigest(admission.bindingHash), limits: DreamRunLimits())
  let start = UInt64((header + before).utf8.count)
  #expect(
    frozen.batch.exactSourceRecords.map(\.bytes) == [
      Data(header.utf8), Data(before.utf8), nil, Data(after.utf8),
    ])
  #expect(
    frozen.batch.exactSourceRecords[2].witness.byteRange
      == start..<(start + UInt64(excluded.utf8.count)))
  try SessionReader.verifyPreparation(frozen.batch)
  let completed = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare,
      call: { request in
        #expect(
          request.messages == original?.messages && request.contextHash == original?.contextHash)
        return try transactionNotes(request)
      }))
  #expect(completed.generation == 1 && !completed.isBacklog)
  let idle = try fixture.store().run(
    selection: fixture.selection, prepare: prepare, call: transactionUncalled)
  guard case .noNewRecords(let current, _) = idle else {
    throw MemoryError("expected contiguous completed input")
  }
  #expect(current == 1)
  #expect(try fixture.protectedState() == protected)
}

@Test func dreamTransactionThreeGenerationsBacklogLateAppendsAndPartialUnicode() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["First retained preference.", "Second retained preference."])
  var calls = 0
  func run() throws -> DreamCompletionReport {
    try transactionCompleted(
      fixture.store().run(
        selection: fixture.selection, prepare: { try fixture.prepare($0, records: 1) },
        call: { request in
          calls += 1
          return try transactionNotes(request)
        }))
  }
  let first = try run()
  #expect(first.generation == 1 && first.isBacklog && calls == 0)
  let second = try run()
  #expect(second.generation == 2 && second.isBacklog && calls == 1)
  let third = try run()
  #expect(third.generation == 3 && !third.isBacklog && calls == 2)
  try fixture.append(
    dreamUser("backdated", nil, "1999-01-01T00:00:00.000Z", "Backdated append.") + "\n")
  let late = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        try fixture.append(dreamUser("equal", nil, dreamOld, "Equal timestamp append.") + "\n")
        let bytes = Data((dreamUser("partial", nil, dreamOld, "Multibyte 😀 append.") + "\n").utf8)
        let emoji = try #require(bytes.firstIndex(of: 0xF0))
        let file = try FileHandle(forWritingTo: fixture.source)
        try file.seekToEnd()
        try file.write(contentsOf: bytes.prefix(emoji + 2))
        try file.close()
        return try transactionNotes(request)
      }))
  #expect(late.generation == 4)
  let equal = try run()
  #expect(equal.generation == 5)
  let partialBytes = Data((dreamUser("partial", nil, dreamOld, "Multibyte 😀 append.") + "\n").utf8)
  let emoji = try #require(partialBytes.firstIndex(of: 0xF0))
  let file = try FileHandle(forWritingTo: fixture.source)
  try file.seekToEnd()
  try file.write(contentsOf: partialBytes.suffix(partialBytes.count - emoji - 2))
  try file.close()
  #expect(try run().generation == 6)
}

@Test func dreamTransactionInvalidSavedResponseNeverGetsReplacementCall() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(cwd: "/synthetic/missing-cwd")
  let store = try fixture.store()
  var calls = 0
  let result = try store.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { request in
      calls += 1
      let scopes = try transactionObject(request)["scopes"] as! [[String: Any]]
      #expect((scopes[0]["resolution"] as! [String: Any])["kind"] as? String == "unresolved")
      return try DreamCompletedResponse(text: "Invalid semantic response")
    })
  _ = try transactionPending(result, reason: .invalidDecision)
  let response = try Data(contentsOf: fixture.payload("response.json"))
  for resume in [DreamResumeAction.inspectOrContinue, .retryInterruptedCall] {
    _ = try transactionPending(
      fixture.store().run(
        selection: fixture.selection, resume: resume, prepare: transactionUncalledPrepare,
        call: transactionUncalled), reason: .invalidDecision)
  }
  #expect(calls == 1)
  #expect(try Data(contentsOf: fixture.payload("response.json")) == response)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
}

@Test func dreamTransactionExclusionsCompleteWithoutFakeModelResponse() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let records = [
    dreamHeader("one", cwd: fixture.root.path, parent: "parent", name: nil),
    dreamUser("child", nil, dreamOld, "Child text."),
    dreamJSON([
      "type": "custom", "id": "generated", "timestamp": dreamOld, "data": "Generated review",
    ]), dreamAssistant("assistant", nil, dreamOld, [dreamText("Not primary")]),
  ]
  try fixture.write(records.joined(separator: "\n") + "\n", file: fixture.source)
  let report = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
  )
  #expect(report.generation == 1 && report.proposals.isEmpty && report.notes.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: try fixture.payload("response.json").path))
  #expect(!FileManager.default.fileExists(atPath: try fixture.payload("call-started.json").path))
}

@Test func dreamTransactionExactAllPlanRecoveryPrecedesStaleSiblingRefusal() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let project = fixture.root.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
  _ = try Git(repo: project, environment: [:]).data(["init", "--template="])
  try fixture.populate(cwd: project.path)
  let store = try fixture.store()
  store.beforePublication = { path in
    if path == "MEMORY.md" { throw CancellationError() }
  }
  #expect(throws: CancellationError.self) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0, isProject: true) })
  }
  let decisionsBytes = try Data(contentsOf: fixture.payload("decisions.json"))
  let decisions = try DreamRunEncoding.decode(
    DreamRunEncoding.Decisions.self, bytes: decisionsBytes)
  #expect(decisions.plans.count == 2)
  let saved = decisions.plans[1]
  let memory = try MemoryStore(repo: fixture.memory, environment: [:])
  let published = try memory.propose(
    base: saved.base, path: saved.path, replacement: saved.replacement, reason: saved.reason,
    contradictions: saved.contradictions)
  try fixture.advance()
  let pending = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled),
    reason: .staleUnpublishedPlans)
  #expect(pending.proposals.count == 1 && pending.proposals[0].commit == published.commit)
  #expect(pending.proposals[0].path == saved.path)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
}

@Test func dreamTransactionMainAdvanceAfterPublicationRecoversLostReceiptExactly() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  store.persistenceFault = { event in
    if case .beforeWrite(let name) = event, name.hasSuffix(".json"), name.count == 69 {
      throw POSIXError(.EIO)
    }
  }
  #expect(throws: DreamRunError.persistenceFailure) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) })
  }
  let refs = try Git(repo: fixture.memory, environment: [:]).text([
    "for-each-ref", "--format=%(refname)", "refs/heads/proposals/",
  ])
  #expect(refs.split(separator: "\n").count == 1)
  try fixture.advance()
  let report = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled))
  #expect(report.isRecovered && report.generation == 1 && report.proposals.count == 1)
  #expect(report.proposals[0].ref == refs)
}

@Test func dreamTransactionCompletionAndGenerationCacheLossAdvanceExactlyOnce() throws {
  for boundary in [
    DreamPersistenceEvent.afterDirectorySync("completion.json"), .afterInstall("1.json"),
    .beforeInstall("state.json"),
  ] {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    try fixture.populate()
    let store = try fixture.store()
    var stateWrites = 0
    store.persistenceFault = { event in
      if event == .beforeInstall("state.json") { stateWrites += 1 }
      if event == boundary, boundary != .beforeInstall("state.json") || stateWrites == 3 {
        throw POSIXError(.EIO)
      }
    }
    #expect(throws: DreamRunError.persistenceFailure) {
      try store.run(
        selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes)
    }
    try FileManager.default.removeItem(at: fixture.state.appendingPathComponent("state.json"))
    let report = try transactionCompleted(
      fixture.store().run(
        selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled
      ))
    #expect(report.generation == 1 && report.isRecovered && report.notes.count == 1)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.state.appendingPathComponent("generations/2.json").path))
  }
}

@Test func dreamTransactionLinkedWorktreesAliasesAndOwnerCoverageArePinned() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let project = fixture.root.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
  let git = Git(repo: project, environment: [:])
  _ = try git.data(["init", "--initial-branch=main", "--template="])
  _ = try git.data(
    ["commit", "--allow-empty", "-m", "Synthetic root"], additions: Git.proposalIdentity)
  let linked = fixture.root.appendingPathComponent("linked")
  _ = try git.data(["worktree", "add", "--detach", linked.path])
  let alias = fixture.root.appendingPathComponent("alias")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
  try fixture.write(
    "Owner: [code style](code-style.md). Remote owner: https://example.invalid/style.md\n",
    file: project.appendingPathComponent("AGENTS.md"))
  try fixture.write("Exact local owner.\n", file: project.appendingPathComponent("code-style.md"))
  try fixture.populate(cwd: alias.path)
  let other = fixture.sessions.appendingPathComponent("--fixture--/two.jsonl")
  try fixture.write(
    dreamHeader("two", cwd: linked.path, name: nil) + "\n"
      + dreamUser("u", nil, dreamOld, "Linked preference.") + "\n", file: other)
  let ownerBefore = try fixture.snapshot(project)
  let report = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        let context = try transactionObject(request)
        let scopes = context["scopes"] as! [[String: Any]]
        let keys = scopes.map { ($0["resolution"] as! [String: Any])["key"] as! String }
        #expect(Set(keys).count == 1)
        #expect(try keys[0] == MemoryStore.projectKey(cwd: project))
        #expect((context["limitations"] as! [String]).contains { $0.contains("remote") })
        #expect((context["ownersNotPrimaryEvidence"] as! [[String: Any]]).count == 2)
        return try transactionNotes(request)
      }))
  #expect(report.generation == 1)
  #expect(try fixture.snapshot(project) == ownerBefore)
}

@Test func dreamTransactionSupportedStrippingExclusionsConsumeOnceWithoutCall() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: [
    "Synthetic stripping body",
    "<skill name=\"test\" location=\"/synthetic/SKILL.md\">\nBody\n</skill>", "ok",
  ])
  let report = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
  )
  #expect(report.generation == 1 && report.proposals.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: try fixture.payload("response.json").path))
}

@Test func dreamTransactionPendingAfterSuccessfulGenerationResumesCurrentAdmission() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  #expect(
    try transactionCompleted(
      fixture.store().run(
        selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes)
    ).generation == 1)
  try fixture.append(dreamUser("next", nil, dreamOld, "New preference.") + "\n")
  let pending = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { _ in throw CancellationError() }), reason: .cancelled)
  #expect(pending.generation == 1)
  try FileManager.default.removeItem(at: fixture.state.appendingPathComponent("state.json"))
  let replay = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled),
    reason: .interruptedCall)
  #expect(replay.runID == pending.runID)
  let report = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare, call: transactionNotes))
  #expect(report.generation == 2 && report.runID == pending.runID)
}

@Test func dreamTransactionMainRaceRetainsSiblingAndDoesNotConsumeProgress() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let project = fixture.root.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
  _ = try Git(repo: project, environment: [:]).data(["init", "--template="])
  try fixture.populate(cwd: project.path)
  let store = try fixture.store()
  store.beforePublication = { path in if path.hasPrefix("projects/") { try fixture.advance() } }
  let report = try transactionPending(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0, isProject: true) }), reason: .staleUnpublishedPlans)
  #expect(report.proposals.count == 1 && report.proposals[0].path == "MEMORY.md")
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
}

@Test func dreamTransactionCancellationBeforeProgressRetainsRecoverableRefs() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  var isCancelled = false
  store.isCancelled = { isCancelled }
  store.persistenceFault = {
    if $0 == .afterDirectorySync("completion.json") { isCancelled = true }
  }
  let pending = try transactionPending(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }), reason: .cancelled)
  #expect(pending.proposals.count == 1)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
  let report = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled))
  #expect(report.generation == 1 && report.proposals[0].ref == pending.proposals[0].ref)
}

@Test func dreamTransactionExplicitGlobalOwnersPinUnrelatedProjectRuleAndSymlinkReplay() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let unrelated = fixture.root.appendingPathComponent("unrelated")
  try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
  _ = try Git(repo: unrelated, environment: [:]).data(["init", "--template="])
  let owned = fixture.root.appendingPathComponent("personal-instructions")
  let target = owned.appendingPathComponent("AGENTS.md")
  let locator = fixture.root.appendingPathComponent("agent/AGENTS.md")
  try fixture.write("The global instruction owner is [code style](code-style.md).\n", file: target)
  try fixture.write(
    "Use is-prefixed Boolean names.\n", file: owned.appendingPathComponent("code-style.md"))
  try FileManager.default.createDirectory(
    at: locator.deletingLastPathComponent(), withIntermediateDirectories: false)
  try FileManager.default.createSymbolicLink(at: locator, withDestinationURL: target)
  try fixture.populate(texts: ["Use is-prefixed Boolean names."], cwd: unrelated.path)
  let store = try fixture.store(globalAgents: locator)
  var original: DreamModelRequest?
  _ = try store.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { request in
      original = request
      throw CancellationError()
    })
  let frozen = try #require(original)
  let context = try transactionObject(frozen)
  let owners = context["ownersNotPrimaryEvidence"] as! [[String: Any]]
  #expect(owners.count == 2)
  #expect(owners.allSatisfy { ($0["scope"] as! [String: Any])["kind"] as? String == "global" })
  try FileManager.default.removeItem(at: owned)
  try FileManager.default.removeItem(at: locator)
  let report = try transactionCompleted(
    fixture.store(globalAgents: locator).run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare,
      call: { request in
        #expect(request.messages == frozen.messages && request.contextHash == frozen.contextHash)
        let pinned = try transactionObject(request)
        let anchor = (pinned["ownerAnchorsNotPrimaryEvidence"] as! [[String: Any]]).first {
          ($0["before"] as? String)?.contains("is-prefixed") == true
        }!
        let source = (pinned["primaryEvidence"] as! [[String: Any]])[0]["source"]!
        return try transactionResponse(
          request,
          decisions: [
            [
              "kind": "ownerNote", "sources": [source], "owner": anchor, "contradictions": [],
              "explanation": "The global owner already contains the rule.",
            ]
          ])
      }))
  #expect(report.proposals.isEmpty && report.notes.count == 1 && report.generation == 1)
}

@Test func dreamTransactionSameGlobalAndProjectAgentsFileUsesGlobalScopeOnce() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let project = fixture.root.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
  _ = try Git(repo: project, environment: [:]).data(["init", "--template="])
  let agents = project.appendingPathComponent("AGENTS.md")
  try fixture.write("A global instruction owner.\n", file: agents)
  try fixture.populate(cwd: project.path)
  _ = try fixture.store(globalAgents: agents).run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { request in
      let owners = try transactionObject(request)["ownersNotPrimaryEvidence"] as! [[String: Any]]
      #expect(owners.count == 1)
      #expect((owners[0]["scope"] as! [String: Any])["kind"] as? String == "global")
      return try transactionNotes(request)
    })
}

@Test func dreamTransactionOwnerCaptureChecksExactDefaultBytesAndFinalSymlinks() throws {
  for kind in ["exact", "oneOver", "symlink"] {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    let owner = fixture.root.appendingPathComponent("code-style.md")
    try fixture.write(
      String(repeating: "x", count: 262_144 + (kind == "oneOver" ? 1 : 0)), file: owner)
    if kind == "symlink" {
      let target = fixture.root.appendingPathComponent("target.md")
      try FileManager.default.moveItem(at: owner, to: target)
      try FileManager.default.createSymbolicLink(at: owner, withDestinationURL: target)
    }
    try fixture.populate(texts: ["The instruction owner is code-style.md."])
    let sourceBefore = try fixture.snapshot(fixture.sessions)
    if kind == "exact" {
      let report = try transactionCompleted(
        fixture.store().run(
          selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes
        ))
      #expect(report.generation == 1)
    } else {
      #expect(throws: (any Error).self) {
        try fixture.store().run(
          selection: fixture.selection, prepare: { try fixture.prepare($0) },
          call: transactionUncalled)
      }
    }
    #expect(try fixture.snapshot(fixture.sessions) == sourceBefore)
  }
}

@Test func dreamTransactionExactOwnerLocatorsNeverReadMisleadingSuffixes() throws {
  for isUnsafeSuffix in [false, true] {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    let names = ["docs/codé-style.md", "docs/code style.md", "docs/quoted style.md"]
    for (index, name) in names.enumerated() {
      try fixture.write("Exact owner \(index).\n", file: fixture.root.appendingPathComponent(name))
    }
    let suffix = fixture.root.appendingPathComponent("-style.md")
    if isUnsafeSuffix {
      #expect(mkfifo(suffix.path, 0o600) == 0)
    } else {
      try fixture.write("Unrelated suffix.\n", file: suffix)
    }
    try fixture.write(
      "Unrelated remote suffix.\n", file: fixture.root.appendingPathComponent("style.md"))
    try fixture.populate(texts: [
      "Instruction owner [Unicode](docs/codé-style.md).",
      "Instruction owner [space](<docs/code style.md>).",
      "Instruction owner \"docs/quoted style.md\".",
      "Instruction owner file://remote.invalid/docs/style.md.",
      "Instruction owner opaque:docs/style.md.",
    ])
    var frozen: DreamModelRequest?
    _ = try fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        frozen = request
        let owners = try transactionObject(request)["ownersNotPrimaryEvidence"] as! [[String: Any]]
        #expect(owners.count == 3)
        let anchors =
          try transactionObject(request)["ownerAnchorsNotPrimaryEvidence"] as! [[String: Any]]
        #expect(
          Set(anchors.compactMap { $0["before"] as? String })
            == Set((0..<3).map { "Exact owner \($0).\n" }))
        throw CancellationError()
      })
    for name in names {
      try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(name))
    }
    _ = try transactionCompleted(
      fixture.store().run(
        selection: fixture.selection, resume: .retryInterruptedCall,
        prepare: transactionUncalledPrepare,
        call: { request in
          #expect(request.messages == frozen?.messages)
          return try transactionNotes(request)
        }))
  }
}

@Test func dreamTransactionRepeatedMissingAndRemoteOwnersHaveBoundedCoverage() throws {
  for locator in [
    "code-style.md", "https://example.invalid/code-style.md", "file://remote.invalid/code-style.md",
  ] {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    try fixture.populate(texts: Array(repeating: "Instruction owner \(locator).", count: 65))
    var calls = 0
    let report = try transactionCompleted(
      fixture.store(globalAgents: fixture.root.appendingPathComponent("missing/AGENTS.md")).run(
        selection: fixture.selection, prepare: { try fixture.prepare($0) },
        call: { request in
          calls += 1
          let context = try transactionObject(request)
          let limitations = context["limitations"] as! [String]
          #expect(limitations.count == 3 && Set(limitations).count == 3)
          #expect((context["ownersNotPrimaryEvidence"] as! [[String: Any]]).isEmpty)
          return try transactionNotes(request)
        }))
    #expect(calls == 1 && report.generation == 1 && report.notes.count == 65)
  }
}

@Test func dreamTransactionPublicationRecoveryIsLinearAndAllRefsSurviveHumanAdvance() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let project = fixture.root.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
  _ = try Git(repo: project, environment: [:]).data(["init", "--template="])
  try fixture.populate(cwd: project.path)
  let store = try fixture.store()
  store.persistenceFault = {
    if $0 == .beforeWrite("completion.json") { throw POSIXError(.EIO) }
  }
  #expect(throws: DreamRunError.persistenceFailure) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0, isProject: true) })
  }
  #expect(store.recoveryCount == 4)
  try fixture.advance()
  let report = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled))
  #expect(report.proposals.count == 2 && report.generation == 1)
}

@Test func dreamTransactionExplicitRetryRecoversCommittedReportButDefaultAdmitsNextBatch() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let original = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let runs = try FileManager.default.contentsOfDirectory(
    atPath: fixture.state.appendingPathComponent("runs").path)
  let report = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare, call: transactionUncalled))
  #expect(
    report.runID == original.runID && report.generation == original.generation && report.isRecovered
  )
  #expect(report.proposals.map(\.commit) == original.proposals.map(\.commit))
  for selection in [
    try DreamSelectedCall(provider: "other", modelID: "fixture", thinkingLevel: "off"),
    try DreamSelectedCall(provider: "synthetic", modelID: "other", thinkingLevel: "off"),
    try DreamSelectedCall(provider: "synthetic", modelID: "fixture", thinkingLevel: "medium"),
  ] {
    let before = try fixture.snapshot(fixture.state)
    let recovered = try transactionCompleted(fixture.store().run(
      selection: selection, resume: .retryInterruptedCall, prepare: transactionUncalledPrepare,
      call: transactionUncalled))
    #expect(recovered.runID == original.runID && recovered.isRecovered)
    #expect(recovered.proposals.map(\.commit) == original.proposals.map(\.commit))
    #expect(try fixture.snapshot(fixture.state).mapValues(\.bytes) == before.mapValues(\.bytes))
  }
  let idle = try fixture.store().run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
  guard case .noNewRecords(let generation, _) = idle else { throw MemoryError("expected idle") }
  #expect(generation == 1)
  #expect(
    try FileManager.default.contentsOfDirectory(
      atPath: fixture.state.appendingPathComponent("runs").path) == runs)
  try fixture.append(dreamUser("next", nil, dreamOld, "Next preference.") + "\n")
  let next = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes))
  #expect(next.generation == 2 && next.runID != original.runID)
}

@Test func dreamTransactionCommittedReportRetryCannotRecreateMissingHistoricalRef() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let report = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let ref = try #require(report.proposals.first).ref
  _ = try Git(repo: fixture.memory, environment: [:]).data(["update-ref", "-d", ref])
  let before = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.corruption) {
    try fixture.store().run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == before)
  #expect(
    try Git(repo: fixture.memory, environment: [:]).text([
      "for-each-ref", "--format=%(refname)", "refs/heads/proposals/",
    ]).isEmpty)
}

@Test func dreamTransactionCancellationAfterGenerationDoesNotClaimRollback() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  var isCancelled = false
  store.isCancelled = { isCancelled }
  store.persistenceFault = { if $0 == .afterInstall("1.json") { isCancelled = true } }
  let report = try transactionCompleted(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes))
  #expect(isCancelled && report.generation == 1)
}
