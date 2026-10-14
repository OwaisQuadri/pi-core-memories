import Darwin
import Foundation
import Testing

@testable import CoreMemories

func transportStore(_ fixture: TransactionFixture, alias: URL, kind: String) throws -> DreamRunStore
{
  try DreamRunStore(
    stateRoot: fixture.state, sessionsRoot: kind == "sessions" ? alias : fixture.sessions,
    memoryRepository: kind == "memory" ? alias : fixture.memory,
    strippingRoots: [kind == "stripping" ? alias : fixture.snippets])
}

func transportPrepare(_ store: DreamRunStore, progress: DreamProgress) throws
  -> PreparedSessionBatch
{
  let roots = store.acceptedSources
  return try SessionReader(
    sessions: roots.sessions, snippets: roots.stripping.first, environment: [:]
  ).prepare(progress: progress, limits: DreamInputLimits())
}

@Test(arguments: ["sessions", "stripping", "memory"])
func dreamTransportOriginalAliasesReopenWithoutChangingBinding(kind: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let alias = fixture.root.appendingPathComponent("configured-alias")
  let target =
    kind == "sessions" ? fixture.sessions : kind == "memory" ? fixture.memory : fixture.snippets
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
  let first = try transportStore(fixture, alias: alias, kind: kind)
  let before = try fixture.protectedState()
  let report = try transactionCompleted(
    first.run(
      selection: fixture.selection, prepare: { try transportPrepare(first, progress: $0) },
      call: transactionNotes))
  #expect(report.generation == 1)
  let binding = try Data(contentsOf: fixture.state.appendingPathComponent("root.json"))
  let second = try transportStore(fixture, alias: alias, kind: kind)
  let result = try second.run(
    selection: fixture.selection, prepare: { try transportPrepare(second, progress: $0) },
    call: transactionUncalled)
  guard case .noNewRecords(let generation, _) = result else {
    throw MemoryError("expected unchanged aliased source progress")
  }
  #expect(generation == 1)
  #expect(try Data(contentsOf: fixture.state.appendingPathComponent("root.json")) == binding)
  #expect(try fixture.protectedState() == before)
  let other = fixture.root.appendingPathComponent("different-configured-alias")
  try FileManager.default.createSymbolicLink(at: other, withDestinationURL: target)
  let state = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.unsafeState) {
    try transportStore(fixture, alias: other, kind: kind)
  }
  #expect(try fixture.snapshot(fixture.state) == state)
}

@Test(arguments: ["sessions", "stripping"])
func dreamTransportRemovedAliasesAndTargetsReplayFrozenInput(kind: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let alias = fixture.root.appendingPathComponent("configured-alias")
  let target = kind == "sessions" ? fixture.sessions : fixture.snippets
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
  let first = try transportStore(fixture, alias: alias, kind: kind)
  var original: DreamModelRequest?
  _ = try transactionPending(
    first.run(
      selection: fixture.selection, prepare: { try transportPrepare(first, progress: $0) },
      call: { request in
        original = request
        throw CancellationError()
      }), reason: .cancelled)
  let request = try #require(original)
  try FileManager.default.removeItem(at: alias)
  try FileManager.default.removeItem(at: target)
  let second = try transportStore(fixture, alias: alias, kind: kind)
  _ = try transactionPending(
    second.run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled),
    reason: .interruptedCall)
  let report = try transactionCompleted(
    second.run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare,
      call: { replay in
        #expect(replay.requestHash == request.requestHash && replay.messages == request.messages)
        return try transactionNotes(replay)
      }))
  #expect(report.generation == 1 && report.proposals.isEmpty)
}

@Test(arguments: ["sessions", "stripping", "memory"])
func dreamTransportRetargetedAliasCannotAdmitForeignRoots(kind: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let alias = fixture.root.appendingPathComponent("configured-alias")
  let target =
    kind == "sessions" ? fixture.sessions : kind == "memory" ? fixture.memory : fixture.snippets
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
  let first = try transportStore(fixture, alias: alias, kind: kind)
  _ = try first.run(
    selection: fixture.selection, prepare: { try transportPrepare(first, progress: $0) },
    call: transactionUncalled)
  let foreign = fixture.root.appendingPathComponent("foreign")
  try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
  try FileManager.default.removeItem(at: alias)
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign)
  let second = try transportStore(fixture, alias: alias, kind: kind)
  let before = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.unsafeState) {
    try second.run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == before)
}

