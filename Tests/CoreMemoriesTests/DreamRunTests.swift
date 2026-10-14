import Darwin
import Foundation
import Testing
import XCTest

@testable import CoreMemories

private func transactionMutate(_ file: URL, _ change: (inout [String: Any]) -> Void) throws {
  var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
  change(&value)
  try JSONSerialization.data(
    withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]
  ).write(to: file)
}

@Test func dreamRunRetryUsesCurrentSelectionWithoutChangingFrozenPayloads() throws {
  for selection in [
    try DreamSelectedCall(provider: "other", modelID: "fixture", thinkingLevel: "off"),
    try DreamSelectedCall(provider: "synthetic", modelID: "other", thinkingLevel: "off"),
    try DreamSelectedCall(provider: "synthetic", modelID: "fixture", thinkingLevel: "medium"),
  ] {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    try fixture.populate()
    var original: DreamModelRequest?
    _ = try fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in original = request; throw CancellationError() })
    let saved = try #require(original)
    try transactionMutate(fixture.payload("call-started.json")) { $0.removeValue(forKey: "selection") }
    let before = try fixture.snapshot(fixture.state)
    let protected = try fixture.protectedState()
    _ = try transactionPending(
      fixture.store().run(
        selection: selection, prepare: transactionUncalledPrepare, call: transactionUncalled),
      reason: .interruptedCall)
    #expect(try fixture.snapshot(fixture.state) == before)
    let report = try transactionCompleted(
      fixture.store().run(
        selection: selection, resume: .retryInterruptedCall, prepare: transactionUncalledPrepare,
        call: { request in
          #expect(request.selection == selection)
          #expect(request.inputHash == saved.inputHash && request.contextHash == saved.contextHash)
          #expect(request.requestHash == saved.requestHash && request.runID == saved.runID)
          #expect(request.systemPrompt == saved.systemPrompt && request.messages == saved.messages)
          return try transactionNotes(request)
        }))
    #expect(report.generation == 1 && report.isRecovered)
    let after = try fixture.snapshot(fixture.state)
    for name in ["input.json", "context.json", "request.json"] {
      let path = try fixture.payload(name).path
      #expect(after[path] == before[path])
    }
    let admission = fixture.state.appendingPathComponent("admissions/0.json").path
    #expect(after[admission] == before[admission])
    #expect(try fixture.protectedState() == protected)
    let response = try DreamRunEncoding.decode(
      DreamRunEncoding.BoundResponse.self, bytes: Data(contentsOf: fixture.payload("response.json")))
    #expect(try response.selection.domain() == selection)
    #expect(try transactionCompleted(fixture.store().run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare, call: transactionUncalled)).runID == report.runID)
  }
}

@Test func dreamRunUnstartedAdmissionUsesCurrentSelection() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  store.isCancelled = { true }
  _ = try transactionPending(store.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled),
    reason: .cancelled)
  let selection = try DreamSelectedCall(provider: "other", modelID: "other", thinkingLevel: "high")
  let report = try transactionCompleted(fixture.store().run(
    selection: selection, prepare: transactionUncalledPrepare,
    call: { request in
      #expect(request.selection == selection)
      return try transactionNotes(request)
    }))
  #expect(report.generation == 1 && report.isRecovered)
}

@Test func dreamRunCompletedRecoveryUsesSavedResponseUnderChangedSelection() throws {
  for isMissingCache in [false, true] {
    for selection in [
      try DreamSelectedCall(provider: "other", modelID: "fixture", thinkingLevel: "off"),
      try DreamSelectedCall(provider: "synthetic", modelID: "other", thinkingLevel: "off"),
      try DreamSelectedCall(provider: "synthetic", modelID: "fixture", thinkingLevel: "medium"),
    ] {
      let fixture = try TransactionFixture()
      defer { fixture.clean() }
      _ = try fixture.store().run(
        selection: fixture.selection, prepare: { try fixture.prepare($0) },
        call: transactionUncalled)
      let cache = fixture.state.appendingPathComponent("state.json")
      let genesisCache = try Data(contentsOf: cache)
      try fixture.populate()
      _ = try fixture.store().run(
        selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes)
      if isMissingCache {
        try FileManager.default.removeItem(at: cache)
      } else {
        try genesisCache.write(to: cache)
      }
      try transactionMutate(fixture.payload("call-started.json")) { $0.removeValue(forKey: "selection") }
      let responseBefore = try Data(contentsOf: fixture.payload("response.json"))
      let report = try transactionCompleted(fixture.store().run(
        selection: selection, prepare: transactionUncalledPrepare, call: transactionUncalled))
      #expect(report.generation == 1 && report.isRecovered && report.notes.count == 1)
      #expect(try Data(contentsOf: fixture.payload("response.json")) == responseBefore)
    }
  }
}

@Test func dreamRunNewAdmissionRejectsSubstitutedRootAncestors() throws {
  for rootIndex in 0..<3 {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    let ancestor = fixture.root.appendingPathComponent("bound")
    try FileManager.default.createDirectory(at: ancestor, withIntermediateDirectories: false)
    let sources = [fixture.sessions, fixture.memory, fixture.snippets]
    let bound = ancestor.appendingPathComponent(sources[rootIndex].lastPathComponent)
    try FileManager.default.moveItem(at: sources[rootIndex], to: bound)
    var roots = sources
    roots[rootIndex] = bound
    func store() throws -> DreamRunStore {
      try DreamRunStore(
        stateRoot: fixture.state, sessionsRoot: roots[0], memoryRepository: roots[1],
        strippingRoots: [roots[2]])
    }
    _ = try store().run(
      selection: fixture.selection,
      prepare: { progress in
        try SessionReader(sessions: roots[0], snippets: roots[2], environment: [:]).prepare(
          progress: progress, limits: DreamInputLimits())
      }, call: transactionUncalled)
    let displaced = fixture.root.appendingPathComponent("displaced")
    try FileManager.default.moveItem(at: ancestor, to: displaced)
    let foreign = fixture.root.appendingPathComponent("foreign")
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(
      at: foreign.appendingPathComponent(bound.lastPathComponent),
      withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: foreign)
    let before = try fixture.snapshot(fixture.state)
    let foreignBefore = try fixture.snapshot(foreign)
    #expect(throws: DreamRunError.unsafeState) {
      try store().run(
        selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled
      )
    }
    #expect(try fixture.snapshot(fixture.state) == before)
    #expect(try fixture.snapshot(foreign) == foreignBefore)
  }
}

