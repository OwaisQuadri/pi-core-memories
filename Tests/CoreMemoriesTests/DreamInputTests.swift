import CryptoKit
import Foundation
import Testing

@testable import CoreMemories

@Test func sourceDigestPreservesLeadingZerosAndLowercaseSHA256Bytes() {
  #expect(
    SourceDigest(bytes: Data()).rawValue
      == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  #expect(
    SourceDigest(bytes: Data("abc".utf8)).rawValue
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  for byte in UInt8.min...UInt8.max {
    let bytes = Data([byte])
    let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    #expect(SourceDigest(bytes: bytes).rawValue == expected)
  }
  #expect(SessionReader.sha256("café 🐟/\n") == SourceDigest(bytes: Data("café 🐟/\n".utf8)).rawValue)
}

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

@Test func dreamInputLateNewlineAdmitsOldPartialRecord() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let file = fixture.file()
  let partial = dreamUser("late", nil, dreamOld, "Old text completed later.")
  try fixture.write(fixture.header() + "\n" + partial, to: file)
  let first = try fixture.prepare()
  #expect(first.evidence.isEmpty)
  #expect(first.unfinishedTails.count == 1)
  #expect(first.unfinishedTails.first?.byteRange.count == partial.utf8.count)
  #expect(first.positionsAfter.first?.completeBytes == UInt64(fixture.header().utf8.count + 1))
  let progress = try fixture.checkpoint(first)
  try fixture.append("\n", to: file)
  let second = try fixture.prepare(progress)
  #expect(second.evidence.map(\.exactText) == ["Old text completed later."])
  #expect(second.evidence.first?.timestamp == SessionReader.date(dreamOld))
  #expect(second.unfinishedTails.isEmpty)
  #expect(second.predecessorGeneration == 1)
}

@Test func dreamInputAdmitsBackdatedEqualFutureAndSkipsFilesOutsideWindow() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let file = fixture.file()
  try fixture.write(
    fixture.header() + "\n" + dreamUser("u1", nil, dreamNew, "First.") + "\n", to: file)
  let first = try fixture.prepare()
  let progress = try fixture.checkpoint(first)
  let modified = try #require(
    file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
  let lines = [
    dreamUser("back", "u1", dreamOld, "Backdated."),
    dreamUser("equal", "back", dreamNew, "Equal timestamp."),
    dreamUser("future", "equal", "2099-01-01T00:00:00.000Z", "Future timestamp."),
  ]
  try fixture.append(lines.joined(separator: "\n") + "\n", to: file)
  try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
  let old = fixture.file("old.jsonl", folder: "--old--")
  try fixture.write(
    fixture.header("old") + "\n" + dreamUser("oldtext", nil, dreamOld, "New old file.") + "\n",
    to: old)
  try FileManager.default.setAttributes(
    [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
  let next = try fixture.prepare(progress)
  #expect(
    next.evidence.map(\.exactText) == ["Backdated.", "Equal timestamp.", "Future timestamp."])
  #expect(next.positionsAfter.count == 1)
}

@Test func dreamInputBacklogCountsOnlyUndreamtBytesAndAgedTrackedFilesKeepPositions() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let now = Date()
  for (index, id) in ["oldest", "middle", "newest"].enumerated() {
    let file = fixture.file("\(id).jsonl", folder: "--\(id)--")
    try fixture.write(
      fixture.header(id) + "\n" + dreamUser("\(id)-text", nil, dreamNew, id) + "\n", to: file)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(TimeInterval(index - 3))], ofItemAtPath: file.path)
  }
  let reader = try fixture.reader()
  let batch = try reader.prepare(
    progress: DreamProgress(), limits: DreamInputLimits(), maximumBacklogBytes: 7)
  #expect(batch.evidence.map(\.exactText) == ["newest", "middle"])
  let aged = fixture.file("newest.jsonl", folder: "--newest--")
  try FileManager.default.setAttributes(
    [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: aged.path)
  let progress = try fixture.checkpoint(batch)
  var backlog: DreamBacklog?
  let next = try reader.prepare(
    progress: progress, limits: DreamInputLimits(), maximumBacklogBytes: 6,
    backlog: { backlog = $0 })
  #expect(next.evidence.map(\.exactText) == ["oldest"])
  #expect(next.positionsAfter.count == 3)
  #expect(backlog == DreamBacklog(backlogBytes: 12, undreamtBytes: 6, nextBytes: 0))
  let copy = fixture.file("copy.jsonl", folder: "--newest--")
  try FileManager.default.copyItem(at: aged, to: copy)
  try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: copy.path)
  let checkpoint = try fixture.checkpoint(next)
  do {
    _ = try reader.prepare(progress: checkpoint, limits: DreamInputLimits())
    Issue.record("an aged tracked session copy must block preparation")
  } catch {
    #expect(String(describing: error) == "duplicate session identity: newest")
  }
}

