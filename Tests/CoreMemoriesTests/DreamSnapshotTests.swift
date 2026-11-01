import CryptoKit
import Foundation
import Testing

@testable import CoreMemories

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