@Test func dreamRunCommittedRecoveryRejectsForeignMemoryWithoutSourceReads() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  _ = try fixture.store().run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { try transactionAdd($0) })
  try FileManager.default.removeItem(at: fixture.state.appendingPathComponent("state.json"))
  try FileManager.default.removeItem(at: fixture.sessions)
  try FileManager.default.removeItem(at: fixture.snippets)
  let moved = fixture.root.appendingPathComponent("original-memory")
  try FileManager.default.moveItem(at: fixture.memory, to: moved)
  let foreign = fixture.root.appendingPathComponent("foreign-memory")
  try MemoryStore.initialize(repo: foreign, environment: [:])
  try FileManager.default.createSymbolicLink(at: fixture.memory, withDestinationURL: foreign)
  let before = try fixture.snapshot(fixture.state)
  let foreignBefore = try fixture.snapshot(foreign)
  #expect(throws: DreamRunError.unsafeState) {
    try fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == before)
  #expect(try fixture.snapshot(foreign) == foreignBefore)
}

@Test func dreamRunEmptyAndTailOnlyHaveNoRunCallOrGeneration() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  for isTail in [false, true] {
    if isTail { try fixture.write("{\"partial\":", file: fixture.source) }
    let result = try fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
    guard case .noNewRecords(let generation, let tails) = result else {
      throw MemoryError("expected no records")
    }
    #expect(generation == 0 && tails.count == (isTail ? 1 : 0))
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: fixture.state.appendingPathComponent("runs").path
      ).isEmpty)
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: fixture.state.appendingPathComponent("admissions").path
      ).isEmpty)
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: fixture.state.appendingPathComponent("generations").path) == ["0.json"])
  }
}

@Test func dreamRunReentrantAndSeparateStoreHoldStableKernelLock() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  let other = try fixture.store()
  var inode: ino_t = 0
  let result = try store.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { request in
      var status = stat()
      #expect(lstat(fixture.state.appendingPathComponent("writer.lock").path, &status) == 0)
      inode = status.st_ino
      for candidate in [store, other] {
        #expect(throws: DreamRunError.busy) {
          try candidate.run(
            selection: fixture.selection, prepare: transactionUncalledPrepare,
            call: transactionUncalled)
        }
      }
      return try transactionNotes(request)
    })
  #expect(try transactionCompleted(result).generation == 1)
  var status = stat()
  #expect(lstat(fixture.state.appendingPathComponent("writer.lock").path, &status) == 0)
  #expect(status.st_ino == inode)
}

@Test func dreamRunActualShortWritesInstallEveryTransactionPayload() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  var shortCount = 0
  store.writeCall = { descriptor, bytes, count in
    let written = Darwin.write(descriptor, bytes, min(3, count))
    if written > 0 && written < count { shortCount += 1 }
    return written
  }
  let report = try transactionCompleted(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes))
  #expect(shortCount > 0 && report.generation == 1)
  try FileManager.default.removeItem(at: fixture.state.appendingPathComponent("state.json"))
  #expect(
    try transactionCompleted(
      fixture.store().run(
        selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled
      )
    ).generation == 1)
}

private let transactionPayloads = [
  "input.json", "context.json", "request.json", "0.json", "call-started.json", "response.json",
  "decisions.json", "completion.json", "1.json", "state.json",
]
private func transactionBoundaries(_ name: String) -> [DreamPersistenceEvent] {
  [
    .beforeWrite(name), .afterWriteChunk(name), .afterWrite(name), .beforeFileSync(name),
    .afterFileSync(name), .beforeInstall(name), .afterInstall(name), .beforeDirectorySync(name),
    .afterDirectorySync(name),
  ]
}

@Test func dreamRunEveryPayloadPersistenceBoundaryRefusesFalseCompletion() throws {
  for name in transactionPayloads {
    for target in transactionBoundaries(name) {
      let fixture = try TransactionFixture()
      defer { fixture.clean() }
      _ = try fixture.store().run(
        selection: fixture.selection, prepare: { try fixture.prepare($0) },
        call: transactionUncalled)
      try fixture.populate()
      let store = try fixture.store()
      var isTriggered = false
      store.persistenceFault = { event in
        if event == target {
          isTriggered = true
          throw POSIXError(.ENOSPC)
        }
      }
      #expect(throws: DreamRunError.persistenceFailure, "\(target)") {
        try store.run(
          selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes
        )
      }
      #expect(isTriggered)
      #expect(
        try Git(repo: fixture.memory, environment: [:]).text([
          "for-each-ref", "--format=%(refname)", "refs/heads/proposals/",
        ]).isEmpty)
      let state = try fixture.snapshot(fixture.state)
      store.persistenceFault = nil
      do {
        let result = try store.run(
          selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes
        )
        if case .completed(let report) = result { #expect(report.generation == 1) }
      } catch let error as DreamRunError {
        #expect([.missingPayload, .corruption, .unsafeState].contains(error))
        #expect(try fixture.snapshot(fixture.state) == state)
      }
    }
  }
}

@Test func dreamRunRetryIntentReplacementFailureKeepsExplicitRecovery() throws {
  for target in transactionBoundaries("call-started.json") {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    try fixture.populate()
    _ = try fixture.store().run(selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { _ in throw CancellationError() })
    let selection = try DreamSelectedCall(provider: "other", modelID: "other", thinkingLevel: "high")
    let store = try fixture.store()
    store.persistenceFault = { if $0 == target { throw POSIXError(.EIO) } }
    #expect(throws: DreamRunError.persistenceFailure) {
      try store.run(selection: selection, resume: .retryInterruptedCall,
        prepare: transactionUncalledPrepare, call: transactionUncalled)
    }
    _ = try transactionPending(fixture.store().run(selection: selection,
      prepare: transactionUncalledPrepare, call: transactionUncalled), reason: .interruptedCall)
    let report = try transactionCompleted(fixture.store().run(
      selection: selection, resume: .retryInterruptedCall, prepare: transactionUncalledPrepare,
      call: { request in
        #expect(request.selection == selection)
        return try transactionNotes(request)
      }))
    #expect(report.generation == 1 && report.isRecovered)
  }
}