@Test func dreamInputNativeDottedSessionIdentitySupportsReplayAndRejectsCopies() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let body =
    fixture.header("release.1") + "\n"
    + dreamUser("u", nil, dreamOld, "Release text.") + "\n"
  try fixture.write(body, to: fixture.file())
  let first = try fixture.prepare()
  #expect(first.positionsAfter.first?.sessionID.rawValue == "release.1")
  #expect(first.evidence.first?.id.citation.reference == "pi:release.1#u")
  let progress = try fixture.checkpoint(first)
  let replay = try fixture.prepare(progress)
  #expect(replay.evidence.isEmpty && replay.exactSourceRecords.isEmpty)
  #expect(replay.positionsAfter == first.positionsAfter)
  try fixture.write(body, to: fixture.file("copy.jsonl"))
  #expect(throws: (any Error).self) { try fixture.prepare(progress) }
  #expect(throws: (any Error).self) { try fixture.prepare() }
  for id in ["a", "A0", "release.1", "release_1-2", "a..b"] {
    #expect(try SessionIdentifier(id).rawValue == id)
  }
  for id in ["", ".release", "release.", "-release", "release_", "bad/id", "é"] {
    #expect(throws: (any Error).self) { try SessionIdentifier(id) }
  }
}

@Test func dreamInputNativeSystemMessagesAreGeneratedNotHumanContext() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let system = dreamEntry(
    "system", nil, dreamOld,
    message: dreamJSON([
      "role": "system", "content": "", "sections": ["identity": "Generated instructions."],
      "timestamp": 1_767_484_800_000,
    ]))
  try fixture.write(
    fixture.header() + "\n" + system + "\n"
      + dreamUser("u", "system", dreamOld, "Later human text.") + "\n", to: fixture.file())
  let batch = try fixture.prepare()
  #expect(batch.evidence.map(\.exactText) == ["Later human text."])
  #expect(batch.evidence.first?.agentContext == nil)
  #expect(batch.selections.isEmpty)
  guard case .skipped = batch.exactSourceRecords[1].disposition else {
    Issue.record("native system messages must be skipped")
    return
  }
}

@Test func dreamInputReplayRequiresOnlyASyntheticCheckpoint() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  try fixture.write(
    fixture.header() + "\n" + dreamUser("u", nil, dreamOld, "Keep exactly.") + "\n",
    to: fixture.file())
  let original = try DreamProgress(generation: 9)
  let first = try fixture.prepare(original)
  let repeated = try fixture.prepare(original)
  #expect(first.evidence.map(\.exactText) == repeated.evidence.map(\.exactText))
  #expect(first.positionsAfter == repeated.positionsAfter)
  #expect(original.positions.isEmpty && original.generation == 9)
  let synthetic = try fixture.checkpoint(first)
  let replay = try fixture.prepare(synthetic)
  #expect(replay.evidence.isEmpty && replay.exactSourceRecords.isEmpty)
  #expect(replay.positionsAfter == first.positionsAfter)
  #expect(replay.predecessorGeneration == 10 && !replay.isBacklog)
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

@Test func dreamInputBlocksDuplicateSessionIdentityIncludingIdenticalCopies() throws {
  for isIdentical in [true, false] {
    let fixture = try DreamInputFixture()
    defer { fixture.clean() }
    let body = fixture.header() + "\n" + dreamUser("u", nil, dreamOld, "Original.") + "\n"
    try fixture.write(body, to: fixture.file())
    try fixture.write(
      isIdentical ? body : body.replacingOccurrences(of: "Original", with: "Copy"),
      to: fixture.file("copy.jsonl"))
    #expect(throws: (any Error).self) { try fixture.prepare() }
  }
}

@Test func dreamInputBlocksMalformedCompleteUnknownAndInvalidRecords() throws {
  let cases = [
    "{not json",
    dreamUser("bad#id", nil, dreamOld, "Invalid identifier."),
    dreamUser("entry.1", nil, dreamOld, "Invalid entry identifier."),
    dreamEntry("u", "bad/id", dreamOld, message: dreamJSON(["role": "user", "content": "Words"])),
    dreamEntry("u", nil, "not-time", message: dreamJSON(["role": "user", "content": "Words"])),
    dreamEntry(
      "u", nil, dreamOld,
      message: dreamJSON(["role": "user", "content": [["type": "future-human", "text": "Words"]]])),
    dreamEntry(
      "u", nil, dreamOld,
      message: dreamJSON(["role": "user", "content": [["type": "thinking", "text": "Words"]]])),
    dreamJSON(["type": "future-entry", "id": "u", "timestamp": dreamOld, "content": "Words"]),
    dreamEntry(
      "u", nil, dreamOld, message: dreamJSON(["role": "future-role", "content": "Words"])),
    dreamResult(
      "u", nil, call: "c", tool: "ask_user_question", "Words",
      details: dreamAnswer("answered", [["type": "future-answer", "label": "Words"]])),
  ]
  for record in cases {
    let fixture = try DreamInputFixture()
    defer { fixture.clean() }
    try fixture.write(fixture.header() + "\n", to: fixture.file())
    let progress = try fixture.checkpoint(try fixture.prepare())
    try fixture.append(record + "\n", to: fixture.file())
    #expect(throws: (any Error).self) { try fixture.prepare(progress) }
    #expect(progress.positions.count == 1)
  }
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  try fixture.write(fixture.header("invalid/id") + "\n", to: fixture.file())
  #expect(throws: (any Error).self) { try fixture.prepare() }
}

