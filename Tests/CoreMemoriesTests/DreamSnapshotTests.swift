import CryptoKit
import Foundation
import Testing

@testable import CoreMemories

@Test func dreamSnapshotExplicitCommonDirectorySymlinkPreservesOldProjectKeyAndRender() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let project = try fixture.project("project")
  let projectGit = Git(repo: project, environment: [:])
  _ = try projectGit.data(
    ["commit", "--allow-empty", "-m", "Synthetic project"], additions: Git.proposalIdentity)
  let common = fixture.root.appendingPathComponent("common")
  try FileManager.default.moveItem(at: project.appendingPathComponent(".git"), to: common)
  try FileManager.default.createSymbolicLink(
    atPath: project.appendingPathComponent(".git").path, withDestinationPath: "../common")
  let raw = try projectGit.text(["rev-parse", "--path-format=absolute", "--git-common-dir"])
  let oldKey = SHA256.hash(data: Data(URL(fileURLWithPath: raw).path.utf8)).map {
    String(format: "%02x", $0)
  }.joined()
  #expect(try MemoryStore.projectKey(cwd: project, environment: [:]) == oldKey)
  let alias = fixture.root.appendingPathComponent("project-alias")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
  let linked = fixture.root.appendingPathComponent("linked")
  _ = try projectGit.data(["worktree", "add", "--detach", linked.path])
  let approved = fact("Existing project preference")
  try fixture.write(approved, path: "projects/\(oldKey).md")
  try fixture.commit()
  for cwd in [project, alias, linked] {
    #expect(try MemoryStore.projectKey(cwd: cwd, environment: [:]) == oldKey)
    #expect(try fixture.store.render(cwd: cwd).contains(approved))
  }
}

@Test func dreamSnapshotPinsOldCommitAndExplicitAbsenceWithoutMutation() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let keys = ["a", "b", "c", "d"].map { String(repeating: $0, count: 64) }
  let global = fact("Old global")
  try fixture.write(global, path: "MEMORY.md")
  for key in keys.prefix(2) {
    try fixture.write(fact("Old \(key.prefix(1))"), path: "projects/\(key).md")
  }
  try fixture.write("Unrelated invalid annotations", path: "projects/\(keys[3]).md")
  try fixture.commit()
  let base = try fixture.store.approvedCommit()
  let old = try fixture.store.decisionSnapshot(base: base, projectKeys: Array(keys.prefix(3)))
  try fixture.write(fact("New global"), path: "MEMORY.md")
  try fixture.write(fact("Now present"), path: "projects/\(keys[2]).md")
  try fixture.commit()
  try fixture.write("Staged", path: "MEMORY.md")
  _ = try fixture.git(["add", "MEMORY.md"])
  try fixture.write("Dirty", path: "MEMORY.md")
  try fixture.write("Untracked", path: "human.txt")
  let before = try fixture.snapshot(fixture.repo)
  let snapshot = try fixture.store.decisionSnapshot(
    base: base, projectKeys: Array(keys.prefix(3).reversed()))
  #expect(snapshot.base == base && snapshot.layoutHash == old.layoutHash)
  #expect(
    snapshot.documents.map(\.path) == ["MEMORY.md"] + keys.prefix(3).map { "projects/\($0).md" })
  #expect(snapshot.documents[0].bytes == Data(global.utf8))
  #expect(snapshot.documents[1].bytes == Data(fact("Old a").utf8))
  #expect(snapshot.documents[2].bytes == Data(fact("Old b").utf8))
  #expect(snapshot.documents[3].bytes == nil && snapshot.documents[3].digest == nil)
  #expect(snapshot.documents.count == 4 && snapshot.layoutEntryCount == 4)
  #expect(try fixture.snapshot(fixture.repo) == before)
}

@Test(arguments: ["main", "tag", "tree", "blob", "missing", "uppercase", "expression"])
func dreamSnapshotRejectsNonCommitIdentity(kind: String) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  _ = try fixture.git(["tag", "fixture", base])
  let input: String
  switch kind {
  case "tree": input = try fixture.git(["rev-parse", "\(base)^{tree}"])
  case "blob": input = try fixture.git(["rev-parse", "\(base):MEMORY.md"])
  case "missing": input = String(repeating: "0", count: 40)
  case "uppercase": input = base.uppercased()
  case "expression": input = base + "^{commit}"
  case "tag": input = "fixture"
  default: input = "main"
  }
  let before = try fixture.snapshot(fixture.repo)
  #expect(throws: (any Error).self) {
    try fixture.store.decisionSnapshot(base: input, projectKeys: [])
  }
  #expect(try fixture.snapshot(fixture.repo) == before)
}