@Test func dreamRunDecisionsAreDurableBeforeEveryPublicationBoundary() throws {
  for target in transactionBoundaries("decisions.json") {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    try fixture.populate()
    let store = try fixture.store()
    store.persistenceFault = { if $0 == target { throw POSIXError(.EIO) } }
    #expect(throws: DreamRunError.persistenceFailure) {
      try store.run(
        selection: fixture.selection, prepare: { try fixture.prepare($0) },
        call: { try transactionAdd($0) })
    }
    #expect(
      try Git(repo: fixture.memory, environment: [:]).text([
        "for-each-ref", "--format=%(refname)", "refs/heads/proposals/",
      ]).isEmpty)
  }
}

@Test func dreamRunFailedSyscallsPreservePendingAndOrphanEvidence() throws {
  for payload in [
    "input.json", "context.json", "request.json", "0.json", "call-started.json", "response.json",
    "decisions.json", "receipt", "completion.json", "1.json", "state.json",
  ] {
    for failure in ["write", "shortThenFull", "fileSync", "install", "directorySync"] {
      let fixture = try TransactionFixture()
      defer { fixture.clean() }
      _ = try fixture.store().run(
        selection: fixture.selection, prepare: { try fixture.prepare($0) },
        call: transactionUncalled)
      try fixture.populate()
      let store = try fixture.store()
      var event: DreamPersistenceEvent?
      var shortCount = 0
      var failures = 0
      store.persistenceFault = { current in
        switch current {
        case .beforeWrite(let name) where payload == "receipt" && name.count == 69:
          event = .beforeWrite(payload)
        case .afterWriteChunk(let name) where payload == "receipt" && name.count == 69:
          event = .afterWriteChunk(payload)
        case .beforeFileSync(let name) where payload == "receipt" && name.count == 69:
          event = .beforeFileSync(payload)
        case .beforeDirectorySync(let name) where payload == "receipt" && name.count == 69:
          event = .beforeDirectorySync(payload)
        default: event = current
        }
      }
      store.writeCall = { file, bytes, requested in
        if failure == "write", event == .beforeWrite(payload) {
          failures += 1
          errno = ENOSPC
          return -1
        }
        if failure == "shortThenFull",
          event == .beforeWrite(payload) || event == .afterWriteChunk(payload)
        {
          if shortCount == 0 {
            shortCount += 1
            return Darwin.write(file, bytes, min(3, requested))
          }
          failures += 1
          errno = ENOSPC
          return -1
        }
        return Darwin.write(file, bytes, requested)
      }
      store.syncCall = { file in
        if (failure == "fileSync" && event == .beforeFileSync(payload))
          || (failure == "directorySync" && event == .beforeDirectorySync(payload))
        {
          failures += 1
          errno = EIO
          return -1
        }
        return Darwin.fsync(file)
      }
      store.installCall = { directory, temporary, name, isReplacing in
        if failure == "install", name == payload || (payload == "receipt" && name.count == 69) {
          failures += 1
          errno = EIO
          return -1
        }
        return isReplacing
          ? Darwin.renameat(directory, temporary, directory, name)
          : Darwin.renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL))
      }
      #expect(throws: DreamRunError.persistenceFailure) {
        try store.run(
          selection: fixture.selection, prepare: { try fixture.prepare($0) },
          call: { try transactionAdd($0) }
        )
      }
      #expect(failures == 1)
      if failure == "shortThenFull" {
        #expect(shortCount == 1)
        #expect(
          try fixture.snapshot(fixture.state).contains {
            $0.key.contains(".pending-") && $0.value.bytes.count == 3
          })
      }
    }
  }
}

@Test func dreamRunResponseInstallSurvivesPointerLossWithZeroReplacementCalls() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  var calls = 0
  store.persistenceFault = {
    if $0 == .afterDirectorySync("response.json") { throw POSIXError(.EIO) }
  }
  #expect(throws: DreamRunError.persistenceFailure) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        calls += 1
        return try transactionNotes(request)
      })
  }
  let original = try Data(contentsOf: fixture.payload("response.json"))
  try FileManager.default.removeItem(at: fixture.state.appendingPathComponent("state.json"))
  let selection = try DreamSelectedCall(provider: "other", modelID: "other", thinkingLevel: "high")
  let report = try transactionCompleted(
    fixture.store().run(
      selection: selection, prepare: transactionUncalledPrepare, call: transactionUncalled))
  #expect(report.generation == 1 && calls == 1)
  #expect(try Data(contentsOf: fixture.payload("response.json")) == original)
}

@Test func dreamRunResponseSelectionMustMatchDurableCallIntent() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  store.persistenceFault = {
    if $0 == .afterDirectorySync("response.json") { throw POSIXError(.EIO) }
  }
  #expect(throws: DreamRunError.persistenceFailure) {
    try store.run(selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: transactionNotes)
  }
  try transactionMutate(fixture.payload("call-started.json")) {
    $0["selection"] = ["provider": "other", "modelID": "other", "thinkingLevel": "high"]
  }
  let before = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.corruption) {
    try fixture.store().run(selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == before)
}

