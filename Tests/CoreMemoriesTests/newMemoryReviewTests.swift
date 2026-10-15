import Darwin
import Foundation
import Testing

@testable import CoreMemories

@Test func reviewPreviewDoesNotApproveAndRejectDeferSurviveRestart() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Keep A.", "Keep B.", "Keep C."])
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let state = fixture.root.appendingPathComponent("review")
  var controller: MemoryReviewController? = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  let rows = try controller!.list()
  #expect(rows.count == 3)
  let original = try fixture.snapshot(fixture.memory)
  let date = Date(timeIntervalSince1970: 1_783_036_799)
  let preview = try controller!.preview(candidateID: rows[0].change.id, clockDate: date)
  #expect(preview.after != rows[0].change.after)
  #expect(preview.change.sources[0].exactText == rows[0].change.sources[0].exactText)
  #expect(MemoryDocument.entries(in: preview.replacement).filter { $0.identity != nil }.count == 1)
  #expect(try fixture.snapshot(fixture.memory) == original)
  try controller!.reject(candidateID: rows[1].change.id)
  try controller!.deferCandidate(candidateID: rows[2].change.id)
  controller = nil
  let reopened = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  let dispositions = try reopened.list().map(\.disposition)
  #expect(dispositions == [.pending, .rejected, .deferred])
  #expect(try fixture.snapshot(fixture.memory) == original)
  let deferredPreview = try reopened.preview(candidateID: rows[2].change.id, clockDate: date)
  #expect(deferredPreview.change.id == rows[2].change.id)
  #expect(throws: (any Error).self) {
    try reopened.preview(candidateID: rows[1].change.id, clockDate: date)
  }
}

@Test func reviewLegacySiblingOffsetsDoNotSearchDuplicateUnicodeProse() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let paragraph = "Keep café 🐟. [source: pi:one#old/part/0; added: 2026-01-01]\r\n"
  let original = "# Memory\r\n\r\n" + paragraph + "\r\n" + paragraph
  try fixture.write(original, file: fixture.memory.appendingPathComponent("MEMORY.md"))
  let git = Git(repo: fixture.memory, environment: [:])
  _ = try git.data(["add", "MEMORY.md"])
  _ = try git.data(
    ["commit", "-m", "Synthetic duplicate legacy text"], additions: Git.proposalIdentity)
  try fixture.populate()
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        let context = try transactionObject(request)
        let anchors = context["eligibleMemoryAnchors"] as! [[String: Any]]
        let source = (context["primaryEvidence"] as! [[String: Any]])[0]["source"]!
        return try transactionResponse(
          request,
          decisions: anchors.enumerated().map { index, anchor in
            [
              "kind": "update", "scope": ["kind": "global"], "anchor": anchor,
              "text": index == 0
                ? "Keep the first café 🐟 entry longer." : "Keep the second café 🐟 entry.",
              "sources": [source], "reason": "Retain each separate correction.",
              "contradictions": [
                ["kind": "memory", "anchor": anchor, "explanation": "Replace this exact entry."]
              ],
            ]
          })
      }))
  let state = fixture.root.appendingPathComponent("review")
  var controller: MemoryReviewController? = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  let rows = try controller!.list().sorted { $0.change.locator!.start < $1.change.locator!.start }
  #expect(rows.count == 2)
  #expect(rows[0].change.before == rows[1].change.before)
  try controller!.confirmDetach(controller!.checkoutPreview())
  let date = Date(timeIntervalSince1970: 1_783_036_799)
  let first = try controller!.preview(candidateID: rows[0].change.id, clockDate: date)
  _ = try controller!.apply(first)
  controller = nil
  let reopened = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: fixture.store(), environment: [:])
  let second = try reopened.preview(
    candidateID: rows[1].change.id, clockDate: date.addingTimeInterval(1))
  #expect(second.before == rows[1].change.before)
  #expect(second.after.suffix(2) == Data([13, 10]))
  _ = try reopened.apply(second)
  #expect(try git.data(["show", "refs/heads/main:MEMORY.md"]) == second.replacement)
  let entries = MemoryDocument.entries(in: second.replacement).filter(\.isMutable)
  #expect(entries.map(\.identity) == [first.identity, second.identity])
  #expect(Set(entries.compactMap(\.identity)).count == 2)
}

@Test func reviewAbsentProjectAddsOnlyShownNativeEntryAndLeavesGlobalPending() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let project = fixture.root.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
  _ = try Git(repo: project, environment: [:]).data(["init", "--template="])
  try fixture.populate(cwd: project.path)
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0, isProject: true) }))
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  let rows = try controller.list()
  let row = rows.first { $0.change.path.hasPrefix("projects/") }!
  try controller.confirmDetach(controller.checkoutPreview())
  let preview = try controller.preview(
    candidateID: row.change.id, clockDate: Date(timeIntervalSince1970: 1_783_036_799))
  #expect(preview.replacement.starts(with: Data("# Memory\n\n".utf8)))
  _ = try controller.apply(preview)
  #expect(try controller.list().first { $0.change.path == "MEMORY.md" }?.disposition == .pending)
  #expect(MemoryDocument.entries(in: preview.replacement).filter(\.isMutable).count == 1)
}