@Test func dreamInputReadFailuresPreserveProgressAndSource() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  try fixture.write(fixture.header() + "\n", to: fixture.file())
  let progress = try fixture.checkpoint(try fixture.prepare())
  let reader = try fixture.reader()
  let limits = try DreamInputLimits()
  let original = progress
  _ = try fixture.checked {
    #expect(throws: (any Error).self) {
      try reader.prepare(progress: progress, limits: limits) { _ in
        throw MemoryError("injected read failure")
      }
    }
  }
  #expect(progress == original)
}

@Test func dreamInputStrictDiscoveryRejectsUnsafeFilesAndIgnoresUnsupportedDepths() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  try fixture.write(fixture.header() + "\n", to: fixture.file())
  try fixture.write(
    fixture.header("deep") + "\n", to: fixture.file("deep.jsonl", folder: "--fixture--/nested"))
  try fixture.write(
    fixture.header("flat") + "\n", to: fixture.sessions.appendingPathComponent("flat.jsonl"))
  let batch = try fixture.prepare()
  #expect(batch.positionsAfter.map { $0.sessionID.rawValue } == ["one"])
  let link = fixture.file("linked.jsonl")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.file())
  #expect(throws: (any Error).self) { try fixture.prepare() }
  try FileManager.default.removeItem(at: link)
  let folderLink = fixture.sessions.appendingPathComponent("--linked--")
  try FileManager.default.createSymbolicLink(
    at: folderLink, withDestinationURL: fixture.file().deletingLastPathComponent())
  #expect(throws: (any Error).self) { try fixture.prepare() }
  #expect(throws: (any Error).self) { try SourceRelativePath("../one.jsonl") }
  #expect(throws: (any Error).self) { try SourceRelativePath("/one.jsonl") }
  #expect(throws: (any Error).self) { try SourceRelativePath("a/nested/one.jsonl") }
  #expect(throws: (any Error).self) { try SourceDigest("INVALID") }
}

@Test func dreamInputSessionDirectorySubstitutionKeepsAcceptedFiles() throws {
  for target in ["root", "parent"] {
    let fixture = try DreamInputFixture()
    defer { fixture.clean() }
    let file = fixture.file()
    let body =
      fixture.header() + "\n"
      + dreamUser("u", nil, dreamOld, "Accepted human text.") + "\n"
    try fixture.write(body, to: file)
    let second = fixture.file("two.jsonl")
    let later = fixture.file(folder: "--later--")
    let secondBody =
      fixture.header("two") + "\n"
      + dreamUser("u", nil, dreamOld, "Second accepted text.") + "\n"
    let laterBody =
      fixture.header("later") + "\n"
      + dreamUser("u", nil, dreamOld, "Later accepted text.") + "\n"
    try fixture.write(secondBody, to: second)
    try fixture.write(laterBody, to: later)
    for accepted in [file, second, later] {
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: accepted.path)
    }
    let foreignRoot = fixture.root.appendingPathComponent("foreign")
    let foreignFolder = foreignRoot.appendingPathComponent("--fixture--")
    let foreign = foreignFolder.appendingPathComponent("one.jsonl")
    try fixture.write(
      fixture.header("foreign") + "\n"
        + dreamUser("f", nil, dreamOld, "Substituted human text.") + "\n", to: foreign)
    let reader = try fixture.reader()
    let directory = target == "root" ? fixture.sessions : file.deletingLastPathComponent()
    let replacement = target == "root" ? foreignRoot : foreignFolder
    let moved = fixture.root.appendingPathComponent("accepted")
    var stateAfterSubstitution: [String: DreamInputFileState]?
    let batch = try reader.prepare(progress: DreamProgress(), limits: DreamInputLimits()) {
      candidate in
      guard candidate == file else { return }
      try FileManager.default.moveItem(at: directory, to: moved)
      try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: replacement)
      stateAfterSubstitution = try fixture.snapshot()
    }
    #expect(stateAfterSubstitution != nil)
    #expect(try fixture.snapshot() == stateAfterSubstitution)
    #expect(
      batch.evidence.map(\.exactText)
        == ["Accepted human text.", "Second accepted text.", "Later accepted text."])
    #expect(batch.positionsAfter.map { $0.sessionID.rawValue } == ["one", "two", "later"])
    for (path, expected) in [
      "--fixture--/one.jsonl": body, "--fixture--/two.jsonl": secondBody,
      "--later--/one.jsonl": laterBody,
    ] {
      let bytes = batch.exactSourceRecords.filter { $0.witness.relativePath.rawValue == path }
        .compactMap(\.bytes).reduce(Data(), +)
      #expect(bytes == Data(expected.utf8))
    }
  }
}

