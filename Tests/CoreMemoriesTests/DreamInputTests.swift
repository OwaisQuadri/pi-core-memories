import CryptoKit
import Foundation
import Testing

@testable import CoreMemories

private struct DreamInputFileState: Equatable {
  let bytes: Data
  let modified: Date?
}

private struct DreamInputFixture {
  let root: URL
  let sessions: URL
  let snippets: URL
  let prompts: URL

  init() throws {
    root = try temporaryDirectory()
    sessions = root.appendingPathComponent("sessions")
    snippets = root.appendingPathComponent("snippets")
    prompts = root.appendingPathComponent("prompts")
    for directory in [sessions, snippets, prompts] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  func clean() {
    try? FileManager.default.removeItem(at: root)
  }

  func file(_ name: String = "one.jsonl", folder: String = "--fixture--") -> URL {
    sessions.appendingPathComponent(folder).appendingPathComponent(name)
  }

  func write(_ text: String, to file: URL) throws {
    try write(Data(text.utf8), to: file)
  }

  func write(_ bytes: Data, to file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: file)
  }

  func append(_ text: String, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
  }

  func header(_ id: String = "one", name: String? = nil, parent: String? = nil) -> String {
    dreamHeader(id, cwd: root.path, parent: parent, name: name)
  }

  func reader(isStrippingLoaded: Bool = false) throws -> SessionReader {
    try SessionReader(
      sessions: sessions, snippets: isStrippingLoaded ? snippets : nil,
      prompts: isStrippingLoaded ? prompts : nil, environment: [:])
  }

  func snapshot() throws -> [String: DreamInputFileState] {
    var state: [String: DreamInputFileState] = [:]
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
    while let file = enumerator?.nextObject() as? URL {
      let values = try file.resourceValues(forKeys: [
        .isRegularFileKey, .contentModificationDateKey,
      ])
      if values.isRegularFile == true {
        state[file.path] = DreamInputFileState(
          bytes: try Data(contentsOf: file), modified: values.contentModificationDate)
      }
    }
    return state
  }

  func checked<Result>(_ operation: () throws -> Result) throws -> Result {
    let before = try snapshot()
    defer { #expect((try? snapshot()) == before) }
    return try operation()
  }

  func prepare(
    _ progress: DreamProgress? = nil, limits: DreamInputLimits? = nil,
    isStrippingLoaded: Bool = false
  ) throws -> PreparedSessionBatch {
    let reader = try reader(isStrippingLoaded: isStrippingLoaded)
    let progress = try progress ?? DreamProgress()
    let limits = try limits ?? DreamInputLimits()
    return try checked { try reader.prepare(progress: progress, limits: limits) }
  }

  func checkpoint(_ batch: PreparedSessionBatch) throws -> DreamProgress {
    try DreamProgress(
      generation: batch.predecessorGeneration + 1, positions: batch.positionsAfter)
  }
}

@Test func dreamInputLeavesPartialJSONAndMultibyteBytesOutsideBoundary() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let prefix = fixture.header() + "\n" + dreamUser("u", nil, dreamOld, "Complete text.") + "\n"
  let line = Data(dreamUser("partial", "u", dreamOld, "é😀 ending").utf8)
  let emojiStart = try #require(line.firstIndex(of: 0xF0))
  let partial = Data(line.prefix(emojiStart + 2))
  try fixture.write(Data(prefix.utf8) + partial, to: fixture.file())
  let first = try fixture.prepare()
  #expect(first.evidence.map(\.exactText) == ["Complete text."])
  #expect(first.positionsAfter.first?.completeBytes == UInt64(prefix.utf8.count))
  #expect(
    first.unfinishedTails.first?.byteRange == UInt64(
      prefix.utf8.count)..<UInt64(prefix.utf8.count + partial.count))
  let checkpoint = try fixture.checkpoint(first)
  try fixture.write(Data(prefix.utf8) + line + Data([0x0A]), to: fixture.file())
  let completed = try fixture.prepare(checkpoint)
  #expect(completed.evidence.map(\.exactText) == ["é😀 ending"])
  try fixture.write(Data("{\"type\":\"session\"".utf8), to: fixture.file("empty.jsonl"))
  let withIncompleteHeader = try fixture.prepare(try fixture.checkpoint(completed))
  #expect(withIncompleteHeader.positionsAfter.count == 1)
  #expect(withIncompleteHeader.unfinishedTails.count == 1)
}

