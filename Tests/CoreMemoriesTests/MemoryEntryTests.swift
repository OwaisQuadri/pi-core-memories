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
