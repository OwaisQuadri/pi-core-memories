import Darwin
import Foundation
import Testing

@testable import CoreMemories

private func transactionMutate(_ file: URL, _ change: (inout [String: Any]) -> Void) throws {
  var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
  change(&value)
  try JSONSerialization.data(
    withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]
  ).write(to: file)
}

@Test func dreamRunRetryRefusesAnotherSelectionAndRetriesTheRecordedOneWithFrozenPayloads() throws {
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
    #expect(saved.systemPrompt.contains(DreamDecisionContext.stuckDetectionGuidance))
    try transactionMutate(fixture.payload("call-started.json")) { $0.removeValue(forKey: "selection") }
    let before = try fixture.snapshot(fixture.state)
    let protected = try fixture.protectedState()
    let refused = try transactionPending(
      fixture.store().run(
        selection: selection, resume: .retryInterruptedCall, prepare: transactionUncalledPrepare,
        call: transactionUncalled),
      reason: .interruptedCall)
    #expect(refused.callSelection == fixture.selection)
    #expect(try fixture.snapshot(fixture.state) == before)
    let report = try transactionCompleted(
      fixture.store().run(
        selection: fixture.selection, resume: .retryInterruptedCall,
        prepare: transactionUncalledPrepare,
        call: { request in
          #expect(request.selection == fixture.selection)
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
    #expect(try response.selection.domain() == fixture.selection)
    #expect(try transactionCompleted(fixture.store().run(
      selection: selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare, call: transactionUncalled)).runID == report.runID)
  }
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