@Test func dreamInputBlocksPrefixRewriteShrinkAndMissingFiles() throws {
  for change in ["rewrite", "shrink", "missing", "identity"] {
    let fixture = try DreamInputFixture()
    defer { fixture.clean() }
    let file = fixture.file()
    let body = fixture.header() + "\n" + dreamUser("u", nil, dreamOld, "First text.") + "\n"
    try fixture.write(body, to: file)
    let progress = try fixture.checkpoint(try fixture.prepare())
    let original = progress
    switch change {
    case "rewrite":
      try fixture.write(body.replacingOccurrences(of: "First", with: "Other"), to: file)
    case "identity":
      try fixture.write(body.replacingOccurrences(of: "\"one\"", with: "\"two\""), to: file)
    case "shrink": try fixture.write(fixture.header() + "\n", to: file)
    default: try FileManager.default.removeItem(at: file)
    }
    #expect(throws: (any Error).self) { try fixture.prepare(progress) }
    #expect(progress == original)
  }
}

@Test func dreamInputOversizedRecordAfterFullBatchDoesNotOverflowNextBatch() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let texts = [40, 100, 10].map { String(repeating: "x", count: $0) }
  let lines = [fixture.header()] + texts.indices.map { dreamUser("u\($0)", nil, dreamOld, texts[$0]) }
  try fixture.write(lines.joined(separator: "\n") + "\n", to: fixture.file())
  var backlog: DreamBacklog?
  let batch = try fixture.reader().prepare(
    progress: DreamProgress(), limits: DreamInputLimits(maximumBatchBytes: 80),
    backlog: { backlog = $0 })
  #expect(batch.evidence.map(\.exactText) == [texts[0]] && backlog?.nextBytes == 100)
}

@Test func dreamInputExcludesGeneratedCustomToolsSummariesAttachmentsAndSelections() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let generated = dreamJSON([
    "type": "custom_message", "id": "memory", "timestamp": dreamOld,
    "customType": "core-memories",
    "content": "Generated approved core-memory context\n\nFalse support.",
    "details": ["origin": "approved-core-memory", "schemaVersion": 1],
  ])
  let custom = dreamJSON([
    "type": "custom", "id": "custom", "timestamp": dreamOld, "data": ["result": "False support."],
  ])
  let summary = dreamJSON([
    "type": "compaction", "id": "summary", "timestamp": dreamOld, "summary": "False support.",
  ])
  let branch = dreamJSON([
    "type": "branch_summary", "id": "branch", "timestamp": dreamOld, "summary": "False support.",
  ])
  let answer = dreamAnswer(
    "answered",
    [["type": "option", "label": "Agent option"], ["type": "text", "label": "Human answer"]])
  let lines = [
    fixture.header(), generated, custom, summary, branch,
    dreamAssistant("assistant", nil, dreamOld, [dreamText("False support.")]),
    dreamUser("attached", nil, dreamOld, "<file name=\"a.md\">False support.</file>\n\nRead this."),
    dreamUser("attachmentOnly", nil, dreamOld, "<file name=\"a.md\">False support.</file>"),
    dreamEntry(
      "image", nil, dreamOld,
      message: dreamJSON([
        "role": "user",
        "content": [["type": "image", "data": "False support.", "mimeType": "image/png"]],
      ])),
    dreamResult("output", nil, call: "c", tool: "read", "False support."),
    dreamResult(
      "answer", nil, call: "q", tool: "ask_user_question", "Agent rendered body", details: answer),
    dreamResult(
      "picked", nil, call: "p", tool: "ask_user_question", "Agent rendered body",
      details: dreamAnswer("answered", [["type": "option", "label": "Selected only"]])),
    dreamEntry(
      "customrole", nil, dreamOld,
      message: dreamJSON(["role": "custom", "content": "False support."])),
    dreamEntry(
      "bashrole", nil, dreamOld,
      message: dreamJSON(["role": "bashExecution", "output": "False support."])),
    dreamEntry(
      "summaryrole", nil, dreamOld,
      message: dreamJSON(["role": "compactionSummary", "summary": "False support."])),
  ]
  try fixture.write(lines.joined(separator: "\n") + "\n", to: fixture.file())
  try fixture.write(
    fixture.header("child", name: "worker#abcdef12") + "\n"
      + dreamUser("cu", nil, dreamOld, "Child prompt.") + "\n"
      + dreamResult(
        "cq", nil, call: "q", tool: "ask_user_question", "Child answer", details: answer) + "\n",
    to: fixture.file("child.jsonl"))
  let batch = try fixture.prepare()
  #expect(batch.evidence.map(\.exactText) == ["Read this.", "Human answer"])
  #expect(batch.evidence.map(\.kind) == [.typed, .answered])
  #expect(
    batch.selections.map(\.agentWrittenSelectedLabels) == [["Agent option"], ["Selected only"]])
  #expect(batch.selections.map(\.question) == ["Ship it?", "Ship it?"])
  #expect(batch.evidence.allSatisfy { $0.id.citation.session == "one" })
  #expect(batch.exactSourceRecords.count == 9)
  #expect(batch.exactSourceRecords.filter { $0.bytes == nil }.count == 4)
}