@Test(arguments: ["symlink", "directory"])
func dreamInputUnvisitedFolderReplacementCannotRedirectCapture(_ replacement: String) throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let first = fixture.file(folder: "--a--")
  let later = fixture.file(folder: "--b--")
  try fixture.write(fixture.header("first") + "\n", to: first)
  try fixture.write(fixture.header("later") + "\n", to: later)
  let foreign = fixture.root.appendingPathComponent("foreign")
  try fixture.write(
    fixture.header("foreign") + "\n"
      + dreamUser("u", nil, dreamOld, "Must not be captured.") + "\n",
    to: foreign.appendingPathComponent("one.jsonl"))
  var reads: [URL] = []
  var stateAfterSubstitution: [String: DreamInputFileState]?
  #expect(throws: (any Error).self) {
    try fixture.reader().prepare(progress: DreamProgress(), limits: DreamInputLimits()) { candidate in
      reads.append(candidate)
      guard candidate == first else { return }
      let folder = later.deletingLastPathComponent()
      try FileManager.default.moveItem(
        at: folder, to: fixture.root.appendingPathComponent("accepted"))
      if replacement == "symlink" {
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: foreign)
      } else {
        try FileManager.default.moveItem(at: foreign, to: folder)
      }
      stateAfterSubstitution = try fixture.snapshot()
    }
  }
  #expect(reads == [first])
  #expect(stateAfterSubstitution != nil)
  #expect(try fixture.snapshot() == stateAfterSubstitution)
}

@Test func dreamInputStrippingDirectorySubstitutionKeepsAcceptedInputs() throws {
  for target in ["snippets", "prompts"] {
    let fixture = try DreamInputFixture()
    defer { fixture.clean() }
    try fixture.write(
      "---\nname: fixture\n---\n\nOriginal snippet\n",
      to: fixture.snippets.appendingPathComponent("strip.md"))
    try fixture.write(
      "Original template $1\n", to: fixture.prompts.appendingPathComponent("strip.md"))
    try fixture.write(
      fixture.header() + "\n"
        + dreamUser("u", nil, dreamOld, "Original snippet\n\nTyped text.") + "\n"
        + dreamUser("t", "u", dreamOld, "Original template value") + "\n", to: fixture.file())
    let baseline = try fixture.prepare(isStrippingLoaded: true)
    let foreign = fixture.root.appendingPathComponent("foreign")
    try fixture.write(
      "---\nname: foreign\n---\n\nSubstituted stripping body\n",
      to: foreign.appendingPathComponent("strip.md"))
    let reader = try fixture.reader(isStrippingLoaded: true)
    let directory = target == "snippets" ? fixture.snippets : fixture.prompts
    let moved = fixture.root.appendingPathComponent("accepted")
    var stateAfterSubstitution: [String: DreamInputFileState]?
    let batch = try reader.prepare(progress: DreamProgress(), limits: DreamInputLimits()) {
      candidate in
      guard candidate.deletingLastPathComponent().path == directory.path else { return }
      try FileManager.default.moveItem(at: directory, to: moved)
      try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: foreign)
      stateAfterSubstitution = try fixture.snapshot()
    }
    #expect(stateAfterSubstitution != nil)
    #expect(try fixture.snapshot() == stateAfterSubstitution)
    #expect(batch.evidence.map(\.exactText) == ["Typed text.", "value"])
    #expect(batch.strippingInputHash == baseline.strippingInputHash)
  }
}

@Test func dreamInputStrippingFollowsSymlinkedTemplate() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  try fixture.write(
    "---\nname: fixture\n---\n\nOriginal snippet\n",
    to: fixture.snippets.appendingPathComponent("strip.md"))
  let installed = fixture.root.appendingPathComponent("installed/strip.md")
  try fixture.write("Original template $1\n", to: installed)
  try FileManager.default.createSymbolicLink(
    at: fixture.prompts.appendingPathComponent("strip.md"), withDestinationURL: installed)
  try fixture.write(
    fixture.header() + "\n"
      + dreamUser("u", nil, dreamOld, "Original snippet\n\nTyped text.") + "\n"
      + dreamUser("t", "u", dreamOld, "Original template value") + "\n", to: fixture.file())
  let batch = try fixture.prepare(isStrippingLoaded: true)
  #expect(batch.evidence.map(\.exactText) == ["Typed text.", "value"])
}

@Test func dreamInputStoresNoBytesForSkippedRecords() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let header = fixture.header() + "\n"
  let result =
    dreamResult(
      "r", nil, call: "c", tool: "read", String(repeating: "image bytes ", count: 200)) + "\n"
  let user = dreamUser("u", "r", dreamOld, "Typed after the image.") + "\n"
  try fixture.write(header + result + user, to: fixture.file())
  let batch = try fixture.prepare()
  #expect(batch.evidence.map(\.exactText) == ["Typed after the image."])
  #expect(batch.exactSourceRecords.map(\.bytes) == [Data(header.utf8), nil, Data(user.utf8)])
  let start = UInt64(header.utf8.count)
  #expect(
    batch.exactSourceRecords[1].witness.byteRange == start..<(start + UInt64(result.utf8.count)))
  #expect(
    batch.exactSourceRecords[1].witness.rawRecordHash == SourceDigest(bytes: Data(result.utf8)))
  #expect(
    batch.positionsAfter.first?.completeBytes == UInt64((header + result + user).utf8.count))
  try SessionReader.verifyPreparation(batch)
}