@Test func dreamRunUnsafeAuthorityAndCorruptionFailWithoutWrites() throws {
  for corruption in [
    "symlink", "hardlink", "permissions", "fifo", "missingInput", "missingContext", "pointer",
    "schema", "generation", "unknownField", "request", "admission",
  ] {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    try fixture.populate()
    _ = try fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { _ in throw CancellationError() })
    let input = try fixture.payload("input.json")
    switch corruption {
    case "symlink":
      let moved = fixture.root.appendingPathComponent("moved")
      try FileManager.default.moveItem(at: input, to: moved)
      try FileManager.default.createSymbolicLink(at: input, withDestinationURL: moved)
    case "hardlink":
      #expect(link(input.path, fixture.root.appendingPathComponent("hardlink").path) == 0)
    case "permissions": #expect(chmod(input.path, 0o644) == 0)
    case "fifo":
      try FileManager.default.removeItem(at: input)
      #expect(mkfifo(input.path, 0o600) == 0)
    case "missingInput": try FileManager.default.removeItem(at: input)
    case "missingContext": try FileManager.default.removeItem(at: fixture.payload("context.json"))
    case "pointer": try Data("{".utf8).write(to: fixture.state.appendingPathComponent("state.json"))
    case "schema":
      try transactionMutate(fixture.state.appendingPathComponent("root.json")) {
        $0["schemaVersion"] = 1
      }
    case "generation":
      try transactionMutate(fixture.state.appendingPathComponent("state.json")) {
        $0["generation"] = 1
      }
    case "unknownField":
      try transactionMutate(fixture.state.appendingPathComponent("admissions/0.json")) {
        $0["forged"] = "unrecognized"
      }
    case "request":
      try transactionMutate(fixture.payload("request.json")) { $0["systemPrompt"] = "changed" }
    default:
      try transactionMutate(fixture.state.appendingPathComponent("admissions/0.json")) {
        $0["predecessorHash"] = String(repeating: "0", count: 64)
      }
    }
    let before = try fixture.snapshot(fixture.state)
    #expect(throws: (any Error).self) {
      try fixture.store().run(
        selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled
      )
    }
    #expect(try fixture.snapshot(fixture.state) == before)
  }
}

@Test func dreamRunSchemaOneSavedResponseIsExplicitlyRefusedWithoutLiveReads() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  _ = try fixture.store().run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { _ in throw CancellationError() })
  try transactionMutate(fixture.state.appendingPathComponent("root.json")) {
    $0["schemaVersion"] = 1
  }
  try transactionMutate(fixture.state.appendingPathComponent("state.json")) {
    $0 = [
      "schemaVersion": 1, "revision": 3, "generation": 0, "phase": "responseSaved",
      "runID": "00000000-0000-4000-8000-000000000001",
      "inputHash": String(repeating: "a", count: 64),
      "responseHash": String(repeating: "b", count: 64),
    ]
  }
  try FileManager.default.removeItem(at: fixture.sessions)
  try FileManager.default.removeItem(at: fixture.snippets)
  let before = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.unsupportedSchema) {
    try fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(DreamRunError.unsupportedSchema.description.contains("lack pinned decision context"))
  #expect(try fixture.snapshot(fixture.state) == before)
}

@Test func dreamRunGenerationGapsAndForgedCompletionCannotAuthorizeProgress() throws {
  for corruption in ["gap", "predecessor", "completion", "positions", "overflow"] {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    try fixture.populate()
    _ = try fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes)
    let one = fixture.state.appendingPathComponent("generations/1.json")
    switch corruption {
    case "gap":
      try FileManager.default.moveItem(
        at: one, to: fixture.state.appendingPathComponent("generations/2.json"))
    case "predecessor":
      try transactionMutate(one) { $0["predecessorHash"] = String(repeating: "0", count: 64) }
    case "completion":
      try transactionMutate(one) { $0["completionHash"] = String(repeating: "0", count: 64) }
    case "positions":
      try transactionMutate(one) {
        var progress = $0["progress"] as! [String: Any]
        progress["positions"] = []
        $0["progress"] = progress
      }
    default:
      try transactionMutate(one) {
        var progress = $0["progress"] as! [String: Any]
        progress["generation"] = UInt64.max
        $0["progress"] = progress
      }
    }
    let before = try fixture.snapshot(fixture.state)
    #expect(throws: (any Error).self) {
      try fixture.store().run(
        selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled
      )
    }
    #expect(try fixture.snapshot(fixture.state) == before)
  }
}

@Test func dreamRunSafetyLimitsArePositiveExactAndExpansionAware() throws {
  #expect(try DreamRunLimits().maximumPositions == 32_768)
  for limits in [(0, 1, 1, 1), (1, 0, 1, 1), (1, 1, 0, 1), (1, 1, 1, 0)] {
    #expect(throws: DreamRunError.limitExceeded) {
      try DreamRunLimits(
        maximumFrozenBytes: limits.0, maximumResponseBytes: limits.1, maximumPositions: limits.2,
        maximumStateBytes: limits.3)
    }
  }
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let batch = try fixture.prepare(DreamProgress())
  let runID = UUID().uuidString.lowercased()
  let binding = SourceDigest(bytes: Data("roots".utf8))
  let context = try DreamRunContext(
    selection: fixture.selection, currentApprovedBase: fixture.main())
  let input = try DreamRunEncoding.input(
    runID: runID, context: context, bindingHash: binding, progress: DreamProgress(), batch: batch,
    limits: DreamRunLimits())
  #expect(input.count > batch.exactSourceRecords.reduce(0) { $0 + ($1.bytes?.count ?? 0) })
  #expect(
    try DreamRunEncoding.input(
      runID: runID, context: context, bindingHash: binding, progress: DreamProgress(), batch: batch,
      limits: DreamRunLimits(maximumFrozenBytes: input.count)) == input)
  #expect(throws: DreamRunError.limitExceeded) {
    try DreamRunEncoding.input(
      runID: runID, context: context, bindingHash: binding, progress: DreamProgress(), batch: batch,
      limits: DreamRunLimits(maximumFrozenBytes: input.count - 1))
  }
  try DreamRunEncoding.validate(
    progress: DreamProgress(), batch: batch, limits: DreamRunLimits(maximumPositions: 1))
  try fixture.write(
    dreamHeader("two", cwd: fixture.root.path, name: nil) + "\n",
    file: fixture.sessions.appendingPathComponent("--fixture--/two.jsonl"))
  #expect(throws: DreamRunError.limitExceeded) {
    try DreamRunEncoding.validate(
      progress: DreamProgress(), batch: fixture.prepare(DreamProgress()),
      limits: DreamRunLimits(maximumPositions: 1))
  }
  _ = try fixture.store().run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { _ in throw CancellationError() })
  let retained = try fixture.snapshot(fixture.state).values.reduce(0) { $0 + $1.bytes.count }
  _ = try transactionPending(
    fixture.store(limits: DreamRunLimits(maximumStateBytes: retained)).run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled),
    reason: .interruptedCall)
  #expect(throws: DreamRunError.limitExceeded) {
    try fixture.store(limits: DreamRunLimits(maximumStateBytes: retained - 1)).run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  let orphan = fixture.state.appendingPathComponent("orphan")
  let descriptor = open(orphan.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
  #expect(descriptor >= 0 && Darwin.write(descriptor, "x", 1) == 1 && close(descriptor) == 0)
  #expect(throws: DreamRunError.limitExceeded) {
    try fixture.store(limits: DreamRunLimits(maximumStateBytes: retained)).run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(FileManager.default.fileExists(atPath: orphan.path))
}

