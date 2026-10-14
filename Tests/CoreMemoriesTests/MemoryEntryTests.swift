import Foundation
import Testing

@testable import CoreMemories

@Test func legacyEntriesKeepUnknownReviewAndOriginalByteRanges() throws {
  let paragraph = "同じ memory [source: owner; added: 2024-02-29]\r\n"
  let bytes = Data(("# Memory\r\n\r\n" + paragraph + "\r\n" + paragraph).utf8)
  let entries = MemoryDocument.entries(in: bytes).filter(\.isMutable)
  #expect(entries.count == 2)
  #expect(entries[0].locator != entries[1].locator)
  for entry in entries {
    #expect(entry.identity == nil)
    #expect(entry.lastReview == nil)
    #expect(entry.bytes == Data(paragraph.utf8))
    #expect(bytes.subdata(in: entry.locator.start..<entry.locator.end) == entry.bytes)
  }
  #expect(MemoryDocument.failures(in: bytes).isEmpty)
}

@Test func reviewedBytesAdoptOnlySelectedLegacyEntryAndPreserveSourceAndEnding() throws {
  let paragraph = "Memory [source: owner; added: 2024-02-29]\r\n"
  var bytes = Data((paragraph + "\r\n" + paragraph).utf8)
  let entry = MemoryDocument.entries(in: bytes).first { $0.isMutable }!
  let identity = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  let instant = try MemoryDocument.ReviewInstant("2026-07-10T12:30:00Z")
  let reviewed = try MemoryDocument.reviewedBytes(entry.bytes, identity: identity, instant: instant)
  bytes.replaceSubrange(entry.locator.start..<entry.locator.end, with: reviewed)
  let entries = MemoryDocument.entries(in: bytes).filter(\.isMutable)
  #expect(entries.count == 2)
  #expect(entries[0].identity == identity)
  #expect(entries[0].lastReview == instant)
  #expect(entries[1].identity == nil)
  #expect(entries[1].lastReview == nil)
  #expect(entries[1].bytes == Data(paragraph.utf8))
  #expect(String(decoding: reviewed, as: UTF8.self).hasSuffix("Z]\r\n"))
  #expect(String(decoding: reviewed, as: UTF8.self).contains("[source: owner; added: 2024-02-29]"))
  #expect(MemoryDocument.failures(in: bytes).isEmpty)
}

@Test func invalidReviewDatesAndRepeatedIdentitiesCannotPassDocumentValidation() throws {
  for instant in [
    "2025-02-29T12:30:00Z", "2026-07-10T24:00:00Z", "2026-07-10", "2026-07-10T12:30:00+00:00",
  ] {
    #expect(throws: (any Error).self) { try MemoryDocument.ReviewInstant(instant) }
    let bytes = Data(
      "Memory [source: owner; added: 2024-02-29] [memory-id: 11111111-2222-3333-4444-555555555555; reviewed: \(instant)]\n"
        .utf8)
    #expect(!MemoryDocument.failures(in: bytes).isEmpty)
    #expect(!MemoryDocument.entries(in: bytes)[0].isMutable)
  }
  let paragraph =
    "Memory [source: owner; added: 2024-02-29] [memory-id: 11111111-2222-3333-4444-555555555555; reviewed: 2026-07-10T12:30:00Z]\n"
  let duplicated = Data((paragraph + "\n" + paragraph).utf8)
  #expect(MemoryDocument.failures(in: duplicated).contains("duplicate memory identity"))
  #expect(MemoryDocument.entries(in: duplicated).allSatisfy { !$0.isMutable })
}

@Test func reviewInstantAndEntryLocatorDecodingCannotBypassValidation() throws {
  for raw in ["2025-02-29T12:30:00Z", "2026-07-10T24:00:00Z", "2026-07-10"] {
    let bytes = try JSONEncoder().encode(["rawValue": raw])
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(MemoryDocument.ReviewInstant.self, from: bytes)
    }
  }
  for pair in [(-1, 2), (2, 2), (3, 2)] {
    let bytes = try JSONEncoder().encode(["start": pair.0, "end": pair.1])
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(MemoryDocument.EntryLocator.self, from: bytes)
    }
  }
}

@Test func reviewCannotReplaceExistingIdentityOrChangeNativeEndings() throws {
  let identity = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  let instant = try MemoryDocument.ReviewInstant("2026-07-10T12:30:00Z")
  for ending in ["\n", "\r\n", "\r", ""] {
    let bytes = Data(("Memory [source: owner; added: 2024-02-29]" + ending).utf8)
    let reviewed = try MemoryDocument.reviewedBytes(bytes, identity: identity, instant: instant)
    #expect(String(decoding: reviewed, as: UTF8.self).hasSuffix("Z]" + ending))
    #expect(throws: (any Error).self) {
      try MemoryDocument.reviewedBytes(reviewed, identity: UUID(), instant: instant)
    }
    #expect(
      try MemoryDocument.reviewedBytes(reviewed, identity: identity, instant: instant) == reviewed)
  }
}

@Test func escapedAndCodeReviewLookalikesDoNotBecomeMetadataAuthority() throws {
  for lookalike in [
    #"\[memory-id: bad; reviewed: bad]"#,
    "`[memory-id: bad; reviewed: bad]`",
  ] {
    let bytes = Data(("Memory " + lookalike + " [source: owner; added: 2024-02-29]\n").utf8)
    let entry = try #require(MemoryDocument.entries(in: bytes).first)
    #expect(entry.isMutable)
    #expect(entry.identity == nil)
    #expect(MemoryDocument.failures(in: bytes).isEmpty)
  }
  let fenced = Data("```\n[memory-id: bad; reviewed: bad]\n```\n".utf8)
  #expect(MemoryDocument.entries(in: fenced).allSatisfy { !$0.isMutable && $0.identity == nil })
  #expect(!MemoryDocument.failures(in: fenced).contains { $0.contains("review") })
}

@Test func malformedOptionalReviewMetadataKeepsApprovedLegacyMemoryReadable() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let bytes = "Memory [source: owner; added: 2024-02-29] [memory-id: bad; reviewed: bad]\n"
  try fixture.write(bytes, path: "MEMORY.md")
  try fixture.commit()
  #expect(try fixture.store.render(cwd: fixture.root) == bytes)
  #expect(!MemoryDocument.entries(in: Data(bytes.utf8))[0].isMutable)
}

@Test func approvedSnapshotDuplicateIdentityBlocksOnlyAffectedEntries() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let paragraph =
    "Memory [source: owner; added: 2024-02-29] [memory-id: 11111111-2222-3333-4444-555555555555; reviewed: 2026-07-10T12:30:00Z]\n"
  try fixture.write(paragraph + "\nLegacy [source: owner; added: 2024-02-29]\n", path: "MEMORY.md")
  try fixture.write(paragraph, path: "projects/" + String(repeating: "a", count: 64) + ".md")
  try fixture.commit()
  let snapshot = try fixture.store.reviewSnapshot(base: fixture.store.approvedCommit())
  let entries = snapshot.reviewEntries()
  #expect(entries.filter { $0.entry.identity != nil }.allSatisfy { !$0.entry.isMutable })
  #expect(entries.filter { $0.entry.identity == nil }.allSatisfy { $0.entry.isMutable })
}