@Test func reviewOverlappingCompletedCandidateStaysBlockedWithOriginalEvidence() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  try fixture.append(dreamUser("u1", nil, dreamOld, "Use purple buttons.") + "\n")
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        let context = try transactionObject(request)
        let anchor = (context["eligibleMemoryAnchors"] as! [[String: Any]])[0]
        let source = (context["primaryEvidence"] as! [[String: Any]])[0]["source"]!
        return try transactionResponse(
          request,
          decisions: [
            [
              "kind": "update", "scope": ["kind": "global"], "anchor": anchor,
              "text": "Use purple buttons.", "sources": [source],
              "reason": "Retain another correction.",
              "contradictions": [
                [
                  "kind": "memory", "anchor": anchor,
                  "explanation": "Replace the same original entry.",
                ]
              ],
            ]
          ])
      }))
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  let rows = try controller.list()
  let green = rows.first {
    String(decoding: $0.change.after, as: UTF8.self).contains("Use green buttons.")
  }!
  let purple = rows.first {
    String(decoding: $0.change.after, as: UTF8.self).contains("Use purple buttons.")
  }!
  try controller.confirmDetach(controller.checkoutPreview())
  _ = try controller.apply(
    controller.preview(
      candidateID: green.change.id, clockDate: Date(timeIntervalSince1970: 1_783_036_799)))
  let blocked = try controller.list().first { $0.change.id == purple.change.id }!
  #expect(blocked.disposition == .blocked)
  #expect(blocked.change.before == purple.change.before)
  #expect(blocked.change.sources[0].exactText == "Use purple buttons.")
  #expect(throws: (any Error).self) {
    try controller.preview(candidateID: purple.change.id, clockDate: Date())
  }
}

@Test func reviewUsesOnlySavedEvidenceAndDoesNotWriteDreamProgress() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  try FileManager.default.removeItem(at: fixture.sessions)
  try FileManager.default.removeItem(at: fixture.snippets)
  let saved = try fixture.snapshot(fixture.state)
  sources.clock = {
    Issue.record("review must not call dream clock")
    return Date()
  }
  sources.isCancelled = {
    Issue.record("review must not call dream cancellation")
    return false
  }
  sources.persistenceFault = { _ in Issue.record("review must not write dream state") }
  sources.beforePublication = { _ in Issue.record("review must not publish dream proposals") }
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  let candidate = try controller.list().first { $0.change.operation == .update }!
  try controller.confirmDetach(controller.checkoutPreview())
  let preview = try controller.preview(
    candidateID: candidate.change.id, clockDate: Date(timeIntervalSince1970: 1_783_036_799))
  #expect(preview.change.sources[0].exactText == "Use green buttons, not blue.")
  _ = try controller.apply(preview)
  #expect(try fixture.snapshot(fixture.state) == saved)
}

@Test(arguments: ["memory", "progress", "corpus", "symlink", "mode"])
func reviewStateRefusesProtectedOrUnsafeRootsWithoutAdmission(failure: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let state: URL
  switch failure {
  case "memory": state = fixture.memory.appendingPathComponent("review")
  case "progress": state = fixture.state.appendingPathComponent("review")
  case "corpus": state = fixture.snippets.appendingPathComponent("review")
  case "symlink":
    state = fixture.root.appendingPathComponent("review-link")
    try FileManager.default.createSymbolicLink(at: state, withDestinationURL: fixture.state)
  default:
    state = fixture.root.appendingPathComponent("review")
    #expect(mkdir(state.path, 0o755) == 0)
  }
  let before = try fixture.snapshot(fixture.root)
  #expect(throws: (any Error).self) {
    try MemoryReviewController(
      repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  }
  #expect(try fixture.snapshot(fixture.root) == before)
}

@Test func reviewAdmissionRefusesTamperedCompletionAndKernelConcurrentController() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let state = fixture.root.appendingPathComponent("review")
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  _ = try controller.list()
  #expect(throws: DreamRunError.busy) {
    try MemoryReviewController(
      repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  }
  let file = try fixture.payload("completion.json")
  var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
  object["unbound"] = "changed"
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
  let before = try fixture.snapshot(state)
  #expect(throws: (any Error).self) { try controller.list() }
  #expect(try fixture.snapshot(state) == before)
}

@Test func reviewListKeepsMixedFrozenBasesAndRechecksMainAfterEarlierList() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Keep A.", "Keep B.", "Keep C.", "Keep D."])
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  let original = try controller.list()
  try controller.reject(candidateID: original[0].change.id)
  try controller.deferCandidate(candidateID: original[1].change.id)
  try controller.confirmDetach(controller.checkoutPreview())
  _ = try controller.apply(
    controller.preview(
      candidateID: original[2].change.id, clockDate: Date(timeIntervalSince1970: 1_783_036_799)))
  try fixture.append(dreamUser("later", nil, dreamOld, "Keep E.") + "\n")
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let rows = try controller.list()
  #expect(rows.count == 5)
  #expect(rows.map(\.change.id.rawValue) == rows.map(\.change.id.rawValue).sorted())
  #expect(Set(rows.filter { $0.disposition == .pending }.map(\.change.base)).count == 2)
  for (index, disposition) in [
    MemoryReviewDisposition.rejected, .deferred, .approved, .pending,
  ].enumerated() {
    let row = rows.first { $0.change.id == original[index].change.id }!
    #expect(row.disposition == disposition)
    #expect(row.change.documentHash == original[index].change.documentHash)
  }
  let git = Git(repo: fixture.memory, environment: [:])
  let base = try fixture.main()
  let tree = try git.text(["rev-parse", "\(base)^{tree}"])
  let next = try git.text(
    ["commit-tree", tree, "-p", base], input: Data("Synthetic external advance\n".utf8),
    additions: Git.proposalIdentity)
  _ = try git.data(["update-ref", "refs/heads/main", next, base])
  let changed = try controller.list()
  #expect(changed.map(\.change.id) == rows.map(\.change.id))
  #expect(changed.filter { $0.disposition == .blocked }.count == 3)
  #expect(changed.filter { $0.disposition == .approved }.count == 1)
  #expect(changed.filter { $0.disposition == .rejected }.count == 1)
}
