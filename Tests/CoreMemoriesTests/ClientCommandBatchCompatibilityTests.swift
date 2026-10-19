import Foundation
import Testing

@testable import CoreMemories

@Test func clientDraftCommandsCannotOverwriteOrPublishCandidateBatchIntent() throws {
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let drafts = try MemoryDraftStore(
    repository: fixture.transaction.memory,
    journal: memoryBatchTestJournal(fixture.transaction.root))
  let controller = try fixture.controller()
  let session = try MemoryBatchSession(
    repository: fixture.transaction.memory, drafts: drafts, review: controller,
    date: ReviewFlowFixture.reviewDate)
  let candidate = try #require(session.projection.candidates.first { $0.disposition == .pending })
  try session.stage(session.presentAcceptance(candidateID: candidate.change.id))
  _ = try session.stageManual(
    MemoryManagementRequest(
      operation: .add, base: session.projection.draft.baseCommit, path: "MEMORY.md",
      replacement: fact("Explicit manual addition."), reason: "Requested addition"))
  try session.acknowledgePersistence(drafts.persistBatch(session.persistenceRequest))
  let draft = session.projection.draft
  let before = try fixture.transaction.snapshot(drafts.journal)
  let main = try fixture.transaction.main()
  let binary = try #require(ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_BIN"])
  for operation in ["update", "save"] {
    let result = try runCommand(
      executable: URL(fileURLWithPath: binary),
      arguments: [
        "draft", operation, "--config", fixture.configurationURL.path,
        "--id", draft.draftID.uuidString, "--revision", String(draft.revision),
      ] + (operation == "save" ? ["--key", "not-an-approval"] : []),
      environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.transaction.root.path],
      input: Data("[]".utf8))
    #expect(result.status != 0)
    #expect(try fixture.transaction.snapshot(drafts.journal) == before)
    #expect(try fixture.transaction.main() == main)
  }
  #expect(try memoryBatchDigest(drafts.list(review: controller).last) == memoryBatchDigest(draft))
}

@Test func clientDraftCommandsRetainCRUDSaveAndIdempotentReceipt() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try MemoryManagement(repository: fixture.repo).confirmDetach(
    MemoryManagement(repository: fixture.repo).checkoutPreview())
  var configuration = MemoryConfiguration.defaults
  configuration.roots = DreamControlRoots(
    state: fixture.root.appendingPathComponent("state").path,
    sessions: fixture.root.appendingPathComponent("sessions").path, memory: fixture.repo.path,
    snippets: nil, prompts: nil, globalAgents: nil)
  configuration.journal = try memoryBatchTestJournal(fixture.root).path
  let root = URL(fileURLWithPath: configuration.journal).deletingLastPathComponent()
  configuration.reviewState = root.appendingPathComponent("review").path
  configuration.diagnostics = root.appendingPathComponent("diagnostics").path
  let configURL = root.appendingPathComponent("profile/config.json")
  try configuration.save(to: configURL)
  func command(_ arguments: [String], input: Data = Data()) throws -> CommandResult {
    try fixture.cli(
      ["draft"] + arguments + ["--config", configURL.path], input: input,
      environment: ["HOME": fixture.root.path])
  }
  let created = try command(["create"])
  try #require(created.status == 0)
  let draft = try JSONDecoder().decode(MemoryDraft.self, from: created.output)
  let request = MemoryManagementRequest(
    operation: .add, base: draft.baseCommit, path: "MEMORY.md",
    replacement: fact("CLI draft addition."), reason: "Requested addition")
  let updated = try command(
    ["update", "--id", draft.draftID.uuidString, "--revision", "0"],
    input: JSONEncoder().encode([request]))
  try #require(updated.status == 0)
  let revision = try JSONDecoder().decode(MemoryDraft.self, from: updated.output).revision
  let arguments = [
    "save", "--id", draft.draftID.uuidString, "--revision", String(revision), "--key", "save",
  ]
  let saved = try command(arguments)
  try #require(saved.status == 0)
  let main = try fixture.store.approvedCommit()
  let replayed = try command(arguments)
  #expect(replayed.status == 0)
  #expect(saved.output == replayed.output)
  #expect(try fixture.store.approvedCommit() == main)
  #expect(try fixture.git(["rev-list", "--count", draft.baseCommit + ".." + main]) == "1")
}