@Test func dreamRunStatePlacementAndForeignBindingRemainProtected() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  for state in [
    fixture.sessions, fixture.root, fixture.memory.appendingPathComponent("state"),
    fixture.snippets.appendingPathComponent("state"),
  ] {
    #expect(throws: DreamRunError.unsafeState) { try fixture.store(state: state) }
  }
  let target = fixture.root.appendingPathComponent("target")
  #expect(mkdir(target.path, 0o700) == 0)
  let alias = fixture.root.appendingPathComponent("alias")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
  #expect(throws: DreamRunError.unsafeState) { try fixture.store(state: alias) }
  try fixture.populate()
  _ = try fixture.store().run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { _ in throw CancellationError() })
  let foreign = fixture.root.appendingPathComponent("foreign")
  try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
  let before = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.unsafeState) {
    let store = try DreamRunStore(
      stateRoot: fixture.state, sessionsRoot: foreign, memoryRepository: fixture.memory,
      strippingRoots: [fixture.snippets])
    _ = try store.run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == before)
  for isDirectory in [false, true] {
    var status = stat()
    status.st_uid = geteuid()
    status.st_mode = isDirectory ? S_IFDIR | 0o700 : S_IFREG | 0o600
    status.st_nlink = 1
    try DreamRunStore.validateStateIdentity(status, isDirectory: isDirectory)
    status.st_uid = geteuid() == 0 ? 1 : 0
    #expect(throws: DreamRunError.unsafeState) {
      try DreamRunStore.validateStateIdentity(status, isDirectory: isDirectory)
    }
  }
}

final class DreamRunProcessHelper: XCTestCase {
  func testSavedRunHelper() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let root = environment["DREAM_RUN_FIXTURE"], let mode = environment["DREAM_RUN_MODE"]
    else { return }
    let fixture = try TransactionFixture(root: URL(fileURLWithPath: root), isCreating: false)
    let store = try fixture.store()
    var inheritedLocks = 0
    for descriptor in 3..<min(getdtablesize(), 4096) {
      var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      if fcntl(descriptor, F_GETPATH, &path) == 0,
        String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
          .hasSuffix("/writer.lock")
      {
        inheritedLocks += 1
      }
    }
    try fixture.write(
      String(inheritedLocks), file: fixture.root.appendingPathComponent("helper-inherited-locks"))
    func pause() throws {
      try fixture.write("boundary", file: fixture.root.appendingPathComponent("helper-signal"))
      while true { usleep(10_000) }
    }
    var cacheInstalls = 0
    if mode == "boundary", let name = environment["DREAM_RUN_PAYLOAD"] {
      store.persistenceFault = {
        if $0 == .afterInstall("state.json") { cacheInstalls += 1 }
        if $0 == .afterInstall(name), name != "state.json" || cacheInstalls == 3 { try pause() }
      }
      if name == "finalReport" { store.beforeFinalReport = { try pause() } }
    }
    let verdict: String
    do {
      let result = try store.run(
        selection: fixture.selection,
        resume: mode == "recover" ? .retryInterruptedCall : .inspectOrContinue,
        prepare: { progress in
          if mode == "reopen" || mode == "recover" { throw MemoryError("unexpected preparation") }
          return try fixture.prepare(progress)
        },
        call: { request in
          if mode == "reopen" || mode == "recover" {
            try fixture.write(
              "called", file: fixture.root.appendingPathComponent("helper-reopened-called"))
            throw MemoryError("unexpected model call")
          }
          if mode == "hold" { try pause() }
          try fixture.write(
            "called", file: fixture.root.appendingPathComponent("helper-initial-called"))
          return try transactionAdd(request)
        })
      switch result {
      case .completed: verdict = "completed"
      case .pending: verdict = "pending"
      case .noNewRecords: verdict = "idle"
      }
    } catch let error as DreamRunError { verdict = error == .busy ? "busy" : "blocked" } catch {
      verdict = "blocked"
    }
    try fixture.write(verdict, file: fixture.root.appendingPathComponent("helper-result"))
  }
}

private func transactionStartHelper(
  _ fixture: TransactionFixture, mode: String, payload: String? = nil
) throws -> Process {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  process.arguments = [
    "xctest", "-XCTest", "CoreMemoriesTests.DreamRunProcessHelper/testSavedRunHelper",
    Bundle(for: DreamRunProcessHelper.self).bundleURL.path,
  ]
  process.environment = [
    "PATH": "/usr/bin:/bin", "DREAM_RUN_FIXTURE": fixture.root.path, "DREAM_RUN_MODE": mode,
  ]
  if let payload { process.environment?["DREAM_RUN_PAYLOAD"] = payload }
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  return process
}

private func transactionWait(_ fixture: TransactionFixture, process: Process) throws {
  let deadline = Date().addingTimeInterval(15)
  while Date() < deadline {
    if FileManager.default.fileExists(
      atPath: fixture.root.appendingPathComponent("helper-signal").path)
    {
      return
    }
    guard process.isRunning else { throw MemoryError("helper exited before boundary") }
    usleep(10_000)
  }
  throw MemoryError("helper timeout")
}