@Test func dreamInputBatchesByKeptTextAndCountsNextBatch() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let texts = ["a", "b", "c"].map { String(repeating: $0, count: 40) }
  let header = fixture.header() + "\n"
  let first = dreamUser("a", nil, dreamOld, texts[0]) + "\n"
  let skipped =
    dreamResult("r", "a", call: "c", tool: "read", String(repeating: "x", count: 5_000)) + "\n"
  let second = dreamUser("b", "r", dreamOld, texts[1]) + "\n"
  let third = dreamUser("c", "b", dreamOld, texts[2]) + "\n"
  try fixture.write(header + first + skipped + second + third, to: fixture.file())
  let limits = try DreamInputLimits(maximumBatchBytes: 80)
  var backlog: DreamBacklog?
  let batch = try fixture.checked {
    try fixture.reader().prepare(
      progress: DreamProgress(), limits: limits, backlog: { backlog = $0 })
  }
  #expect(batch.evidence.map(\.exactText) == [texts[0], texts[1]])
  #expect(batch.isBacklog && batch.keptBytes == 80)
  #expect(backlog == DreamBacklog(backlogBytes: 120, undreamtBytes: 120, nextBytes: 40))
  #expect(
    batch.positionsAfter.first?.completeBytes
      == UInt64((header + first + skipped + second).utf8.count))
  try SessionReader.verifyPreparation(batch)
  let next = try fixture.prepare(try fixture.checkpoint(batch), limits: limits)
  #expect(next.evidence.map(\.exactText) == [texts[2]])
  #expect(!next.isBacklog)
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

@Test func dreamInputDefersOversizedPrimaryFailureUntilSelected() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let prefix = fixture.header() + "\n" + dreamUser("safe", nil, dreamOld, "Safe prefix.") + "\n"
  let oversized = dreamUser("large", "safe", dreamOld, String(repeating: "x", count: 300)) + "\n"
  try fixture.write(prefix + oversized, to: fixture.file())
  for limits in [
    try DreamInputLimits(maximumRecordBytes: 300, maximumBatchRecords: 2),
    try DreamInputLimits(maximumEvidenceBytes: 100, maximumBatchRecords: 2),
  ] {
    let first = try fixture.prepare(limits: limits)
    #expect(first.evidence.map(\.exactText) == ["Safe prefix."])
    #expect(
      first.isBacklog && first.positionsAfter.first?.completeBytes == UInt64(prefix.utf8.count))
    try SessionReader.verifyPreparation(first)
    #expect(throws: (any Error).self) {
      try fixture.prepare(try fixture.checkpoint(first), limits: limits)
    }
  }
}

@Test func dreamInputExcludesBrokenAttachmentEnvelopeInsteadOfAborting() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  try fixture.write(
    fixture.header() + "\n"
      + dreamUser("m", nil, dreamOld, "<file name=\"a.md\">unterminated") + "\n"
      + dreamUser("u", "m", dreamOld, "<leader>sf opens search") + "\n", to: fixture.file())
  let batch = try fixture.prepare()
  #expect(batch.evidence.map(\.exactText) == ["<leader>sf opens search"])
  guard case .skipped = batch.exactSourceRecords[1].disposition else {
    Issue.record("unknown markup must be skipped")
    return
  }
}

@Test func dreamInputAcceptsLegacySingularAnswer() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let legacy = dreamResult(
    "a", nil, call: "c", tool: "ask_user_question", "Words",
    details: ["status": "answered", "question": "Ship it?", "answer": "Typed legacy answer."])
  try fixture.write(fixture.header() + "\n" + legacy + "\n", to: fixture.file())
  let batch = try fixture.prepare()
  #expect(batch.evidence.map(\.exactText) == ["Typed legacy answer."])
  #expect(batch.evidence.map(\.kind) == [.answered])
}

@Test func dreamInputRepairsLoneSurrogateInCompleteRecord() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let line = dreamUser("u", nil, dreamOld, "Typed LONE text.")
    .replacingOccurrences(of: "LONE", with: #"\ud83d"#)
  try fixture.write(fixture.header() + "\n" + line + "\n", to: fixture.file())
  let batch = try fixture.prepare()
  #expect(batch.evidence.map(\.exactText) == ["Typed \u{FFFD} text."])
}

@Test func dreamInputClassifiesLateMetadataBeyondLineTwentyAndBatch() throws {
  for name in ["worker#abcdef12", "om-observer-late"] {
    let fixture = try DreamInputFixture()
    defer { fixture.clean() }
    var lines = [fixture.header(), dreamUser("u", nil, dreamOld, "Must not support.")]
    lines += (0..<24).map { index in
      dreamJSON([
        "type": "custom", "id": "c\(index)", "timestamp": dreamOld, "customType": "note",
        "data": [:],
      ])
    }
    lines.append(
      dreamJSON(["type": "session_info", "id": "lateinfo", "timestamp": dreamOld, "name": name]))
    try fixture.write(lines.joined(separator: "\n") + "\n", to: fixture.file())
    let first = try fixture.prepare(limits: DreamInputLimits(maximumBatchRecords: 2))
    #expect(first.evidence.isEmpty && !first.isBacklog)
    #expect(first.exactSourceRecords.count == 2)
    guard case .skipped = first.exactSourceRecords[1].disposition else {
      Issue.record("late metadata must skip primary text")
      continue
    }
    let replay = try fixture.prepare(try fixture.checkpoint(first))
    #expect(replay.exactSourceRecords.isEmpty && !replay.isBacklog)
  }
}

