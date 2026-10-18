import Foundation
import Testing

@testable import CoreMemories

@Test(arguments: [false, true])
func installerReplacementPreservesDreamGenerationAndReviewDecisions(isStable: Bool) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let state = fixture.root.appendingPathComponent(".local/state/pi-core-memories")
  let old = fixture.root.appendingPathComponent(
    ".cache/tool-sync/installs/old/home/.local/lib/agents-runtime/pi/extensions/prompt-snippets/snippets"
  )
  let current = fixture.root.appendingPathComponent(
    ".cache/tool-sync/installs/new/home/.local/lib/agents-resources/pi/extensions/prompt-snippets/snippets"
  )
  let logical = fixture.root.appendingPathComponent("extensions/prompt-snippets/snippets")
  try fixture.write(
    "---\nname: old\n---\n\nOld stripping body\n", file: old.appendingPathComponent("strip.md"))
  if isStable {
    try FileManager.default.createDirectory(
      at: logical.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: logical, withDestinationURL: old)
  }
  let first = try DreamRunStore(
    stateRoot: state, sessionsRoot: fixture.sessions, memoryRepository: fixture.memory,
    strippingRoots: [isStable ? logical : old])
  let completed = try transactionCompleted(
    first.run(
      selection: fixture.selection,
      prepare: {
        try SessionReader(sessions: fixture.sessions, snippets: old, environment: [:])
          .prepare(progress: $0, limits: DreamInputLimits())
      },
      call: { try transactionAdd($0) }))
  #expect(completed.generation == 1)
  let reviewState = fixture.root.appendingPathComponent("review")
  var review: MemoryReviewController? = try MemoryReviewController(
    repository: fixture.memory, stateRoot: reviewState, sources: first, environment: [:])
  let row = try #require(review!.list().first)
  try review!.deferCandidate(candidateID: row.change.id)
  review = nil
  let dreamBefore = try fixture.snapshot(state)
  let reviewBefore = try fixture.snapshot(reviewState)
  let memoryBefore = try fixture.snapshot(fixture.memory)
  try FileManager.default.removeItem(
    at: fixture.root.appendingPathComponent(".cache/tool-sync/installs/old"))
  try fixture.write(
    "---\nname: new\n---\n\nNew stripping body\n", file: current.appendingPathComponent("strip.md"))
  try FileManager.default.createDirectory(
    at: logical.deletingLastPathComponent(), withIntermediateDirectories: true)
  if isStable { try FileManager.default.removeItem(at: logical) }
  try FileManager.default.createSymbolicLink(at: logical, withDestinationURL: current)
  let reopened = try DreamRunStore(
    stateRoot: state, sessionsRoot: fixture.sessions, memoryRepository: fixture.memory,
    strippingRoots: [logical])
  #expect(reopened.acceptedSources.stripping.map(\.path) == [current.path])
  let result = try reopened.run(
    selection: fixture.selection,
    prepare: {
      try SessionReader(sessions: fixture.sessions, snippets: current, environment: [:])
        .prepare(progress: $0, limits: DreamInputLimits())
    }, call: transactionUncalled)
  guard case .noNewRecords(let generation, _) = result else {
    Issue.record("installer replacement must not replay consumed evidence")
    return
  }
  #expect(generation == 1)
  #expect(try fixture.snapshot(state) == dreamBefore)
  var configuration = MemoryConfiguration.defaults
  configuration.deviceKey = String(repeating: "d", count: 64)
  let configuredSources = try configuration.reviewSources(
    stateRoot: state, memoryRepository: fixture.memory)
  #expect(configuredSources.acceptedSources.stripping.map(\.path) == [current.path])
  let configuredReview = try MemoryReviewController(
    repository: fixture.memory, stateRoot: reviewState, sources: configuredSources, environment: [:])
  #expect(try configuredReview.list().first?.disposition == .deferred)
  #expect(try fixture.snapshot(reviewState) == reviewBefore)
  #expect(try fixture.snapshot(fixture.memory) == memoryBefore)
  try FileManager.default.removeItem(at: logical)
  try FileManager.default.createSymbolicLink(at: logical, withDestinationURL: fixture.snippets)
  #expect(throws: DreamRunError.unsafeState) {
    try DreamRunStore(
      stateRoot: state, sessionsRoot: fixture.sessions, memoryRepository: fixture.memory,
      strippingRoots: [logical])
  }
  #expect(throws: DreamRunError.unsafeState) {
    try configuration.reviewSources(stateRoot: state, memoryRepository: fixture.memory)
  }
  #expect(try fixture.snapshot(state) == dreamBefore)
  #expect(try fixture.snapshot(reviewState) == reviewBefore)
}