@Test func dreamRunProcessLockContentionAndDeathReleaseKernelOwnership() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let owner = try transactionStartHelper(fixture, mode: "hold")
  defer {
    if owner.isRunning {
      kill(owner.processIdentifier, SIGKILL)
      owner.waitUntilExit()
    }
  }
  try transactionWait(fixture, process: owner)
  let state = try fixture.snapshot(fixture.state)
  let competitor = try transactionStartHelper(fixture, mode: "reopen")
  competitor.waitUntilExit()
  #expect(
    try String(contentsOf: fixture.root.appendingPathComponent("helper-result"), encoding: .utf8)
      == "busy")
  #expect(try fixture.snapshot(fixture.state) == state)
  #expect(kill(owner.processIdentifier, SIGKILL) == 0)
  owner.waitUntilExit()
  let successor = try transactionStartHelper(fixture, mode: "reopen")
  successor.waitUntilExit()
  let verdict = try String(
    contentsOf: fixture.root.appendingPathComponent("helper-result"), encoding: .utf8)
  let inherited = try String(
    contentsOf: fixture.root.appendingPathComponent("helper-inherited-locks"), encoding: .utf8)
  #expect(
    verdict == "pending",
    "successor verdict: \(verdict); exit: \(successor.terminationStatus); inherited locks: \(inherited)"
  )
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.root.appendingPathComponent("helper-reopened-called").path))
}

@Test func dreamRunProcessDeathRecoversInstalledResponseCompletionAndGeneration() throws {
  for payload in [
    "response.json", "decisions.json", "completion.json", "1.json", "state.json", "finalReport",
  ] {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    try fixture.populate()
    let owner = try transactionStartHelper(fixture, mode: "boundary", payload: payload)
    defer {
      if owner.isRunning {
        kill(owner.processIdentifier, SIGKILL)
        owner.waitUntilExit()
      }
    }
    try transactionWait(fixture, process: owner)
    #expect(kill(owner.processIdentifier, SIGKILL) == 0)
    owner.waitUntilExit()
    let successor = try transactionStartHelper(fixture, mode: "recover")
    successor.waitUntilExit()
    let verdict = try String(
      contentsOf: fixture.root.appendingPathComponent("helper-result"), encoding: .utf8)
    #expect(verdict == "completed", "death boundary: \(payload); verdict: \(verdict)")
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("helper-reopened-called").path))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("helper-initial-called").path))
    #expect(
      try Git(repo: fixture.memory, environment: [:]).text([
        "for-each-ref", "--format=%(refname)", "refs/heads/proposals/",
      ]).split(separator: "\n").count == 1)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.state.appendingPathComponent("generations/2.json").path))
  }
}

@Test func dreamRunDefaultPositionCapacityAccepts32768AndRejectsOneOver() throws {
  let hash = SourceDigest(bytes: Data("positions".utf8))
  let stripping = SourceDigest(bytes: Data("snippets\0templates\0".utf8))
  let positions = try (0..<32_769).map { index in
    try SourcePosition(
      relativePath: SourceRelativePath("--fixture--/\(index).jsonl"),
      sessionID: SessionIdentifier("session\(index)"), completeBytes: 1, prefixHash: hash,
      classificationHash: hash)
  }
  func validate(_ values: [SourcePosition]) throws {
    let progress = try DreamProgress(generation: 17, positions: values)
    let batch = PreparedSessionBatch(
      predecessorGeneration: 17, readerSchemaVersion: 1,
      strippingInputHash: stripping, positionsAfter: values, exactSourceRecords: [], evidence: [],
      selections: [], unfinishedTails: [], isBacklog: false,
      provenance: PreparationProvenance(stripping: [], sessions: []))
    try DreamRunEncoding.validate(progress: progress, batch: batch, limits: DreamRunLimits())
  }
  try validate(Array(positions.prefix(32_768)))
  #expect(throws: DreamRunError.limitExceeded) { try validate(positions) }
}

@Test func dreamRunRetainedDirectoryDepthAcceptsExactAndRejectsOneOver() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try fixture.store().run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
  var directory = fixture.state
  for _ in 0..<63 {
    directory.appendPathComponent("retained")
    #expect(mkdir(directory.path, 0o700) == 0)
  }
  _ = try fixture.store().run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
  directory.appendPathComponent("one-over")
  #expect(mkdir(directory.path, 0o700) == 0)
  let before = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.limitExceeded) {
    try fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == before)
}

@Test func dreamRunUnadmittedPayloadsCannotAuthorizeReplay() throws {
  for boundary in [
    DreamPersistenceEvent.beforeInstall("0.json"), .afterDirectorySync("request.json"),
  ] {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    _ = try fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
    try fixture.populate()
    let store = try fixture.store()
    var isTriggered = false
    store.persistenceFault = {
      if $0 == boundary {
        isTriggered = true
        throw POSIXError(.EIO)
      }
    }
    #expect(throws: DreamRunError.persistenceFailure) {
      try store.run(
        selection: fixture.selection, prepare: { try fixture.prepare($0) },
        call: transactionUncalled)
    }
    #expect(isTriggered)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.state.appendingPathComponent("admissions/0.json").path))
    try FileManager.default.removeItem(at: fixture.source)
    let result = try fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
    guard case .noNewRecords(let generation, _) = result else {
      throw MemoryError("orphan selected a run")
    }
    #expect(generation == 0)
  }
}

@Test func dreamRunGenesisPersistenceBoundariesAreDistinctFromAdmission() throws {
  for boundary in transactionBoundaries("0.json") {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    var isTriggered = false
    store.persistenceFault = {
      if $0 == boundary {
        isTriggered = true
        throw POSIXError(.EIO)
      }
    }
    #expect(throws: DreamRunError.persistenceFailure) {
      try store.run(
        selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled
      )
    }
    #expect(isTriggered)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.state.appendingPathComponent("admissions/0.json").path))
  }
}

