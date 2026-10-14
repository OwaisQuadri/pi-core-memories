import Foundation
import Testing

@testable import CoreMemories

@Test(arguments: [false, true])
func gitTransactionPrivateHeadPreservesHumanReflogsInMainAndLinkedWorktrees(isLinked: Bool) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let repository: URL
  if isLinked {
    repository = fixture.root.appendingPathComponent("linked memory")
    _ = try fixture.git(["worktree", "add", "--detach", repository.path])
    _ = try fixture.git(["symbolic-ref", "HEAD", "refs/heads/main"], at: repository)
  } else {
    repository = fixture.repo
  }
  let git = Git(repo: repository, environment: [:])
  let ref = "refs/heads/proposals/fixture"
  let before = try fixture.snapshot(fixture.repo).filter { !$0.key.hasPrefix(".git/objects/") }
  let result = try git.directRefTransaction(
    "verify refs/heads/main \(base)\ncreate \(ref) \(base)\n", refs: ["refs/heads/main", ref],
    isolatedHead: base)
  #expect(result.status == 0)
  #expect(try git.text(["rev-parse", ref]) == base)
  let after = try fixture.snapshot(fixture.repo).filter {
    !$0.key.hasPrefix(".git/objects/") && $0.key != ".git/refs/heads/proposals/fixture"
      && $0.key != ".git/logs/refs/heads/proposals/fixture"
  }
  #expect(after == before)
  _ = try git.data(["symbolic-ref", "HEAD", ref])
  let proposalHead = try fixture.snapshot(fixture.repo)
  let verified = try git.directRefTransaction(
    "verify \(ref) \(base)\n", refs: [ref], isolatedHead: base)
  #expect(verified.status == 0)
  #expect(try fixture.snapshot(fixture.repo) == proposalHead)
  let latest = try git.run(["rev-parse", "HEAD@{0}"])
  #expect(latest.status == 0 && !latest.errorText.contains("unexpectedly ended"))
}

@Test func gitTransactionPrivateHeadRefusesSymbolicRefsAndCheckedBaseConflicts() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let git = Git(repo: fixture.repo, environment: [:])
  let alias = "refs/heads/proposals/alias"
  _ = try git.data(["symbolic-ref", alias, "refs/heads/main"])
  let before = try fixture.snapshot(fixture.repo)
  #expect(throws: (any Error).self) {
    try git.directRefTransaction("verify \(alias) \(base)\n", refs: [alias], isolatedHead: base)
  }
  #expect(try fixture.snapshot(fixture.repo) == before)
  _ = try fixture.git(["commit", "--allow-empty", "-m", "Synthetic human advance"])
  let advanced = try fixture.snapshot(fixture.repo)
  let missing = "refs/heads/proposals/missing"
  let conflict = try git.directRefTransaction(
    "verify refs/heads/main \(base)\ncreate \(missing) \(base)\n",
    refs: ["refs/heads/main", missing], isolatedHead: base)
  #expect(conflict.status != 0)
  #expect(try fixture.snapshot(fixture.repo) == advanced)
}

@Test func gitTransactionRecoveryUsesSavedCommitWithoutCurrentMainOrHeadDependence() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let proposal = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: Data(fact("Synthetic preference").utf8),
    reason: "Synthetic reason")
  _ = try fixture.git(["commit", "--allow-empty", "-m", "Synthetic human advance"])
  _ = try fixture.git(["symbolic-ref", "HEAD", "refs/heads/missing"])
  let before = try fixture.snapshot(fixture.repo)
  let recovered = try fixture.store.recoverProposal(
    base: base, path: "MEMORY.md", replacement: Data(fact("Synthetic preference").utf8),
    reason: "Synthetic reason")
  #expect(recovered?.commit == proposal.commit)
  #expect(try fixture.snapshot(fixture.repo) == before)
}
