import Darwin
import Foundation
import Testing

@testable import CoreMemories
@testable import PiCoreMemories

@Test func reviewWorkerWithoutInheritedControlChannelCannotPublish() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Keep A.", "Keep B."])
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let before = try fixture.snapshot(fixture.memory)
  let worker = try DreamWorkerProcess(arguments: ["memory-review-worker"])
  defer { worker.clean() }
  let final = try worker.frame()
  #expect(final["type"] as? String == "final")
  #expect(final["status"] as? String == "failed")
  try worker.finish(status: 1)
  #expect(try fixture.snapshot(fixture.memory) == before)
}

@Test func reviewWorkerApprovalArgumentsAreNotACommandSurface() throws {
  let worker = try DreamWorkerProcess(arguments: ["memory-review-worker", "approve"])
  defer { worker.clean() }
  let final = try worker.frame()
  #expect(final["status"] as? String == "failed")
  try worker.finish(status: 1)
}
