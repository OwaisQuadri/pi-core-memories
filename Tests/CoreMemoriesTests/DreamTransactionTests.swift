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

@Test func dreamTransactionMainRaceDropsTheBatchAndDoesNotConsumeProgress() throws {
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
      call: { try transactionAdd($0, isProject: true) }), reason: .droppedBatch)
  #expect(report.proposals.isEmpty)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
}