@Test(arguments: ["extra", "symlink", "submodule", "unsafe", "missingGlobal"])
func dreamSnapshotRejectsUnsafeWholeLayout(kind: String) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let key = String(repeating: "a", count: 64)
  switch kind {
  case "extra": try fixture.write("Code", path: "README.md")
  case "unsafe": try fixture.write("Bad", path: "projects/\(key).md\n")
  case "symlink":
    try FileManager.default.createDirectory(
      at: fixture.repo.appendingPathComponent("projects"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: fixture.repo.appendingPathComponent("projects/\(key).md").path,
      withDestinationPath: "../MEMORY.md")
  case "submodule":
    let base = try fixture.store.approvedCommit()
    _ = try fixture.git([
      "update-index", "--add", "--cacheinfo", "160000,\(base),projects/\(key).md",
    ])
  default: try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent("MEMORY.md"))
  }
  if kind == "submodule" {
    _ = try fixture.git(["commit", "-m", "Unsafe fixture"])
  } else {
    try fixture.commit()
  }
  let before = try fixture.snapshot(fixture.repo)
  #expect(throws: (any Error).self) {
    try fixture.store.decisionSnapshot(base: fixture.store.approvedCommit(), projectKeys: [])
  }
  #expect(try fixture.snapshot(fixture.repo) == before)
}

@Test func dreamSnapshotRejectsMissingObjectsOfflineAndSanitizesRouting() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let other = try fixture.project("other")
  let base = try fixture.store.approvedCommit()
  let blob = try fixture.git(["rev-parse", "\(base):MEMORY.md"])
  _ = try fixture.git(["config", "extensions.partialClone", "origin"])
  _ = try fixture.git(["config", "remote.origin.promisor", "true"])
  _ = try fixture.git(["config", "remote.origin.url", "ext::/usr/bin/false"])
  var environment = hostileEnvironment(other: other)
  environment["GIT_NO_LAZY_FETCH"] = "0"
  let store = try MemoryStore(repo: fixture.repo, environment: environment)
  let otherBefore = try fixture.snapshot(other)
  let intact = try fixture.snapshot(fixture.repo)
  #expect(
    try store.decisionSnapshot(base: base, projectKeys: []).documents[0].bytes
      == Data("# Memory\n".utf8))
  #expect(try fixture.snapshot(fixture.repo) == intact)
  try FileManager.default.removeItem(
    at: fixture.repo.appendingPathComponent(".git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))"))
  let before = try fixture.snapshot(fixture.repo)
  #expect(throws: (any Error).self) { try store.decisionSnapshot(base: base, projectKeys: []) }
  #expect(try fixture.snapshot(fixture.repo) == before)
  #expect(try fixture.snapshot(other) == otherBefore)
}

@Test(arguments: [Data([255]), Data("NUL\0".utf8)])
func dreamSnapshotRejectsInvalidSelectedEncoding(bytes: Data) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try bytes.write(to: fixture.repo.appendingPathComponent("MEMORY.md"))
  try fixture.commit()
  #expect(throws: (any Error).self) {
    try fixture.store.decisionSnapshot(base: fixture.store.approvedCommit(), projectKeys: [])
  }
}

@Test func dreamSnapshotLayoutEntryBoundAcceptsExactAndRejectsOneOver() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  #expect(
    try fixture.store.decisionSnapshot(
      base: base, projectKeys: [], limits: DreamDecisionLimits(maximumLayoutEntries: 1)
    ).layoutEntryCount == 1)
  try fixture.write(
    fact("Unselected project"), path: "projects/\(String(repeating: "a", count: 64)).md")
  try fixture.commit()
  #expect(throws: (any Error).self) {
    try fixture.store.decisionSnapshot(
      base: fixture.store.approvedCommit(), projectKeys: [],
      limits: DreamDecisionLimits(maximumLayoutEntries: 1))
  }
}

