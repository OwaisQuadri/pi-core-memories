import Darwin
import Foundation
import Testing

@testable import CoreMemories

@Test func deviceRenderAndAtomicDraftNeverIncludeAnotherDevice() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let device = String(repeating: "a", count: 64)
  let other = String(repeating: "b", count: 64)
  let project = try #require(try MemoryStore.projectKey(cwd: fixture.memory))
  let paths = [
    "MEMORY.md", "projects/\(project).md", "devices/\(device)/MEMORY.md",
    "devices/\(device)/projects/\(project).md", "devices/\(other)/MEMORY.md",
  ]
  for (index, path) in paths.enumerated() {
    try fixture.write(
      "# Memory\n\n" + fact("Scope \(index)."), file: fixture.memory.appendingPathComponent(path))
  }
  let git = Git(repo: fixture.memory, environment: [:])
  _ = try git.text(["add", "."])
  _ = try git.text(["commit", "-m", "Synthetic scopes"], additions: Git.proposalIdentity)
  let store = try MemoryStore(repo: fixture.memory)
  let rendered = try store.render(cwd: fixture.memory, deviceKey: device)
  let positions = try (0..<4).map { index in
    try #require(rendered.range(of: "Scope \(index).")).lowerBound
  }
  #expect(positions == positions.sorted())
  #expect(!rendered.contains("Scope 4."))
  #expect(!(try store.render(cwd: fixture.memory)).contains("Scope 2."))
  let manager = try MemoryManagement(repository: fixture.memory)
  try manager.confirmDetach(manager.checkoutPreview())
  let catalog = try manager.execute(MemoryManagementRequest(operation: .list))
  let drafts = try MemoryDraftStore(
    repository: fixture.memory, journal: fixture.root.appendingPathComponent("drafts"))
  var draft = try drafts.create()
  draft = try drafts.update(
    draftID: draft.draftID, expectedRevision: 0,
    operations: catalog.entries.filter(\.isMutable).map { row in
      MemoryManagementRequest(
        operation: .update, base: catalog.base, path: row.path, locator: row.locator,
        expected: row.expected, replacement: fact("Changed \(row.path)."),
        reason: "Explicit scoped correction")
    })
  let receipt = try drafts.save(
    draftID: draft.draftID, expectedRevision: draft.revision, idempotencyKey: "save")
  #expect(try git.text(["rev-parse", receipt.commit + "^"]) == catalog.base)
  #expect(try store.check().isEmpty)
}

@Test func deviceDreamPinsNewScopeAndReplaysOldPendingContextWithoutRehashing() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let old = try fixture.store()
  var originalHash: SourceDigest?
  _ = try old.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { request in
      originalHash = request.contextHash
      throw CancellationError()
    })
  let device = String(repeating: "a", count: 64)
  let configured = try DreamRunStore(
    stateRoot: fixture.state, sessionsRoot: fixture.sessions,
    memoryRepository: fixture.memory, strippingRoots: [fixture.snippets], deviceKey: device)
  _ = try configured.run(
    selection: fixture.selection, resume: .retryInterruptedCall,
    prepare: transactionUncalledPrepare,
    call: { request in
      #expect(request.contextHash == originalHash)
      return try transactionAdd(request)
    })
  try fixture.populate(texts: ["Use green buttons, not blue.", "This device uses local fixtures."])
  _ = try configured.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { request in
      let context = try transactionObject(request)
      let primary = context["primaryEvidence"] as! [[String: Any]]
      return try transactionResponse(
        request,
        decisions: primary.map { evidence in
          [
            "kind": "add", "scope": ["kind": "device", "deviceKey": device],
            "text": "This device uses local fixtures.", "sources": [evidence["source"]!],
            "contradictions": [], "reason": "Explicit device-local setup",
          ]
        })
    })
  let inspection = try DreamInspection.read(stateRoot: fixture.state)
  #expect(inspection.runs.count == 2)
  #expect(inspection.runs.allSatisfy { $0.isCompleted })
  #expect(inspection.runs.flatMap(\.artifacts).contains { $0.name == "call-started.json" })
}

@Test func explicitProjectBindingsMatchSharedKeyWithoutChangingLocalIdentity() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let original = try #require(try MemoryStore.projectKey(cwd: fixture.repo))
  let common = try #require(try MemoryStore.projectBindingDirectory(cwd: fixture.repo))
  let shared = String(repeating: "c", count: 64)
  #expect(
    try MemoryStore.projectKey(cwd: fixture.repo, projectBindings: [common: shared]) == shared)
  #expect(try MemoryStore.projectKey(cwd: fixture.repo) == original)
}

@Test(arguments: [1, 64])
func deviceSnapshotCountsProjectKeysInsteadOfScopeDocuments(projectCount: Int) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let keys = (0..<projectCount).map { String(format: "%064x", $0) }
  let limits = try DreamDecisionLimits(maximumProjectKeys: projectCount)
  let base = try fixture.store.approvedCommit()
  let snapshot = try fixture.store.decisionSnapshot(
    base: base, projectKeys: keys,
    limits: limits, deviceKey: String(repeating: "d", count: 64))
  #expect(snapshot.documents.count == 2 + 2 * projectCount)
  #expect(throws: DreamDecisionError.limitExceeded) {
    try fixture.store.decisionSnapshot(
      base: base,
      projectKeys: keys + [String(format: "%064x", projectCount)], limits: limits,
      deviceKey: String(repeating: "d", count: 64))
  }
}

@Test func deviceReviewCatalogCommandUsesCurrentDeviceAndBoundProject() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let project = try fixture.project("project")
  let common = try #require(try MemoryStore.projectBindingDirectory(cwd: project))
  let original = try #require(try MemoryStore.projectKey(cwd: project))
  let shared = String(repeating: "c", count: 64)
  let device = String(repeating: "d", count: 64)
  let selected = [
    "MEMORY.md", "projects/\(shared).md", "devices/\(device)/MEMORY.md",
    "devices/\(device)/projects/\(shared).md",
  ]
  for path in selected + [
    "projects/\(original).md", "devices/\(String(repeating: "e", count: 64))/MEMORY.md",
  ] {
    try fixture.write("# Memory\n\n" + fact("Scope \(path)."), path: path)
  }
  try fixture.commit()
  let resolved = try #require(realpath(fixture.root.path, nil))
  defer { free(resolved) }
  let configURL = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(
    "profile/config.json")
  var config = MemoryConfiguration.defaults
  config.settings.piExecutable = "/usr/bin/false"
  config.deviceKey = device
  config.projectBindings = [common: shared]
  try config.save(to: configURL)
  let result = try fixture.cli([
    "review-catalog", "--repo", fixture.repo.path,
    "--cwd", project.path, "--config", configURL.path,
  ])
  #expect(result.status == 0)
  struct Envelope: Decodable { let catalog: MemoryManagementResult }
  let catalog = try JSONDecoder().decode(Envelope.self, from: result.output).catalog
  #expect(Set(catalog.entries.map(\.path)) == Set(selected))
}