@Test func dreamInputChangedSavedClassificationBlocks() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  try fixture.write(
    fixture.header() + "\n" + dreamUser("u", nil, dreamOld, "Earlier primary text.") + "\n",
    to: fixture.file())
  let progress = try fixture.checkpoint(try fixture.prepare())
  try fixture.append(
    dreamJSON([
      "type": "session_info", "id": "lateinfo", "timestamp": dreamOld, "name": "worker#abcdef12",
    ]) + "\n" + dreamUser("new", "u", dreamOld, "Blocked new text.") + "\n", to: fixture.file())
  #expect(throws: (any Error).self) { try fixture.prepare(progress) }
  #expect(progress.generation == 1)
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

@Test func dreamInputOldRecordsSeedContextWithoutNewSupport() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let old = [
    fixture.header(), dreamUser("old", nil, dreamOld, "Old support."),
    dreamAssistant("a", "old", dreamOld, [dreamText("Old agent context.")]),
  ]
  try fixture.write(old.joined(separator: "\n") + "\n", to: fixture.file())
  let progress = try fixture.checkpoint(try fixture.prepare())
  try fixture.append(dreamUser("new", "a", dreamOld, "New human text.") + "\n", to: fixture.file())
  let next = try fixture.prepare(progress)
  #expect(next.evidence.map(\.exactText) == ["New human text."])
  #expect(next.evidence.first?.agentContext == "Old agent context.")
  #expect(next.exactSourceRecords.count == 1)
  #expect(next.evidence.first?.projectScope == fixture.root.path)
}

@Test func dreamInputMetadataChainKeepsOldContextWithoutPrimaryEvidence() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  var lines = [
    fixture.header(), dreamAssistant("a", nil, dreamOld, [dreamText("Accepted context.")]),
  ]
  lines += (0..<2_000).map { index in
    dreamJSON([
      "type": "custom", "id": "c\(index)",
      "parentId": index == 0 ? "a" : "c\(index - 1)", "timestamp": dreamOld, "data": [:],
    ])
  }
  try fixture.write(lines.joined(separator: "\n") + "\n", to: fixture.file())
  let old = try fixture.prepare()
  #expect(old.evidence.isEmpty && old.selections.isEmpty && !old.isBacklog)
  #expect(old.exactSourceRecords.map(\.bytes) == [Data((lines[0] + "\n").utf8), nil])
  let progress = try fixture.checkpoint(old)
  #expect(try fixture.prepare(progress).exactSourceRecords.isEmpty)
  try fixture.append(
    dreamUser("u", "c1999", dreamOld, "New human text.") + "\n", to: fixture.file())
  let next = try fixture.prepare(progress)
  #expect(next.evidence.map(\.exactText) == ["New human text."])
  #expect(next.evidence.first?.agentContext == "Accepted context.")
  #expect(next.exactSourceRecords.count == 1)
}

@Test func dreamInputKeepsLongUnicodeAndExactWitnessesWithoutClipping() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let text = String(repeating: "👩‍👩‍👧é中", count: 1_000) + " exact end"
  let line = dreamUser("u", nil, dreamOld, text) + "\n"
  let header = fixture.header() + "\n"
  try fixture.write(header + line, to: fixture.file())
  let batch = try fixture.prepare()
  let unit = try #require(batch.evidence.first)
  #expect(unit.exactText == text)
  #expect(unit.id.citation.reference == "pi:one#u" && unit.id.part == 0)
  #expect(unit.witness.relativePath.rawValue == "--fixture--/one.jsonl")
  #expect(unit.witness.byteRange == UInt64(header.utf8.count)..<UInt64((header + line).utf8.count))
  #expect(unit.witness.rawRecordHash == SourceDigest(bytes: Data(line.utf8)))
  #expect(batch.exactSourceRecords.last?.bytes == Data(line.utf8))
  let exact = try DreamInputLimits(
    maximumRecordBytes: line.utf8.count, maximumEvidenceBytes: text.utf8.count)
  #expect(try fixture.prepare(limits: exact).evidence.first?.exactText == text)
  #expect(throws: (any Error).self) {
    try fixture.prepare(limits: DreamInputLimits(maximumRecordBytes: line.utf8.count - 1))
  }
  #expect(throws: (any Error).self) {
    try fixture.prepare(limits: DreamInputLimits(maximumEvidenceBytes: text.utf8.count - 1))
  }
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

