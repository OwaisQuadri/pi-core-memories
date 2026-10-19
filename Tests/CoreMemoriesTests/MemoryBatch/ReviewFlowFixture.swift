import Foundation

@testable import CoreMemories

struct ReviewFlowFixture {
  static let pendingCount = 8
  static let retainedCount = 4
  static let reviewDate = Date(timeIntervalSince1970: 1_783_036_799)

  let transaction: TransactionFixture
  let sources: DreamRunStore
  let reviewState: URL
  let configurationURL: URL
  let candidates: [MemoryReviewCandidate]
  let retainedEntries: [UUID: Data]

  init() throws {
    let fixture = try TransactionFixture()
    do {
      try fixture.populate(
        texts: (0..<(Self.pendingCount + Self.retainedCount)).map { "Synthetic preference \($0)." })
      let sources = try fixture.store()
      sources.clock = { Date(timeIntervalSince1970: 1_767_312_000) }
      _ = try transactionCompleted(
        sources.run(
          selection: fixture.selection, prepare: { try fixture.prepare($0) },
          call: { try transactionAdd($0) }))
      let state = fixture.root.appendingPathComponent("review")
      let configurationURL = fixture.root.appendingPathComponent("profile/config.json")
      let configuration = MemoryConfiguration(
        settings: MemoryAppSettings(
          piExecutable: "/usr/bin/false", agentDirectory: fixture.root.path,
          provider: "synthetic", modelID: "fixture", thinkingLevel: "off"),
        roots: DreamControlRoots(
          state: fixture.state.path, sessions: fixture.sessions.path, memory: fixture.memory.path,
          snippets: fixture.snippets.path, prompts: nil, globalAgents: nil),
        journal: fixture.root.appendingPathComponent("drafts").path,
        reviewState: state.path,
        diagnostics: fixture.root.appendingPathComponent("diagnostics").path)
      try configuration.save(to: configurationURL)
      let controller = try MemoryReviewController(
        repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
      let candidates = try controller.list()
      guard candidates.count == Self.pendingCount + Self.retainedCount,
        candidates.allSatisfy({ $0.disposition == .pending })
      else { throw MemoryError("review baseline requires twelve pending candidates") }
      try controller.confirmDetach(controller.checkoutPreview())
      var retained: [UUID: Data] = [:]
      let ordered = candidates.sorted {
        $0.change.sources[0].witness.byteRange.lowerBound
          < $1.change.sources[0].witness.byteRange.lowerBound
      }
      for row in ordered.prefix(Self.retainedCount) {
        let preview = try controller.preview(
          candidateID: row.change.id, clockDate: Self.reviewDate)
        _ = try controller.apply(preview)
        retained[preview.identity] = preview.after
      }
      self.transaction = fixture
      self.sources = sources
      self.reviewState = state
      self.configurationURL = configurationURL
      self.candidates = candidates
      self.retainedEntries = retained
    } catch {
      fixture.clean()
      throw error
    }
  }

  func controller() throws -> MemoryReviewController {
    try MemoryReviewController(
      repository: transaction.memory, stateRoot: reviewState, sources: sources, environment: [:])
  }

  func preservedFiles() throws -> [String: TransactionFileState] {
    var files = try transaction.snapshot(transaction.sessions)
      .merging(transaction.snapshot(transaction.snippets)) { _, new in new }
      .merging(transaction.snapshot(transaction.state)) { _, new in new }
      .merging(transaction.snapshot(configurationURL.deletingLastPathComponent())) { _, new in new }
    for path in ["MEMORY.md", ".git/HEAD", ".git/index", ".git/config"] {
      let url = transaction.memory.appendingPathComponent(path)
      files[url.path] = TransactionFileState(
        bytes: try Data(contentsOf: url),
        modified: try url.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate)
    }
    return files
  }
}
