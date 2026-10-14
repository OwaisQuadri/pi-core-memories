import Foundation
import Testing

@testable import CoreMemories

func reviewCompletedSiblings(_ fixture: TransactionFixture) throws -> DreamRunStore {
  let original = "# Memory\n\nUse blue buttons. [source: pi:one#old/part/0; added: 2026-01-01]\n"
  try fixture.write(original, file: fixture.memory.appendingPathComponent("MEMORY.md"))
  let git = Git(repo: fixture.memory, environment: [:])
  _ = try git.data(["add", "MEMORY.md"])
  _ = try git.data(["commit", "-m", "Synthetic initial entry"], additions: Git.proposalIdentity)
  try fixture.populate()
  let sources = try fixture.store()
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
              "text": "Use green buttons.", "sources": [source], "reason": "Apply the correction.",
              "contradictions": [
                ["kind": "memory", "anchor": anchor, "explanation": "Replace blue."]
              ],
            ],
            [
              "kind": "add", "scope": ["kind": "global"], "text": "Keep the second entry.",
              "sources": [source], "reason": "Retain separate evidence.", "contradictions": [],
            ],
          ])
      }))
  return sources
}

@Test(arguments: [false, true])
func reviewExplicitDetachThenOneEntryApprovalKeepsSiblingAndCheckoutAcrossRestart(
  isSplitIndex: Bool
) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  if isSplitIndex {
    _ = try Git(repo: fixture.memory, environment: [:]).data(["update-index", "--split-index"])
  }
  let state = fixture.root.appendingPathComponent("review")
  var controller: MemoryReviewController? = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  let rows = try controller!.list()
  let update = rows.first { $0.change.operation == .update }!
  let add = rows.first { $0.change.operation == .add }!
  let original = try fixture.snapshot(fixture.memory)
  let base = try fixture.main()
  let checkout = try controller!.checkoutPreview()
  #expect(checkout.isDetachRequired)
  #expect(try fixture.snapshot(fixture.memory) == original)
  let date = Date(timeIntervalSince1970: 1_783_036_799)
  let beforeDetach = try controller!.preview(candidateID: update.change.id, clockDate: date)
  #expect(throws: (any Error).self) { try controller!.apply(beforeDetach) }
  #expect(try fixture.main() == base)
  try controller!.confirmDetach(checkout)
  #expect(try fixture.main() == base)
  let detached = try fixture.snapshot(fixture.memory)
  let afterDetach = try controller!.preview(candidateID: update.change.id, clockDate: date)
  let approval = try controller!.apply(afterDetach)
  #expect(try fixture.main() == approval.commit)
  let git = Git(repo: fixture.memory, environment: [:])
  #expect(try git.data(["show", "refs/heads/main:MEMORY.md"]) == afterDetach.replacement)
  #expect(
    !String(decoding: afterDetach.replacement, as: UTF8.self).contains("Keep the second entry."))
  #expect(afterDetach.change.contradictions.count == 1)
  #expect(try controller!.list().first { $0.change.id == add.change.id }?.disposition == .pending)
  controller = nil
  let reopened = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: fixture.store(), environment: [:])
  #expect(try reopened.list().first { $0.change.id == update.change.id }?.disposition == .approved)
  #expect(try reopened.list().first { $0.change.id == add.change.id }?.disposition == .pending)
  let second = try reopened.preview(
    candidateID: add.change.id, clockDate: date.addingTimeInterval(2))
  _ = try reopened.apply(second)
  #expect(try git.data(["show", "refs/heads/main:MEMORY.md"]) == second.replacement)
  #expect(MemoryDocument.entries(in: second.replacement).compactMap(\.identity).count == 2)
  let sharedPaths = detached.keys.filter { $0.contains("/.git/sharedindex.") }
  let protectedPaths = [".git/HEAD", ".git/index", ".git/config", "MEMORY.md", ".git/logs/HEAD"]
  let final = try fixture.snapshot(fixture.memory)
  for path in protectedPaths {
    let key = fixture.memory.appendingPathComponent(path).path
    #expect(final[key] == detached[key])
  }
  for key in sharedPaths { #expect(final[key] == detached[key]) }
}

@Test(arguments: ["HEAD", "index", "config"])
func reviewStaleCheckoutWitnessCannotDetach(file: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  let preview = try controller.checkoutPreview()
  let target = fixture.memory.appendingPathComponent(".git/" + file)
  switch file {
  case "HEAD": try fixture.write(preview.commit + "\n", file: target)
  case "config":
    let bytes = try Data(contentsOf: target) + Data("\n[user]\n\tname = Synthetic\n".utf8)
    try bytes.write(to: target)
  default: try fixture.write("Invalid index", file: target)
  }
  let before = try fixture.snapshot(fixture.memory)
  let main = try fixture.main()
  #expect(throws: (any Error).self) { try controller.confirmDetach(preview) }
  #expect(try fixture.snapshot(fixture.memory) == before)
  #expect(try fixture.main() == main)
}

@Test(arguments: [
  "dirty", "untracked", "ignored-untracked", "assume-unchanged", "HEAD.lock", "index.lock",
  "other-main",
])
func reviewDetachRefusesUnsafeCheckoutWithoutChangingAuthority(failure: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  _ = try controller.checkoutPreview()
  let git = Git(repo: fixture.memory, environment: [:])
  switch failure {
  case "dirty":
    try fixture.write("Dirty", file: fixture.memory.appendingPathComponent("MEMORY.md"))
  case "untracked":
    try fixture.write("User data", file: fixture.memory.appendingPathComponent("user.txt"))
  case "ignored-untracked":
    try fixture.write(
      "user.txt\n", file: fixture.memory.appendingPathComponent(".git/info/exclude"))
    try fixture.write("Ignored user data", file: fixture.memory.appendingPathComponent("user.txt"))
  case "assume-unchanged":
    _ = try git.data(["update-index", "--assume-unchanged", "MEMORY.md"])
    try fixture.write(
      "Hidden dirty tracked bytes", file: fixture.memory.appendingPathComponent("MEMORY.md"))
  case "other-main":
    _ = try git.data([
      "worktree", "add", "--force", fixture.root.appendingPathComponent("other").path, "main",
    ])
  default:
    try fixture.write("User lock", file: fixture.memory.appendingPathComponent(".git/" + failure))
  }
  let before = try fixture.snapshot(fixture.memory)
  let main = try fixture.main()
  #expect(throws: (any Error).self) { try controller.checkoutPreview() }
  #expect(try fixture.snapshot(fixture.memory) == before)
  #expect(try fixture.main() == main)
}
