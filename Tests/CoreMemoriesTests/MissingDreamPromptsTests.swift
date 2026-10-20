import Darwin
import Foundation
import Testing

@testable import CoreMemories

struct MissingDreamPromptsTests {
  @Test(arguments: [false, true])
  func registeredPromptsDisappearanceBlocksPreparationWithoutChangingSavedWork(
    isRemovingPrompts: Bool
  ) throws {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    try fixture.populate()
    let prompts = fixture.root.appendingPathComponent("prompts")
    try fixture.write(dreamPrompt + "\n", file: prompts.appendingPathComponent("review.md"))
    func store() throws -> DreamRunStore {
      try DreamRunStore(
        stateRoot: fixture.state, sessionsRoot: fixture.sessions,
        memoryRepository: fixture.memory, strippingRoots: [fixture.snippets, prompts])
    }
    func prepare(_ progress: DreamProgress) throws -> PreparedSessionBatch {
      try SessionReader(
        sessions: fixture.sessions, snippets: fixture.snippets, prompts: prompts, environment: [:]
      ).prepare(progress: progress, limits: DreamInputLimits())
    }
    var modelCalls = 0
    let sources = try store()
    let completed = try transactionCompleted(
      sources.run(
        selection: fixture.selection, prepare: prepare,
        call: {
          modelCalls += 1
          return try transactionAdd($0)
        }))
    #expect(modelCalls == 1 && completed.generation == 1 && completed.proposals.count == 1)
    var configuration = queueConfiguration(fixture)
    configuration.roots?.prompts = prompts.path
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: URL(fileURLWithPath: configuration.reviewState),
      sources: sources, environment: [:])
    let candidate = try #require(review.list().first)
    try review.deferCandidate(candidateID: candidate.change.id)
    let drafts = try MemoryDraftStore(
      repository: fixture.memory, journal: URL(fileURLWithPath: configuration.journal))
    let main = try fixture.main()
    let draft = try drafts.create(
      base: main,
      operations: [
        MemoryManagementRequest(
          operation: .add, base: main, path: "MEMORY.md",
          replacement: fact("Retain this manual draft."), reason: "Synthetic manual intent")
      ])
    let git = Git(repo: fixture.memory, environment: [:])
    let refs = try git.data(["for-each-ref", "--format=%(refname) %(objectname)"])
    let history = try DreamInspection.read(stateRoot: fixture.state)
    let saved = try #require(history.runs.first)
    #expect(!history.isBusy && saved.isCompleted && saved.diagnostic == nil)
    #expect(saved.attempts.first?.status == "Reply valid")
    let input = try #require(saved.artifacts.first { $0.name == "input.json" })
    let reply = try #require(saved.artifacts.first { $0.name == "response.json" })
    let inputBytes = try DreamInspection.artifactBytes(input, stateRoot: fixture.state)
    let replyBytes = try DreamInspection.artifactBytes(reply, stateRoot: fixture.state)
    let binding = try Data(contentsOf: fixture.state.appendingPathComponent("root.json"))
    let bound = try #require(try JSONSerialization.jsonObject(with: binding) as? [String: Any])
    #expect(bound["stripping"] as? [String] == [fixture.snippets.path, prompts.path])
    var identity = stat()
    #expect(lstat(fixture.state.path, &identity) == 0 && identity.st_mode & 0o7777 == 0o700)
    #expect(
      lstat(fixture.state.appendingPathComponent("root.json").path, &identity) == 0
        && identity.st_mode & 0o7777 == 0o600)
    if isRemovingPrompts {
      try FileManager.default.removeItem(at: prompts)
      let resolved = realpath(prompts.path, nil)
      #expect(resolved == nil && errno == ENOENT)
      if let resolved { free(resolved) }
    }
    let before = try fixture.snapshot(fixture.root)
    #expect(before.keys.contains { $0.hasSuffix("/state.json") })
    #expect(before.keys.contains { $0.hasPrefix(configuration.reviewState + "/") })
    #expect(before.keys.contains { $0.hasPrefix(configuration.journal + "/") })
    let reopened = try store()
    #expect(reopened.acceptedSources.stripping.map(\.path) == [fixture.snippets.path, prompts.path])
    var prepareCalls = 0
    modelCalls = 0
    func run() throws -> DreamTransactionResult {
      try reopened.run(
        selection: fixture.selection,
        prepare: {
          prepareCalls += 1
          return try prepare($0)
        },
        call: {
          modelCalls += 1
          return try transactionNotes($0)
        })
    }
    if isRemovingPrompts {
      #expect(throws: DreamRunError.unsafeState) { try run() }
      #expect(prepareCalls == 0 && modelCalls == 0)
    } else {
      guard case .noNewRecords(let generation, _) = try run() else {
        throw MemoryError("healthy registered prompts must allow preparation")
      }
      #expect(generation == 1 && prepareCalls == 1 && modelCalls == 0)
    }
    #expect(try fixture.snapshot(fixture.root) == before)
    let worker = try DreamWorkerProcess()
    defer { worker.clean() }
    try worker.send([
      "version": 1, "type": "start", "invocationID": "synthetic-missing-prompts",
      "roots": [
        "state": fixture.state.path, "sessions": fixture.sessions.path,
        "memory": fixture.memory.path, "snippets": fixture.snippets.path,
        "prompts": prompts.path, "globalAgents": NSNull(),
      ],
      "selection": [
        "provider": fixture.selection.provider, "modelID": fixture.selection.modelID,
        "thinkingLevel": fixture.selection.thinkingLevel,
      ],
      "resume": "inspectOrContinue", "batchTextBytes": 262_144,
    ])
    let final = try worker.frame()
    #expect(final["type"] as? String == "final")
    if isRemovingPrompts {
      #expect(final["status"] as? String == "blocked")
      #expect(final["reason"] as? String == "workerFailure")
      #expect(final["detail"] as? String == "unsafe dream state")
      #expect(final["runID"] is NSNull)
      #expect(worker.progressFrames.isEmpty)
      let status = try #require(DreamInvocationStatus(report: final))
      #expect(status.title == "Blocked")
      #expect(status.explanation == "The worker stopped before finishing.")
      #expect(!status.isPublicationBlocked)
    } else {
      #expect(final["status"] as? String == "noNewRecords")
      #expect(final["generation"] as? String == "1")
      #expect(!worker.progressFrames.isEmpty)
    }
    try worker.finish()
    let queue = DreamQueueSnapshot.read(configuration: configuration)
    if isRemovingPrompts {
      #expect(queue.coverage == nil)
      #expect(queue.unavailableReason == "Queue unavailable: no prompt templates in --prompts")
    } else {
      #expect(queue.unavailableReason == nil)
      #expect(queue.coverage?.segments != nil)
    }
    #expect(try fixture.main() == main)
    #expect(try git.data(["for-each-ref", "--format=%(refname) %(objectname)"]) == refs)
    #expect(try Data(contentsOf: fixture.state.appendingPathComponent("root.json")) == binding)
    #expect(try DreamRunEncoding.encode(DreamInspection.read(stateRoot: fixture.state))
      == DreamRunEncoding.encode(history))
    #expect(try DreamInspection.artifactBytes(input, stateRoot: fixture.state) == inputBytes)
    #expect(try DreamInspection.artifactBytes(reply, stateRoot: fixture.state) == replyBytes)
    #expect(try review.list().first?.disposition == .deferred)
    #expect(try drafts.read(draft.draftID, revision: draft.revision).operations.count == 1)
    #expect(try fixture.snapshot(fixture.root) == before)
    print("registered prompts present=\(!isRemovingPrompts), prepare=\(prepareCalls), model=\(modelCalls)")
    print("worker final: \(dreamJSON(final))")
    print("queue: \(queue.unavailableReason ?? "available")")
    print("protected files unchanged=\(before.count); main, all refs, binding, history, input/reply, review, draft unchanged")
  }

  @Test(arguments: ["metadataPermissions", "mismatchedRoots"])
  func unsafeMetadataAndChangedRootsFailBeforePreparation(variant: String) throws {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    _ = try fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionUncalled)
    let root = fixture.state.appendingPathComponent("root.json")
    let other = fixture.root.appendingPathComponent("other-sessions")
    if variant == "metadataPermissions" {
      #expect(chmod(root.path, 0o644) == 0)
    } else {
      try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    }
    let before = try fixture.snapshot(fixture.root)
    #expect(throws: DreamRunError.unsafeState) {
      try DreamRunStore(
        stateRoot: fixture.state,
        sessionsRoot: variant == "mismatchedRoots" ? other : fixture.sessions,
        memoryRepository: fixture.memory, strippingRoots: [fixture.snippets])
    }
    #expect(try fixture.snapshot(fixture.root) == before)
    print("\(variant): constructor rejected unsafe dream state; protected files unchanged=\(before.count)")
  }
}
