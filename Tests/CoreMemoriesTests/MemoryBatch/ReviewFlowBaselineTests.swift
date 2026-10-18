import Foundation
import Testing

@testable import CoreMemories

private struct ReviewFlowTiming: Encodable {
  let repetition: Int
  let isWarmup: Bool
  var preparationMilliseconds = 0.0
  var previewMilliseconds = 0.0
  var publicationMilliseconds = 0.0
  var reloadMilliseconds = 0.0
  var workflowMilliseconds = 0.0
  var initialApprovedBytes = 0
  var approvedBytes = 0
  var completedApprovals = 0
  var explicitListCalls = 0
}

private func reviewFlowTimed<Value>(_ action: () throws -> Value) rethrows -> (Value, Double) {
  let start = DispatchTime.now().uptimeNanoseconds
  let value = try action()
  return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}

private func reviewFlowOutput(_ text: String) throws {
  try FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CORE_MEMORY_REVIEW_BASELINE"] == "1"))
func reviewFlowBaselinePreservesApprovedSiblingsSourcesAndCheckout() throws {
  for repetition in 0...5 {
    let fixture = try ReviewFlowFixture()
    defer { fixture.transaction.clean() }
    let preserved = try fixture.preservedFiles()
    var expectedEntries = fixture.retainedEntries
    var timing = ReviewFlowTiming(repetition: repetition, isWarmup: repetition == 0)
    let git = Git(repo: fixture.transaction.memory, environment: [:])
    timing.initialApprovedBytes = try git.data(["show", "refs/heads/main:MEMORY.md"]).count
    try reviewFlowOutput("REVIEW_FLOW_BEGIN \(repetition)")
    let workflowStart = DispatchTime.now().uptimeNanoseconds
    var finalDocument: Data?
    do {
      let ((controller, rows), preparation) = try reviewFlowTimed {
        let controller = try fixture.controller()
        return (controller, try controller.list())
      }
      timing.preparationMilliseconds = preparation
      timing.explicitListCalls += 1
      try #require(
        rows.filter { $0.disposition == .approved }.count == ReviewFlowFixture.retainedCount)
      let pending = rows.filter { $0.disposition == .pending }.sorted {
        $0.change.sources[0].witness.byteRange.lowerBound
          < $1.change.sources[0].witness.byteRange.lowerBound
      }
      try #require(pending.count == ReviewFlowFixture.pendingCount)
      for row in pending {
        let (preview, previewTime) = try reviewFlowTimed {
          try controller.preview(
            candidateID: row.change.id, clockDate: ReviewFlowFixture.reviewDate)
        }
        timing.previewMilliseconds += previewTime
        let (approval, publicationTime) = try reviewFlowTimed { try controller.apply(preview) }
        timing.publicationMilliseconds += publicationTime
        timing.completedApprovals += 1
        let ((firstReload, secondReload), reloadTime) = try reviewFlowTimed {
          (try controller.list(), try controller.list())
        }
        timing.reloadMilliseconds += reloadTime
        timing.explicitListCalls += 2
        try #require(approval.candidateID == row.change.id)
        try #require(
          firstReload.filter { $0.disposition == .approved }.count == expectedEntries.count + 1)
        try #require(secondReload.map(\.disposition) == firstReload.map(\.disposition))
        try #require(
          MemoryDocument.sourceAnnotations(in: preview.after)
            == MemoryDocument.sourceAnnotations(in: row.change.after))
        expectedEntries[preview.identity] = preview.after
        finalDocument = preview.replacement
      }
    }
    timing.workflowMilliseconds =
      Double(DispatchTime.now().uptimeNanoseconds - workflowStart) / 1_000_000
    let approved = try git.data(["show", "refs/heads/main:MEMORY.md"])
    timing.approvedBytes = approved.count
    try #require(approved == finalDocument)
    let entries = MemoryDocument.entries(in: approved).filter(\.isMutable)
    try #require(entries.count == ReviewFlowFixture.pendingCount + ReviewFlowFixture.retainedCount)
    try #require(Set(entries.compactMap(\.identity)).count == entries.count)
    for entry in entries {
      let identity = try #require(entry.identity)
      try #require(entry.bytes == expectedEntries[identity])
    }
    try #require(MemoryDocument.failures(in: approved).isEmpty)
    try #require(
      MemoryDocument.sourceAnnotations(in: approved).sorted()
        == fixture.candidates.flatMap { MemoryDocument.sourceAnnotations(in: $0.change.after) }
        .sorted())
    try #require(try fixture.preservedFiles() == preserved)
    let reopenedRows = try fixture.controller().list()
    try #require(reopenedRows.allSatisfy { $0.disposition == .approved })
    try #require(reopenedRows.map(\.change.id) == fixture.candidates.map(\.change.id))
    for (original, recovered) in zip(fixture.candidates, reopenedRows) {
      try #require(original.change.after == recovered.change.after)
      try #require(original.change.sources.map(\.id) == recovered.change.sources.map(\.id))
      try #require(
        original.change.sources.map(\.exactText) == recovered.change.sources.map(\.exactText))
      try #require(
        original.change.sources.map(\.witness) == recovered.change.sources.map(\.witness))
    }
    try #require(try fixture.preservedFiles() == preserved)
    try reviewFlowOutput(
      "REVIEW_FLOW_RESULT " + String(decoding: JSONEncoder().encode(timing), as: UTF8.self))
  }
}