@Test func dreamTransportCanonicalSchemaTwoBindingBytesStayUnchanged() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let first = try fixture.store()
  _ = try first.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
  let file = fixture.state.appendingPathComponent("root.json")
  let bytes = try Data(contentsOf: file)
  let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
  #expect(object["originalRoots"] == nil)
  let expected = try JSONSerialization.data(
    withJSONObject: [
      "schemaVersion": 2, "sessions": fixture.sessions.path, "memory": fixture.memory.path,
      "stripping": [fixture.snippets.path],
    ], options: [.sortedKeys, .withoutEscapingSlashes])
  #expect(bytes == expected)
  let second = try fixture.store()
  _ = try second.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
  #expect(try Data(contentsOf: file) == bytes)
}

@Test func dreamTransportChildDescriptorCannotRetainReleasedWriterOwnership() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let holder = Process()
  holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
  holder.arguments = ["30"]
  holder.environment = ["PATH": "/usr/bin:/bin"]
  holder.standardOutput = FileHandle.nullDevice
  holder.standardError = FileHandle.nullDevice
  defer {
    if holder.isRunning {
      holder.terminate()
      holder.waitUntilExit()
    }
  }
  let store = try fixture.store()
  _ = try transactionPending(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { _ in
        let expected = fixture.state.appendingPathComponent("writer.lock").path
        var inherited: Int32?
        for descriptor in 3..<min(getdtablesize(), 4096) {
          var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
          if fcntl(descriptor, F_GETPATH, &bytes) == 0 {
            let path = String(
              decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if path == expected {
              inherited = descriptor
              break
            }
          }
        }
        let descriptor = try #require(inherited)
        holder.standardInput = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try holder.run()
        throw CancellationError()
      }), reason: .cancelled)
  #expect(holder.isRunning)
  let second = try fixture.store()
  _ = try transactionPending(
    second.run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled),
    reason: .interruptedCall)
}

@Test func dreamTransportEveryOriginalAliasChecksItsOwnCanonicalTupleEntry() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let firstAlias = fixture.root.appendingPathComponent("first-stripping-alias")
  let secondAlias = fixture.root.appendingPathComponent("second-stripping-alias")
  for alias in [firstAlias, secondAlias] {
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.snippets)
  }
  func store() throws -> DreamRunStore {
    try DreamRunStore(
      stateRoot: fixture.state, sessionsRoot: fixture.sessions,
      memoryRepository: fixture.memory, strippingRoots: [firstAlias, secondAlias])
  }
  let first = try store()
  _ = try first.run(
    selection: fixture.selection, prepare: { try transportPrepare(first, progress: $0) },
    call: transactionUncalled)
  let foreign = fixture.root.appendingPathComponent("foreign-stripping")
  try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
  try FileManager.default.removeItem(at: secondAlias)
  try FileManager.default.createSymbolicLink(at: secondAlias, withDestinationURL: foreign)
  let second = try store()
  let before = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.unsafeState) {
    try second.run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == before)
}

@Test func dreamTransportCancellationAtGenerationInstallRetainsPendingCompletion() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  var isCancelled = false
  var isBoundaryReached = false
  store.isCancelled = { isCancelled }
  store.persistenceFault = { event in
    if event == .beforeInstall("1.json") {
      isBoundaryReached = true
      isCancelled = true
    }
  }
  let report = try transactionPending(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes),
    reason: .cancelled)
  #expect(isBoundaryReached && report.generation == 0)
  #expect(FileManager.default.fileExists(atPath: try fixture.payload("completion.json").path))
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
  let completed = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled))
  #expect(completed.generation == 1 && completed.runID == report.runID)
}

@Test func dreamTransportPublicCancellationCannotCallPublishOrAdvanceProgress() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let before = try fixture.protectedState()
  let store = try DreamRunStore(
    stateRoot: fixture.state, sessionsRoot: fixture.sessions,
    memoryRepository: fixture.memory, strippingRoots: [fixture.snippets], isCancelled: { true })
  let result = try store.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
  let pending = try transactionPending(result, reason: .cancelled)
  #expect(pending.generation == 0 && pending.proposals.isEmpty)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
  #expect(try fixture.protectedState() == before)
  let recovered = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionNotes))
  #expect(recovered.generation == 1)
}