@Test func dreamInputSharesSkillAndTemplateStrippingAndBindsRawInputs() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let snippetFile = fixture.snippets.appendingPathComponent("diagnose.md")
  let promptFile = fixture.prompts.appendingPathComponent("review.md")
  let snippet = "---\nname: diagnose\n---\n\n\(dreamSnippet)\n"
  try fixture.write(snippet, to: snippetFile)
  try fixture.write("---\ndescription: review\n---\n\nCheck $1 and $1\n", to: promptFile)
  let skill = "<skill name=\"fix\" location=\"/skills/fix/SKILL.md\">\nBody\n</skill>"
  let long = String(repeating: "é😀", count: 2_000)
  let raws = [
    skill + "\n\n" + long,
    dreamSnippet + "\n\nReal typed text.",
    "Check parser and parser", skill, dreamSnippet, "ok", " ",
  ]
  let lines =
    [fixture.header()]
    + raws.enumerated().map { index, raw in dreamUser("u\(index)", nil, dreamOld, raw) }
  try fixture.write(lines.joined(separator: "\n") + "\n", to: fixture.file())
  let batch = try fixture.prepare(isStrippingLoaded: true)
  #expect(batch.evidence.map(\.exactText) == [long, "Real typed text.", "parser"])
  #expect(batch.evidence.map(\.kind) == [.typedSkillArguments, .typed, .typedSkillArguments])
  let short = SessionReader.humanText(
    "Check parser and parser", snippets: [dreamSnippet], templates: ["Check $1 and $1"])
  #expect(short == .human("parser", .typedSkillArguments))
  try fixture.write(
    snippet.replacingOccurrences(of: "name: diagnose", with: "name: renamed"), to: snippetFile)
  let changed = try fixture.prepare(isStrippingLoaded: true)
  #expect(changed.evidence.map(\.exactText) == batch.evidence.map(\.exactText))
  #expect(changed.strippingInputHash != batch.strippingInputHash)
  let reader = try fixture.reader(isStrippingLoaded: true)
  try FileManager.default.removeItem(at: promptFile)
  _ = try fixture.checked {
    #expect(throws: (any Error).self) {
      try reader.prepare(progress: DreamProgress(), limits: DreamInputLimits())
    }
  }
}

@Test func dreamInputBatchesStopBetweenRecordsAndKeepBacklog() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let lines = [
    fixture.header(), dreamUser("u1", nil, dreamOld, "First."),
    dreamUser("u2", "u1", dreamOld, "Second."),
  ]
  try fixture.write(lines.joined(separator: "\n") + "\n", to: fixture.file())
  let twoBytes = (lines[0] + "\n" + lines[1] + "\n").utf8.count
  for limits in [
    try DreamInputLimits(maximumBatchBytes: "First.".utf8.count),
    try DreamInputLimits(maximumBatchRecords: 2),
    try DreamInputLimits(maximumBatchBytes: 1),
  ] {
    let first = try fixture.prepare(limits: limits)
    #expect(first.evidence.map(\.exactText) == ["First."])
    #expect(first.exactSourceRecords.count == 2 && first.isBacklog)
    #expect(first.positionsAfter.first?.completeBytes == UInt64(twoBytes))
    let next = try fixture.prepare(try fixture.checkpoint(first), limits: limits)
    #expect(next.evidence.map(\.exactText) == ["Second."])
    #expect(next.exactSourceRecords.count == 1 && !next.isBacklog)
  }
  let onlyHeader = try fixture.prepare(limits: DreamInputLimits(maximumBatchRecords: 1))
  #expect(onlyHeader.evidence.isEmpty && onlyHeader.isBacklog)
  #expect(onlyHeader.positionsAfter.first?.completeBytes == UInt64(lines[0].utf8.count + 1))
}
