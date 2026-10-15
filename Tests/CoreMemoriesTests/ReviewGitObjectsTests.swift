import Darwin
import Foundation
import Testing

@testable import CoreMemories

@Test func reviewGitObjectsRejectsMalformedOrMismatchedHeaders() throws {
  let oid = String(repeating: "a", count: 40)
  for header in [
    "\(oid) missing", "\(oid) blob -1", "\(oid) blob +1", "\(oid) blob 999999999999999999999",
    "\(oid) unknown 1", "\(oid) blob", "\(oid) blob 1 extra",
    "\(String(repeating: "b", count: 40)) blob 1",
  ] {
    #expect(throws: DreamRunError.corruption) {
      try ReviewGitObjects.Header(Data(header.utf8), oid: oid)
    }
  }
  let valid = try ReviewGitObjects.Header(Data("\(oid) blob 0".utf8), oid: oid)
  #expect(valid.type == "blob" && valid.size == 0 && valid.oid == oid)
}

private func reviewObjectChildren(_ root: URL) throws -> [Substring] {
  let result = try runCommand(
    executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-axo", "pid=,ppid=,args="],
    environment: [:])
  #expect(result.status == 0)
  return result.text.split(separator: "\n").filter {
    $0.contains(root.path) && $0.contains("cat-file --batch-command")
  }
}

@Test func reviewGitObjectsPreservesBinaryBodiesAndSnapshotValidation() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let git = Git(repo: fixture.memory, environment: [:])
  let reader = try ReviewGitObjects(git: git)
  defer { reader.close() }
  for bytes in [Data(), Data((0..<131_077).map { UInt8($0 % 256) })] {
    let oid = try git.text(["hash-object", "-w", "--stdin"], input: bytes)
    #expect(try reader.contents(oid, type: "blob", maximumBytes: bytes.count) == bytes)
  }
  let store = try MemoryStore(repo: fixture.memory, environment: [:])
  let base = try fixture.main()
  let ordinary = try store.reviewSnapshot(base: base)
  let batched = try store.reviewSnapshot(base: base, objects: reader)
  #expect(batched.layoutEntries == ordinary.layoutEntries)
  #expect(batched.layoutHash == ordinary.layoutHash)
  #expect(batched.documents.map(\.bytes) == ordinary.documents.map(\.bytes))
  #expect(batched.documents.map(\.diagnostics) == ordinary.documents.map(\.diagnostics))
  #expect(try reviewObjectChildren(fixture.memory).count == 1)
  reader.close()
  #expect(try reviewObjectChildren(fixture.memory).isEmpty)
  #expect(throws: DreamRunError.corruption) { try reader.info(base) }
}

@Test(arguments: [
  "missing", "wrong-type", "oversize", "unsafe-id", "corrupt-object", "blocked", "exited",
])
func reviewGitObjectsClosesAndReapsAfterReadFailure(failure: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let git = Git(repo: fixture.memory, environment: [:])
  let blob = try git.text(["hash-object", "-w", "--stdin"], input: Data("synthetic".utf8))
  if failure == "corrupt-object" || failure == "blocked" {
    let object = fixture.memory.appendingPathComponent(
      ".git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))")
    if failure == "blocked" {
      try FileManager.default.removeItem(at: object)
      #expect(mkfifo(object.path, 0o600) == 0)
    } else {
      let truncated = try Data(contentsOf: object).prefix(10)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: object.path)
      try truncated.write(to: object)
    }
  }
  let reader = try ReviewGitObjects(
    git: failure == "exited" ? Git(repo: fixture.sessions, environment: [:]) : git)
  defer { reader.close() }
  if failure == "exited" { Thread.sleep(forTimeInterval: 0.05) }
  #expect(throws: (any Error).self) {
    switch failure {
    case "missing": _ = try reader.info(String(repeating: "0", count: 40))
    case "wrong-type": _ = try reader.contents(blob, type: "commit", maximumBytes: 100)
    case "oversize": _ = try reader.contents(blob, type: "blob", maximumBytes: 1)
    case "unsafe-id": _ = try reader.info("HEAD\ncontents HEAD")
    case "corrupt-object": _ = try reader.contents(blob, type: "blob", maximumBytes: 100)
    default: _ = try reader.info(blob)
    }
  }
  #expect(throws: DreamRunError.corruption) { try reader.info(blob) }
  #expect(try reviewObjectChildren(fixture.root).isEmpty)
}