@Test func dreamRunRetainedDirectoryBoundsAndEstablishedLockCannotReset() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try fixture.store().run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
  let orphan = fixture.state.appendingPathComponent("orphan-directory")
  #expect(mkdir(orphan.path, 0o700) == 0)
  for index in 0..<10_000 {
    let descriptor = open(
      orphan.appendingPathComponent(String(index)).path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    #expect(descriptor >= 0 && close(descriptor) == 0)
  }
  _ = try fixture.store().run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
  let descriptor = open(
    orphan.appendingPathComponent("extra").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
  #expect(descriptor >= 0 && close(descriptor) == 0)
  #expect(throws: DreamRunError.limitExceeded) {
    try fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  try FileManager.default.removeItem(at: orphan)
  for name in ["root.json", "state.json", "runs", "generations", "admissions"] {
    try FileManager.default.removeItem(at: fixture.state.appendingPathComponent(name))
  }
  #expect(throws: DreamRunError.missingPayload) {
    try fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
}

@Test func dreamRunResponseUTF8AndFrozenPayloadBoundariesRemainExact() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let maximum = try DreamRunLimits().maximumResponseBytes
  let text = String(repeating: "\0", count: maximum - 4) + "😀"
  #expect(text.utf8.count == maximum)
  _ = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { _ in try DreamCompletedResponse(text: text) }), reason: .invalidDecision)
  let response = try DreamRunEncoding.decode(
    DreamRunEncoding.BoundResponse.self, bytes: Data(contentsOf: fixture.payload("response.json")))
  #expect(response.text == text)
  let payloadSizes = try ["input.json", "context.json", "request.json", "response.json"].map {
    try Data(contentsOf: fixture.payload($0)).count
  }
  let exact = try #require(payloadSizes.max())
  _ = try transactionPending(
    fixture.store(limits: DreamRunLimits(maximumFrozenBytes: exact)).run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled),
    reason: .invalidDecision)
  let largestFrozen = try ["input.json", "context.json", "request.json"].map {
    try Data(contentsOf: fixture.payload($0)).count
  }.max()!
  #expect(throws: DreamRunError.limitExceeded) {
    try fixture.store(limits: DreamRunLimits(maximumFrozenBytes: largestFrozen - 1)).run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  let other = fixture.root.appendingPathComponent("oversized-response")
  #expect(throws: DreamRunError.limitExceeded) {
    try fixture.store(state: other).run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { _ in try DreamCompletedResponse(text: text + "x") })
  }
}

@Test func dreamRunInvalidBatchMutationsCannotAdmitOrCall() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let batch = try fixture.prepare(DreamProgress())
  let position = try #require(batch.positionsAfter.first)
  let backward = SourcePosition(
    relativePath: position.relativePath, sessionID: position.sessionID,
    completeBytes: position.completeBytes - 1, prefixHash: position.prefixHash,
    classificationHash: position.classificationHash)
  let record = try #require(batch.exactSourceRecords.last)
  let changed = ExactSourceRecord(
    witness: record.witness, bytes: Data("wrong\n".utf8), disposition: record.disposition)
  for kind in [
    "generation", "schema", "duplicatePositions", "backward", "record", "duplicateEvidence",
    "hiddenEvidence", "emptyRecords",
  ] {
    let invalid = PreparedSessionBatch(
      predecessorGeneration: kind == "generation" ? 1 : batch.predecessorGeneration,
      readerSchemaVersion: kind == "schema" ? 2 : batch.readerSchemaVersion,
      strippingInputHash: batch.strippingInputHash,
      positionsAfter: kind == "duplicatePositions"
        ? batch.positionsAfter + batch.positionsAfter
        : kind == "backward" ? [backward] : batch.positionsAfter,
      exactSourceRecords: kind == "emptyRecords"
        ? []
        : kind == "record"
          ? Array(batch.exactSourceRecords.dropLast()) + [changed] : batch.exactSourceRecords,
      evidence: kind == "duplicateEvidence"
        ? batch.evidence + batch.evidence
        : kind == "hiddenEvidence" || kind == "emptyRecords" ? [] : batch.evidence,
      selections: batch.selections, unfinishedTails: batch.unfinishedTails,
      isBacklog: batch.isBacklog,
      provenance: batch.provenance)
    let state = fixture.root.appendingPathComponent("invalid-\(kind)")
    #expect(throws: (any Error).self) {
      try fixture.store(state: state).run(
        selection: fixture.selection, prepare: { _ in invalid }, call: transactionUncalled)
    }
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: state.appendingPathComponent("admissions").path
      ).isEmpty)
  }
}

@Test func dreamRunHashBoundMalformedInputEncodingIsRejected() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let binding = SourceDigest(bytes: Data("roots".utf8))
  let runID = UUID().uuidString.lowercased()
  let original = try DreamRunEncoding.input(
    runID: runID,
    context: DreamRunContext(selection: fixture.selection, currentApprovedBase: fixture.main()),
    bindingHash: binding, progress: DreamProgress(), batch: fixture.prepare(DreamProgress()),
    limits: DreamRunLimits())
  for kind in [
    "runID", "binding", "base", "schema", "path", "kind", "date", "tag", "range", "noBytes",
    "skippedBytes", "spanAtZero",
  ] {
    var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
    switch kind {
    case "runID": object["runID"] = "../escape"
    case "binding": object["bindingHash"] = String(repeating: "0", count: 64)
    case "base": object["approvedBase"] = "MAIN"
    default:
      var batch = object["batch"] as! [String: Any]
      switch kind {
      case "schema": batch["readerSchemaVersion"] = 99
      case "path":
        var positions = batch["positionsAfter"] as! [[String: Any]]
        positions[0]["relativePath"] = "../escape"
        batch["positionsAfter"] = positions
      case "kind", "date":
        var evidence = batch["evidence"] as! [[String: Any]]
        if kind == "kind" {
          evidence[0]["kind"] = "picked"
        } else {
          evidence[0]["timestampBits"] = Double.infinity.bitPattern
        }
        batch["evidence"] = evidence
      default:
        var records = batch["exactSourceRecords"] as! [[String: Any]]
        if kind == "tag" {
          records[0]["tag"] = "future"
        } else if kind == "noBytes" {
          records[0]["bytes"] = nil
        } else if kind == "skippedBytes" {
          records[0]["tag"] = "skipped"
          records[0]["exclusion"] = nil
        } else if kind == "spanAtZero" {
          records[0]["tag"] = "skipped"
          records[0]["exclusion"] = nil
          records[0]["bytes"] = nil
        } else {
          var witness = records[0]["witness"] as! [String: Any]
          witness["lower"] = UInt64.max
          witness["upper"] = 0
          records[0]["witness"] = witness
        }
        batch["exactSourceRecords"] = records
      }
      object["batch"] = batch
    }
    let bytes = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    #expect(throws: (any Error).self) {
      try DreamRunEncoding.frozen(
        bytes: bytes, runID: runID, inputHash: SourceDigest(bytes: bytes), bindingHash: binding,
        limits: DreamRunLimits())
    }
  }
}

