import Darwin
import Foundation
import Testing

@testable import CoreMemories

private struct PromptRelocationFixture {
  let transaction: TransactionFixture
  let prompts: URL
  let replacement: URL
  let roles: DreamSourceRoles
  let baselineRunID: String

  init(
    isSnippetsPresent: Bool = true, isCompleted: Bool = true,
    definitionBody: String = dreamPrompt, promptsName: String = "arbitrary-old-definitions"
  ) throws {
    let fixture = try TransactionFixture()
    transaction = fixture
    prompts = fixture.root.appendingPathComponent(promptsName)
    replacement = fixture.root.appendingPathComponent("replacement-definitions")
    roles = DreamSourceRoles(isSnippetsPresent: isSnippetsPresent, isPromptsPresent: true)
    let definition = "---\ndescription: Synthetic review\n---\n\n" + definitionBody + "\n"
    for folder in [prompts, replacement] {
      try fixture.write(definition, file: folder.appendingPathComponent("review.md"))
    }
    try fixture.populate()
    let store = try DreamRunStore(
      stateRoot: fixture.state, sessionsRoot: fixture.sessions,
      memoryRepository: fixture.memory,
      strippingRoots: (isSnippetsPresent ? [fixture.snippets] : []) + [prompts])
    let result = try store.run(
      selection: fixture.selection, sourceRoles: roles, protect: { _ in },
      prepare: { progress, sources in
        try SessionReader(
          sessions: sources.sessions, snippets: sources.snippets,
          prompts: sources.prompts, environment: [:]
        ).prepare(progress: progress, limits: DreamInputLimits())
      },
      call: { request in
        if !isCompleted { throw CancellationError() }
        return try transactionAdd(request)
      })
    switch result {
    case .completed(let report): baselineRunID = report.runID
    case .pending(let report): baselineRunID = report.runID
    default: throw MemoryError("expected captured relocation baseline")
    }
    try FileManager.default.removeItem(at: prompts)
  }

  func store() throws -> DreamRunStore {
    try DreamRunStore(
      stateRoot: transaction.state, sessionsRoot: transaction.sessions,
      memoryRepository: transaction.memory,
      strippingRoots: (roles.isSnippetsPresent ? [transaction.snippets] : []) + [prompts])
  }

  func preview(_ store: DreamRunStore? = nil) throws -> PromptRelocationPreview {
    try (store ?? self.store()).previewPromptRelocation(
      baselineRunID: baselineRunID,
      replacement: replacement, sourceRoles: roles)
  }

  func confirm(_ preview: PromptRelocationPreview, store: DreamRunStore? = nil) throws {
    _ = try (store ?? self.store()).confirmPromptRelocation(
      baselineRunID: baselineRunID,
      replacement: replacement, sourceRoles: roles,
      expectedPreviewHash: #require(preview.previewHash), authorization: .explicitCaller)
  }

  func run(
    _ store: DreamRunStore? = nil,
    call: (DreamModelRequest) throws -> DreamCompletedResponse = transactionNotes
  ) throws -> DreamTransactionResult {
    try (store ?? self.store()).run(
      selection: transaction.selection, sourceRoles: roles, protect: { _ in },
      prepare: { progress, sources in
        try SessionReader(
          sessions: sources.sessions, snippets: sources.snippets,
          prompts: sources.prompts, environment: [:]
        ).prepare(progress: progress, limits: DreamInputLimits())
      }, call: call)
  }

  var configuration: MemoryConfiguration {
    var config = queueConfiguration(transaction)
    config.roots?.snippets = roles.isSnippetsPresent ? transaction.snippets.path : nil
    config.roots?.prompts = prompts.path
    return config
  }

  var recordURL: URL { transaction.state.appendingPathComponent("prompt-relocation.json") }
}

struct PromptSourceRelocationTests {
  @Test func missingMigratedSnippetsBlockFreshIntakeDespiteApprovedPromptRelocation() throws {
    let relocation = try PromptRelocationFixture()
    let fixture = relocation.transaction
    defer { fixture.clean() }
    try relocation.confirm(relocation.preview())
    let replacement = fixture.root.appendingPathComponent("replacement-snippets")
    try FileManager.default.copyItem(at: fixture.snippets, to: replacement)
    try FileManager.default.removeItem(at: fixture.snippets)
    #expect(throws: (any Error).self) { try relocation.run() }
    let store = try relocation.store()
    let before = try fixture.snapshot(fixture.root)
    let preview = try store.previewPromptRelocation(
      baselineRunID: relocation.baselineRunID, replacement: replacement,
      sourceRoles: relocation.roles, role: .snippets)
    #expect(preview.isCompatible)
    #expect(try fixture.snapshot(fixture.root) == before)
    _ = try store.confirmPromptRelocation(
      baselineRunID: relocation.baselineRunID, replacement: replacement,
      sourceRoles: relocation.roles, expectedPreviewHash: #require(preview.previewHash),
      authorization: .explicitCaller, role: .snippets)
    var after = try fixture.snapshot(fixture.root)
    #expect(after.removeValue(forKey: fixture.state.appendingPathComponent("snippet-relocation.json").path) != nil)
    #expect(after == before)
    guard case .noNewRecords = try relocation.run() else {
      throw MemoryError("expected fresh intake through approved relocated sources")
    }
  }