@Test func dreamSnapshotRetainsAnnotationDiagnosticsAndChecksKeyBounds() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try fixture.write("Missing annotation\n", path: "MEMORY.md")
  try fixture.commit()
  let base = try fixture.store.approvedCommit()
  let snapshot = try fixture.store.decisionSnapshot(base: base, projectKeys: [])
  #expect(
    snapshot.documents[0].diagnostics
      == MemoryDocument.failures(in: Data("Missing annotation\n".utf8)))
  for keys in [
    ["cwd"], [String(repeating: "A", count: 64)],
    [String(repeating: "a", count: 64), String(repeating: "a", count: 64)],
  ] {
    #expect(throws: (any Error).self) {
      try fixture.store.decisionSnapshot(base: base, projectKeys: keys)
    }
  }
  let key = String(repeating: "a", count: 64)
  #expect(
    try fixture.store.decisionSnapshot(
      base: base, projectKeys: [key], limits: DreamDecisionLimits(maximumProjectKeys: 1)
    ).documents.count == 2)
  #expect(throws: (any Error).self) {
    try fixture.store.decisionSnapshot(
      base: base, projectKeys: [key, String(repeating: "b", count: 64)],
      limits: DreamDecisionLimits(maximumProjectKeys: 1))
  }
  let bytes = snapshot.documents[0].bytes!.count
  _ = try fixture.store.decisionSnapshot(
    base: base, projectKeys: [],
    limits: DreamDecisionLimits(
      maximumLayoutEntries: 1, maximumLayoutBytes: snapshot.layoutByteCount,
      maximumSnapshotBytes: bytes, maximumDocumentBytes: bytes))
  for limits in [
    try DreamDecisionLimits(maximumLayoutBytes: snapshot.layoutByteCount - 1),
    try DreamDecisionLimits(maximumDocumentBytes: bytes - 1),
    try DreamDecisionLimits(maximumSnapshotBytes: bytes - 1),
  ] {
    #expect(throws: (any Error).self) {
      try fixture.store.decisionSnapshot(base: base, projectKeys: [], limits: limits)
    }
  }
}

@Test func dreamSnapshotSuppliedWitnessReconstructsWithoutGitAndRejectsForgedTuples() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let key = String(repeating: "a", count: 64)
  let snapshot = try fixture.store.decisionSnapshot(
    base: fixture.store.approvedCommit(), projectKeys: [key])
  try FileManager.default.removeItem(at: fixture.repo)
  let supplied = try ApprovedDecisionSnapshot(
    base: snapshot.base, layoutEntries: snapshot.layoutEntries, documents: snapshot.documents,
    limits: DreamDecisionLimits())
  #expect(
    supplied.layoutHash == snapshot.layoutHash
      && supplied.layoutByteCount == snapshot.layoutByteCount)
  for kind in ["mode", "blob", "path", "duplicate", "absence", "digest", "diagnostics"] {
    var entries = snapshot.layoutEntries
    var documents = snapshot.documents
    switch kind {
    case "mode":
      entries[0] = ApprovedDecisionLayoutEntry(
        path: entries[0].path, mode: "120000", blob: entries[0].blob)
    case "blob":
      entries[0] = ApprovedDecisionLayoutEntry(
        path: entries[0].path, mode: entries[0].mode, blob: "not-an-object")
    case "path":
      entries[0] = ApprovedDecisionLayoutEntry(
        path: "../MEMORY.md", mode: entries[0].mode, blob: entries[0].blob)
    case "duplicate": entries.append(entries[0])
    case "absence":
      documents[0] = ApprovedDecisionDocument(
        path: "MEMORY.md", mode: nil, blob: nil, digest: nil, bytes: nil, diagnostics: [])
    default:
      let original = documents[0]
      documents[0] = ApprovedDecisionDocument(
        path: original.path, mode: original.mode, blob: original.blob,
        digest: kind == "digest" ? SourceDigest(bytes: Data("forged".utf8)) : original.digest,
        bytes: original.bytes,
        diagnostics: kind == "diagnostics" ? ["forged diagnostics"] : original.diagnostics)
    }
    #expect(throws: (any Error).self) {
      try ApprovedDecisionSnapshot(
        base: snapshot.base, layoutEntries: entries, documents: documents,
        limits: DreamDecisionLimits())
    }
  }
}