@Test func dreamRunOldFormatInputWithSkippedBytesStillValidatesAndReencodes() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.write(
    [
      dreamHeader("one", cwd: fixture.root.path, name: nil),
      dreamAssistant("a", nil, dreamOld, [dreamText("Agent context.")]),
      dreamUser("u", "a", dreamOld, "Use green buttons."),
    ].joined(separator: "\n") + "\n", file: fixture.source)
  let batch = try fixture.prepare(DreamProgress())
  #expect(batch.exactSourceRecords.map { $0.bytes == nil } == [false, true, false])
  let span = batch.exactSourceRecords[1]
  let source = try Data(contentsOf: fixture.source)
  let range =
    Int(span.witness.byteRange.lowerBound)..<Int(span.witness.byteRange.upperBound)
  let old = PreparedSessionBatch(
    predecessorGeneration: batch.predecessorGeneration,
    readerSchemaVersion: batch.readerSchemaVersion,
    strippingInputHash: batch.strippingInputHash, positionsAfter: batch.positionsAfter,
    exactSourceRecords: [
      batch.exactSourceRecords[0],
      ExactSourceRecord(
        witness: span.witness, bytes: Data(source[range]), disposition: .excluded(.assistantV1)),
      batch.exactSourceRecords[2],
    ], evidence: batch.evidence, selections: batch.selections,
    unfinishedTails: batch.unfinishedTails, isBacklog: batch.isBacklog,
    provenance: batch.provenance)
  try SessionReader.verifyPreparation(old)
  let binding = SourceDigest(bytes: Data("roots".utf8))
  let runID = UUID().uuidString.lowercased()
  let context = try DreamRunContext(
    selection: fixture.selection, currentApprovedBase: fixture.main())
  let input = try DreamRunEncoding.input(
    runID: runID, context: context, bindingHash: binding, progress: DreamProgress(), batch: old,
    limits: DreamRunLimits())
  let frozen = try DreamRunEncoding.frozen(
    bytes: input, runID: runID, inputHash: SourceDigest(bytes: input), bindingHash: binding,
    limits: DreamRunLimits())
  #expect(frozen.batch.exactSourceRecords.map(\.bytes) == old.exactSourceRecords.map(\.bytes))
  #expect(
    try DreamRunEncoding.input(
      runID: runID, context: context, bindingHash: binding, progress: DreamProgress(),
      batch: frozen.batch, limits: DreamRunLimits()) == input)
  try SessionReader.verifyPreparation(frozen.batch)
}

@Test func dreamRunMissingBoundResponseAfterDecisionsCannotAuthorizeRetry() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  store.persistenceFault = {
    if $0 == .afterDirectorySync("decisions.json") { throw POSIXError(.EIO) }
  }
  #expect(throws: DreamRunError.persistenceFailure) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes)
  }
  try FileManager.default.removeItem(at: fixture.payload("response.json"))
  #expect(throws: DreamRunError.missingPayload) {
    try fixture.store().run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
}

@Test(arguments: ["malformed", "unsupported", "unreadable"])
func dreamRunInvalidTimingDoesNotBlockRetryOrRecovery(kind: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  _ = try fixture.store().run(selection: fixture.selection,
    prepare: { try fixture.prepare($0) }, call: { _ in throw CancellationError() })
  let timing = fixture.state.appendingPathComponent("timing.json")
  let bytes = Data((kind == "unsupported" ? "{\"schemaVersion\":999}" : "malformed").utf8)
  try bytes.write(to: timing)
  if kind == "unreadable" { #expect(chmod(timing.path, 0) == 0) }
  let completed = try fixture.store().run(selection: fixture.selection,
    resume: .retryInterruptedCall, prepare: transactionUncalledPrepare, call: transactionNotes,
    observe: { _, _, _, estimate in #expect(estimate == nil) })
  guard case .completed = completed else { Issue.record("retry did not complete"); return }
  if kind == "unreadable" { #expect(chmod(timing.path, 0o600) == 0) }
  try bytes.write(to: timing)
  if kind == "unreadable" { #expect(chmod(timing.path, 0) == 0) }
  let recovered = try fixture.store().run(selection: fixture.selection,
    resume: .retryInterruptedCall, prepare: transactionUncalledPrepare, call: transactionUncalled,
    observe: { _, _, _, estimate in #expect(estimate == nil) })
  guard case .completed = recovered else { Issue.record("recovery did not complete"); return }
}

@Test func dreamRunTimingWriteFailureDoesNotHideCommittedSuccess() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  var isTimingWrite = false
  var failures = 0
  store.persistenceFault = { event in isTimingWrite = event == .beforeWrite("timing.json") }
  store.writeCall = { file, bytes, count in
    if isTimingWrite { failures += 1; errno = ENOSPC; return -1 }
    return Darwin.write(file, bytes, count)
  }
  let completed = try store.run(selection: fixture.selection,
    prepare: { try fixture.prepare($0) }, call: transactionNotes)
  #expect(failures == 1)
  guard case .completed = completed else { Issue.record("committed success was hidden"); return }
  let recovered = try fixture.store().run(selection: fixture.selection,
    resume: .retryInterruptedCall, prepare: transactionUncalledPrepare, call: transactionUncalled)
  guard case .completed = recovered else { Issue.record("commit was not durable"); return }
}