@Test func dreamInputAnswerPartsStayExactAndOversizedAnswersBlock() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let long = String(repeating: "é😀", count: 2_000)
  let answers = [
    ["type": "text", "label": long], ["type": "option", "label": "Agent choice"],
    ["type": "other", "label": "Other typed answer"],
  ]
  let line = dreamResult(
    "answer", nil, call: "q", tool: "ask_user_question", "Not evidence",
    details: dreamAnswer("answered", answers))
  try fixture.write(fixture.header() + "\n" + line + "\n", to: fixture.file())
  let batch = try fixture.prepare()
  #expect(batch.evidence.map(\.exactText) == [long, "Other typed answer"])
  #expect(batch.evidence.map { $0.id.part } == [0, 2])
  #expect(batch.evidence.map(\.kind) == [.answered, .answered])
  #expect(batch.selections.first?.agentWrittenSelectedLabels == ["Agent choice"])
  #expect(throws: (any Error).self) {
    try fixture.prepare(limits: DreamInputLimits(maximumEvidenceBytes: long.utf8.count - 1))
  }
  let progress = try fixture.checkpoint(batch)
  let context = String(repeating: "c", count: 300)
  try fixture.append(
    dreamAssistant("a", "answer", dreamOld, [dreamText(context)]) + "\n"
      + dreamUser("u", "a", dreamOld, "Small human text.") + "\n", to: fixture.file())
  #expect(throws: (any Error).self) {
    try fixture.prepare(progress, limits: DreamInputLimits(maximumEvidenceBytes: 299))
  }
}

@Test func dreamInputTypedOnlyAnswerKeepsQuestionOutsideHumanEvidence() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  try fixture.write(
    fixture.header() + "\n"
      + dreamResult(
        "answer", nil, call: "q", tool: "ask_user_question", "Agent rendered answer",
        details: dreamAnswer("answered", [["type": "text", "label": "go on"]])) + "\n",
    to: fixture.file())
  let batch = try fixture.prepare()
  #expect(batch.evidence.map(\.exactText) == ["go on"])
  #expect(batch.evidence.map(\.kind) == [.answered])
  #expect(batch.evidence.first?.agentContext == nil)
  #expect(batch.selections.count == 1)
  #expect(batch.selections.first?.question == "Ship it?")
  #expect(batch.selections.first?.agentWrittenSelectedLabels == [])
  #expect(batch.selections.first?.citation == batch.evidence.first?.id.citation)
}

@Test func dreamInputManyTypedAnswersShareExactWitnessAndContext() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let answers = (0..<128).map { ["type": "text", "label": "Typed answer \($0)"] }
  let line =
    dreamResult(
      "answer", "a", call: "q", tool: "ask_user_question", "Agent rendered answers",
      details: dreamAnswer("answered", answers)) + "\n"
  let header =
    fixture.header() + "\n"
    + dreamAssistant("a", nil, dreamOld, [dreamText("Question context.")]) + "\n"
  try fixture.write(header + line, to: fixture.file())
  let batch = try fixture.prepare()
  let source = try #require(batch.exactSourceRecords.last)
  #expect(batch.evidence.map(\.exactText) == answers.map { $0["label"]! })
  #expect(batch.evidence.map { $0.id.part } == Array(0..<128))
  #expect(batch.evidence.allSatisfy { $0.agentContext == "Question context." })
  #expect(batch.evidence.allSatisfy { $0.witness == source.witness })
  #expect(source.bytes == Data(line.utf8))
  #expect(source.witness.rawRecordHash == SourceDigest(bytes: Data(line.utf8)))
  #expect(
    source.witness.byteRange == UInt64(header.utf8.count)..<UInt64((header + line).utf8.count))
  #expect(batch.selections.first?.question == "Ship it?")
  #expect(batch.selections.first?.agentWrittenSelectedLabels == [])
}

@Test func dreamInputGlobalBatchOrderingLeavesUnselectedFilesUnprocessed() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  try fixture.write(
    fixture.header("z") + "\n" + dreamUser("zu", nil, dreamOld, "Later file.") + "\n",
    to: fixture.file("z.jsonl"))
  try fixture.write(
    fixture.header("a") + "\n" + dreamUser("au", nil, dreamOld, "Earlier file.") + "\n",
    to: fixture.file("a.jsonl"))
  let limits = try DreamInputLimits(maximumBatchRecords: 2)
  let first = try fixture.prepare(limits: limits)
  let repeated = try fixture.prepare(limits: limits)
  #expect(first.evidence.map(\.exactText) == ["Earlier file."])
  #expect(first.positionsAfter.map { $0.sessionID.rawValue } == ["a"])
  #expect(first.positionsAfter == repeated.positionsAfter)
  #expect(first.isBacklog)
  let second = try fixture.prepare(try fixture.checkpoint(first), limits: limits)
  #expect(second.evidence.map(\.exactText) == ["Later file."])
  #expect(second.positionsAfter.map { $0.sessionID.rawValue } == ["a", "z"])
  #expect(!second.isBacklog)
}

@Test func dreamInputValidatesProgressAndNamedLimits() throws {
  #expect(throws: (any Error).self) { try DreamProgress(schemaVersion: 99) }
  #expect(throws: (any Error).self) { try DreamInputLimits(maximumBatchRecords: 0) }
  #expect(throws: (any Error).self) { try DreamInputLimits(maximumEvidenceBytes: 0) }
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  try fixture.write(fixture.header() + "\n", to: fixture.file())
  let batch = try fixture.prepare()
  #expect(throws: (any Error).self) {
    try DreamProgress(positions: batch.positionsAfter + batch.positionsAfter)
  }
  let saved = try #require(batch.positionsAfter.first)
  let invalidBoundary = SourcePosition(
    relativePath: saved.relativePath, sessionID: saved.sessionID,
    completeBytes: saved.completeBytes - 1, prefixHash: saved.prefixHash,
    classificationHash: saved.classificationHash)
  #expect(throws: (any Error).self) {
    try fixture.prepare(DreamProgress(positions: [invalidBoundary]))
  }
}