  @Test(arguments: [false, true])
  func previewAndConfirmationPreserveHistoricalReviewAndManualAuthority(isSnippetsPresent: Bool)
    throws
  {
    let relocation = try PromptRelocationFixture(isSnippetsPresent: isSnippetsPresent)
    let fixture = relocation.transaction
    defer { fixture.clean() }
    let store = try relocation.store()
    let binding = try store.reviewSourceBinding()
    let review = try MemoryReviewController(
      repository: fixture.memory,
      stateRoot: URL(fileURLWithPath: relocation.configuration.reviewState), sources: store,
      environment: [:])
    let candidate = try #require(review.list().first)
    try review.deferCandidate(candidateID: candidate.change.id)
    let deferred = try #require(review.list().first)
    #expect(deferred.change.id == candidate.change.id && deferred.disposition == .deferred)
    #expect(try review.selection(candidate.change.id.rawValue) == .deferred)
    let drafts = try MemoryDraftStore(
      repository: fixture.memory,
      journal: URL(fileURLWithPath: relocation.configuration.journal))
    let main = try fixture.main()
    let draft = try drafts.create(
      base: main,
      operations: [
        MemoryManagementRequest(
          operation: .add, base: main, path: "MEMORY.md", replacement: fact("Keep manual intent."),
          reason: "Synthetic intent")
      ])
    let git = Git(repo: fixture.memory, environment: [:])
    let refs = try git.data(["for-each-ref", "--format=%(refname) %(objectname)"])
    let history = try DreamRunEncoding.encode(DreamInspection.read(stateRoot: fixture.state))
    let before = try fixture.snapshot(fixture.root)
    let preview = try relocation.preview(store)
    #expect(preview.isCompatible && preview.mismatches.isEmpty)
    #expect(preview.baseline.runID == relocation.baselineRunID)
    #expect(preview.baselineInventory.entryCount == 1)
    #expect(preview.baselineInventory == preview.replacementInventory)
    #expect(preview.roles == relocation.roles)
    #expect(preview.coverage.isCompleted && !preview.coverage.isNewerCompletedCapturePresent)
    #expect(try fixture.snapshot(fixture.root) == before)
    try fixture.advance()
    let advancedMain = try fixture.main()
    let advancedRefs = try git.data(["for-each-ref", "--format=%(refname) %(objectname)"])
    #expect(advancedMain != main && advancedRefs != refs)
    let blockedBeforeConfirmation = try #require(review.list().first)
    #expect(blockedBeforeConfirmation.change.id == candidate.change.id)
    #expect(blockedBeforeConfirmation.disposition == .blocked)
    #expect(
      blockedBeforeConfirmation.limitation
        == "main contains changes outside verified memory publications")
    #expect(try review.selection(candidate.change.id.rawValue) == .deferred)
    let confirmationBefore = try fixture.snapshot(fixture.root)
    try relocation.confirm(preview, store: store)
    var after = try fixture.snapshot(fixture.root)
    let installedRecord = after.removeValue(forKey: relocation.recordURL.path)
    let record = try #require(installedRecord)
    #expect(after == confirmationBefore)
    #expect(record.bytes.count <= 1_048_576)
    var metadata = stat()
    #expect(lstat(relocation.recordURL.path, &metadata) == 0)
    #expect(
      metadata.st_mode & 0o7777 == 0o600 && metadata.st_nlink == 1 && metadata.st_uid == geteuid())
    #expect(try store.reviewSourceBinding() == binding)
    #expect(try relocation.store().reviewSourceBinding() == binding)
    #expect(store.acceptedSources.stripping.last == relocation.prompts)
    #expect(try fixture.main() == advancedMain)
    #expect(try git.data(["for-each-ref", "--format=%(refname) %(objectname)"]) == advancedRefs)
    #expect(try DreamRunEncoding.encode(DreamInspection.read(stateRoot: fixture.state)) == history)
    let blockedAfterConfirmation = try #require(review.list().first)
    #expect(blockedAfterConfirmation.change.id == candidate.change.id)
    #expect(blockedAfterConfirmation.disposition == blockedBeforeConfirmation.disposition)
    #expect(blockedAfterConfirmation.limitation == blockedBeforeConfirmation.limitation)
    #expect(
      blockedAfterConfirmation.frozenLimitations == blockedBeforeConfirmation.frozenLimitations)
    #expect(try review.selection(candidate.change.id.rawValue) == .deferred)
    #expect(try drafts.read(draft.draftID, revision: draft.revision).operations.count == 1)
    guard case .noNewRecords(let generation, _) = try relocation.run() else {
      throw MemoryError("durable mapping did not resolve fresh preparation")
    }
    #expect(generation == 1)
    #expect(
      DreamQueueSnapshot.read(configuration: relocation.configuration).coverage?.segments != nil)
    #expect(throws: (any Error).self) { try relocation.confirm(preview) }
    #expect(throws: (any Error).self) {
      try relocation.store().run(
        selection: fixture.selection,
        prepare: transactionUncalledPrepare, call: transactionUncalled)
    }
  }
}