@Test func dreamInputFrozenProvenanceRejectsConcealedPrimaryEvidence() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  try fixture.write(
    fixture.header() + "\n" + dreamUser("u", nil, dreamOld, "Retain this preference.") + "\n",
    to: fixture.file())
  let batch = try fixture.prepare()
  try SessionReader.verifyPreparation(batch)
  let forged = PreparedSessionBatch(
    predecessorGeneration: batch.predecessorGeneration,
    readerSchemaVersion: batch.readerSchemaVersion,
    strippingInputHash: batch.strippingInputHash, positionsAfter: batch.positionsAfter,
    exactSourceRecords: batch.exactSourceRecords.map {
      ExactSourceRecord(witness: $0.witness, bytes: $0.bytes, disposition: .excluded(.metadataV1))
    }, evidence: [], selections: [], unfinishedTails: batch.unfinishedTails,
    isBacklog: batch.isBacklog, provenance: batch.provenance)
  #expect(throws: (any Error).self) { try SessionReader.verifyPreparation(forged) }
}

@Test func dreamInputFrozenProvenanceSharesLateClassificationAndExactStripping() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  try fixture.write(
    "---\nname: fixture\n---\n\nPinned snippet\n",
    to: fixture.snippets.appendingPathComponent("strip.md"))
  try fixture.write("Pinned template $1\n", to: fixture.prompts.appendingPathComponent("strip.md"))
  let records = [
    fixture.header(), dreamUser("snippet", nil, dreamOld, "Pinned snippet"),
    dreamUser(
      "skill", nil, dreamOld,
      "<skill name=\"test\" location=\"/synthetic/SKILL.md\">\nBody\n</skill>"),
    dreamUser("ack", nil, dreamOld, "ok"),
  ]
  try fixture.write(records.joined(separator: "\n") + "\n", to: fixture.file())
  let batch = try fixture.prepare(isStrippingLoaded: true)
  #expect(batch.evidence.isEmpty)
  try FileManager.default.removeItem(at: fixture.snippets)
  try FileManager.default.removeItem(at: fixture.prompts)
  try FileManager.default.removeItem(at: fixture.sessions)
  try SessionReader.verifyPreparation(batch)
  let late = try DreamInputFixture()
  defer { late.clean() }
  try late.write(
    late.header() + "\n" + dreamUser("u", nil, dreamOld, "Child material.") + "\n"
      + dreamJSON([
        "type": "session_info", "id": "late", "timestamp": dreamOld, "name": "om-observer-late",
      ]) + "\n", to: late.file())
  let child = try late.prepare(limits: DreamInputLimits(maximumBatchRecords: 2))
  #expect(child.evidence.isEmpty && !child.isBacklog)
  try FileManager.default.removeItem(at: late.sessions)
  try SessionReader.verifyPreparation(child)
}

@Test func dreamCoverageExcludesUnfinishedTailAndUsesSavedBoundedCursor() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  let header = fixture.header() + "\n"
  let message =
    "{\"type\":\"message\",\"id\":\"entry\",\"timestamp\":\"1999-01-01T00:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"Green buttons.\"}}\n"
  try fixture.write(header + message + "{", to: fixture.file())
  let reader = try fixture.reader()
  let limits = try DreamInputLimits(maximumBatchRecords: 1)
  var backlog: DreamBacklog?
  var reads = 0
  let first = try reader.prepare(
    progress: DreamProgress(), limits: limits,
    beforeRead: { _ in reads += 1 }, backlog: { backlog = $0 })
  #expect(reads == 1)
  #expect(backlog == DreamBacklog(backlogBytes: 14, undreamtBytes: 14, nextBytes: 14))
  #expect(first.positionsAfter.first?.completeBytes == UInt64(header.utf8.count))
  let progress = try DreamProgress(positions: first.positionsAfter)
  let next = try reader.prepare(progress: progress, limits: limits, backlog: { backlog = $0 })
  #expect(backlog == DreamBacklog(backlogBytes: 14, undreamtBytes: 14, nextBytes: 0))
  #expect(next.positionsAfter.first?.completeBytes == UInt64((header + message).utf8.count))
  #expect(next.unfinishedTails.count == 1)
}

@Test func dreamCoverageCancellationStopsPreparationBeforeNextRecord() throws {
  let fixture = try DreamInputFixture()
  defer { fixture.clean() }
  try fixture.write(
    fixture.header() + "\n" + dreamUser("u", nil, dreamOld, "Green.") + "\n",
    to: fixture.file())
  var checks = 0
  #expect(throws: CancellationError.self) {
    try fixture.reader().prepare(
      progress: DreamProgress(), limits: DreamInputLimits(),
      isCancelled: {
        checks += 1
        return checks == 3
      })
  }
  #expect(checks == 3)
}
