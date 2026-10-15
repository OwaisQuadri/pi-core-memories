import Darwin
import Foundation
import Testing
import XCTest

@testable import CoreMemories

final class MemoryReviewProcessHelper: XCTestCase {
  func testReviewLockHelper() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let root = environment["MEMORY_REVIEW_FIXTURE"],
      let mode = environment["MEMORY_REVIEW_MODE"]
    else { return }
    let fixture = try TransactionFixture(root: URL(fileURLWithPath: root), isCreating: false)
    do {
      if mode == "kill-management-locks" {
        let manager = try MemoryManagement(repository: fixture.memory, environment: [:])
        manager.afterCheckoutLocks = {
          try FileHandle.standardOutput.write(contentsOf: Data([1]))
          while true { _ = pause() }
        }
        try manager.confirmDetach(manager.checkoutPreview())
        throw MemoryError("management fixture did not reach checkout locks")
      }
      let controller = try MemoryReviewController(
        repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
        sources: fixture.store(), environment: [:])
      let rows = try controller.list()
      if mode.hasPrefix("kill-") {
        let isApproval = mode.hasPrefix("kill-approve-")
        if isApproval { try controller.confirmDetach(controller.checkoutPreview()) }
        let checkoutCommit = try controller.checkoutPreview().commit
        controller.persistenceFault = { event in
          let isStop: Bool
          switch mode {
          case "kill-detach-locks", "kill-approve-locks": isStop = event == .afterCheckoutLocks
          case "kill-detach-before", "kill-detach-prefix": isStop = event == .beforeDetach
          case "kill-detach-after": isStop = event == .afterDetach
          case "kill-approve-before": isStop = event == .beforePublication
          case "kill-approve-after": isStop = event == .afterPublication
          default:
            if case .beforeWrite(let name) = event {
              isStop = name.hasPrefix("detach-outcome-")
            } else {
              isStop = false
            }
          }
          if isStop {
            if mode == "kill-detach-prefix" {
              let file = try FileHandle(
                forWritingTo: fixture.memory.appendingPathComponent(".git/HEAD.lock"))
              try file.write(contentsOf: Data(checkoutCommit.utf8.prefix(8)))
              try file.synchronize()
              try file.close()
            }
            try FileHandle.standardOutput.write(contentsOf: Data([1]))
            while true { _ = pause() }
          }
        }
        if isApproval {
          let candidate = rows.first { $0.change.operation == .update }!
          let preview = try controller.preview(candidateID: candidate.change.id, clockDate: Date())
          _ = try controller.apply(preview)
        } else {
          try controller.confirmDetach(controller.checkoutPreview())
        }
        throw MemoryError("kill fixture did not reach its boundary")
      }
      if mode == "hold" {
        try fixture.write("held", file: fixture.root.appendingPathComponent("review-helper-signal"))
        withExtendedLifetime(controller) {
          while true { usleep(10_000) }
        }
      }
      try fixture.write(
        "pending", file: fixture.root.appendingPathComponent("review-helper-result"))
    } catch DreamRunError.busy {
      try fixture.write("busy", file: fixture.root.appendingPathComponent("review-helper-result"))
    }
  }
}

private func reviewStartHelper(_ fixture: TransactionFixture, mode: String) throws -> Process {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  process.arguments = [
    "xctest", "-XCTest", "CoreMemoriesTests.MemoryReviewProcessHelper/testReviewLockHelper",
    Bundle(for: MemoryReviewProcessHelper.self).bundleURL.path,
  ]
  process.environment = [
    "PATH": "/usr/bin:/bin", "MEMORY_REVIEW_FIXTURE": fixture.root.path, "MEMORY_REVIEW_MODE": mode,
  ]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  return process
}

@Test func reviewKernelLockAcrossProcessesReleasesOnProcessDeath() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try reviewCompletedSiblings(fixture)
  let owner = try reviewStartHelper(fixture, mode: "hold")
  defer {
    if owner.isRunning {
      kill(owner.processIdentifier, SIGKILL)
      owner.waitUntilExit()
    }
  }
  let deadline = Date().addingTimeInterval(15)
  while !FileManager.default.fileExists(
    atPath: fixture.root.appendingPathComponent("review-helper-signal").path)
  {
    guard owner.isRunning, Date() < deadline else {
      throw MemoryError("review helper did not acquire lock")
    }
    usleep(10_000)
  }
  let before = try fixture.snapshot(fixture.root.appendingPathComponent("review"))
  let competitor = try reviewStartHelper(fixture, mode: "reopen")
  competitor.waitUntilExit()
  #expect(competitor.terminationStatus == 0)
  #expect(
    try String(
      contentsOf: fixture.root.appendingPathComponent("review-helper-result"), encoding: .utf8)
      == "busy")
  #expect(try fixture.snapshot(fixture.root.appendingPathComponent("review")) == before)
  #expect(kill(owner.processIdentifier, SIGKILL) == 0)
  owner.waitUntilExit()
  let successor = try reviewStartHelper(fixture, mode: "reopen")
  successor.waitUntilExit()
  #expect(successor.terminationStatus == 0)
  #expect(
    try String(
      contentsOf: fixture.root.appendingPathComponent("review-helper-result"), encoding: .utf8)
      == "pending")
}

private func killReviewAtBoundary(_ fixture: TransactionFixture, mode: String) throws {
  let signal = Pipe()
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  process.arguments = [
    "xctest", "-XCTest", "CoreMemoriesTests.MemoryReviewProcessHelper/testReviewLockHelper",
    Bundle(for: MemoryReviewProcessHelper.self).bundleURL.path,
  ]
  process.environment = [
    "PATH": "/usr/bin:/bin", "MEMORY_REVIEW_FIXTURE": fixture.root.path,
    "MEMORY_REVIEW_MODE": mode,
  ]
  process.standardOutput = signal
  process.standardError = FileHandle.nullDevice
  try process.run()
  defer {
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
  try signal.fileHandleForWriting.close()
  var descriptor = pollfd(
    fd: signal.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
  guard poll(&descriptor, 1, 20_000) == 1,
    try signal.fileHandleForReading.read(upToCount: 1) == Data([1])
  else { throw MemoryError("kill fixture did not acquire checkout locks") }
  #expect(kill(process.processIdentifier, SIGKILL) == 0)
  process.waitUntilExit()
  #expect(process.terminationReason == .uncaughtSignal)
}

@Test(arguments: [
  "kill-detach-locks", "kill-detach-before", "kill-detach-prefix", "kill-detach-after",
  "kill-detach-audit",
  "kill-approve-locks", "kill-approve-before", "kill-approve-after",
])
func reviewKilledCheckoutOwnerRecoversExactLocksAndPermitsFreshPreview(mode: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try reviewCompletedSiblings(fixture)
  let original = try fixture.main()
  let index = try Data(contentsOf: fixture.memory.appendingPathComponent(".git/index"))
  let working = try Data(contentsOf: fixture.memory.appendingPathComponent("MEMORY.md"))
  try killReviewAtBoundary(fixture, mode: mode)
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: fixture.store(), environment: [:])
  let rows = try controller.list()
  let isPublished = mode == "kill-approve-after"
  #expect(rows.filter { $0.disposition == .approved }.count == (isPublished ? 1 : 0))
  #expect((try fixture.main() != original) == isPublished)
  let checkout = try controller.checkoutPreview()
  #expect(
    checkout.isDetachRequired
      == (mode == "kill-detach-locks" || mode == "kill-detach-before"
        || mode == "kill-detach-prefix"))
  let pending = rows.first { $0.disposition == .pending }!
  _ = try controller.preview(candidateID: pending.change.id, clockDate: Date())
  for name in ["HEAD.lock", "index.lock"] {
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.memory.appendingPathComponent(".git/\(name)").path))
  }
  #expect(try Data(contentsOf: fixture.memory.appendingPathComponent(".git/index")) == index)
  #expect(try Data(contentsOf: fixture.memory.appendingPathComponent("MEMORY.md")) == working)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.root.appendingPathComponent("review/checkout-lease.json").path))
}

@Test(arguments: ["kill-management-locks", "kill-detach-locks", "legacy"])
func managementAndReviewRecoverKilledCheckoutOwnersAcrossEntrypoints(mode: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try reviewCompletedSiblings(fixture)
  try killReviewAtBoundary(fixture, mode: mode == "legacy" ? "kill-detach-locks" : mode)
  let shared = fixture.memory.appendingPathComponent(".git/memory-management/checkout-lease.json")
  let legacy = fixture.root.appendingPathComponent("review/checkout-lease.json")
  if mode == "legacy" {
    try FileManager.default.moveItem(at: shared, to: legacy)
    let manager = try MemoryManagement(repository: fixture.memory, environment: [:])
    #expect(throws: (any Error).self) { try manager.checkoutPreview() }
    #expect(FileManager.default.fileExists(atPath: legacy.path))
  }
  let before = try fixture.main()
  if mode == "kill-detach-locks" {
    let manager = try MemoryManagement(repository: fixture.memory, environment: [:])
    #expect(try manager.checkoutPreview().isDetachRequired)
  } else {
    let controller = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: fixture.store(), environment: [:])
    #expect(try controller.checkoutPreview().isDetachRequired)
    #expect(try controller.list().allSatisfy { $0.disposition == .pending })
  }
  #expect(try fixture.main() == before)
  for path in [
    shared, legacy, fixture.memory.appendingPathComponent(".git/HEAD.lock"),
    fixture.memory.appendingPathComponent(".git/index.lock"),
  ] {
    #expect(!FileManager.default.fileExists(atPath: path.path))
  }
}

@Test func reviewDetachRefusesLiveSameInodeHeadLockTail() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: reviewCompletedSiblings(fixture), environment: [:])
  let preview = try controller.checkoutPreview()
  let head = fixture.memory.appendingPathComponent(".git/HEAD")
  let original = try Data(contentsOf: head)
  let changed = Data(String(repeating: "x", count: preview.commit.utf8.count + 10).utf8)
  controller.persistenceFault = { event in
    if event == .afterCheckoutLocks {
      let file = try FileHandle(
        forWritingTo: fixture.memory.appendingPathComponent(".git/HEAD.lock"))
      try file.write(contentsOf: changed)
      try file.synchronize()
      try file.close()
    }
  }
  #expect(throws: (any Error).self) { try controller.confirmDetach(preview) }
  #expect(try Data(contentsOf: head) == original)
  #expect(try fixture.main() == preview.main)
  let anchors = try FileManager.default.contentsOfDirectory(
    at: fixture.memory.appendingPathComponent(".git"), includingPropertiesForKeys: nil)
  let anchor = try #require(
    anchors.first {
      $0.lastPathComponent.hasPrefix("memory-review-")
        && $0.lastPathComponent.hasSuffix("HEAD.lock")
    })
  #expect(try Data(contentsOf: anchor) == changed)
}

@Test func reviewDeadOwnerRecoveryRefusesEmptyInstalledHeadWithoutRemovingLease() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try reviewCompletedSiblings(fixture)
  try killReviewAtBoundary(fixture, mode: "kill-detach-after")
  let checkout = try Git(repo: fixture.memory, environment: [:]).reviewCheckout()
  let state = try DreamStateDirectory.openRoot(
    fixture.memory.appendingPathComponent(".git/memory-management"))
  let file = try FileHandle(forWritingTo: fixture.memory.appendingPathComponent(".git/HEAD"))
  try file.truncate(atOffset: 0)
  try file.synchronize()
  try file.close()
  let before = try fixture.snapshot(fixture.root)
  #expect(throws: (any Error).self) { try checkout.recoverLease(state: state) }
  #expect(try fixture.snapshot(fixture.root) == before)
}

@Test func reviewDetachRefusesReplacementOfLiveOwnedHeadLock() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  let preview = try controller.checkoutPreview()
  let head = fixture.memory.appendingPathComponent(".git/HEAD")
  let original = try Data(contentsOf: head)
  let foreign = fixture.memory.appendingPathComponent(".git/HEAD.lock")
  controller.persistenceFault = { event in
    if event == .afterCheckoutLocks {
      try FileManager.default.removeItem(at: foreign)
      try fixture.write("foreign", file: foreign)
    }
  }
  #expect(throws: (any Error).self) { try controller.confirmDetach(preview) }
  #expect(try Data(contentsOf: head) == original)
  #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
  #expect(try fixture.main() == preview.main)
}

@Test(arguments: ["replaced-lock", "changed-anchor", "extra-link"])
func reviewDeadOwnerRecoveryRefusesForeignLockIdentityContentsOrTopology(failure: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try reviewCompletedSiblings(fixture)
  try killReviewAtBoundary(fixture, mode: "kill-detach-locks")
  let index = fixture.memory.appendingPathComponent(".git/index.lock")
  if failure == "replaced-lock" {
    try FileManager.default.removeItem(at: index)
    try fixture.write("foreign", file: index)
  } else if failure == "changed-anchor" {
    try Data("foreign".utf8).write(to: index)
  } else {
    #expect(link(index.path, fixture.root.appendingPathComponent("extra-link").path) == 0)
  }
  let before = try fixture.snapshot(fixture.memory)
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: fixture.store(), environment: [:])
  #expect(throws: (any Error).self) { try controller.list() }
  let manager = try MemoryManagement(repository: fixture.memory, environment: [:])
  #expect(throws: (any Error).self) { try manager.checkoutPreview() }
  #expect(try fixture.snapshot(fixture.memory) == before)
}

@Test(arguments: [MemoryReviewPersistenceEvent.beforePublication, .afterPublication])
func reviewCrashRecoveryUsesExactAuditNotAttemptOrCurrentMain(event: MemoryReviewPersistenceEvent)
  throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let state = fixture.root.appendingPathComponent("review")
  var controller: MemoryReviewController? = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  let rows = try controller!.list()
  let update = rows.first { $0.change.operation == .update }!
  let add = rows.first { $0.change.operation == .add }!
  try controller!.confirmDetach(controller!.checkoutPreview())
  let preview = try controller!.preview(
    candidateID: update.change.id, clockDate: Date(timeIntervalSince1970: 1_783_036_799))
  let original = try fixture.main()
  let git = Git(repo: fixture.memory, environment: [:])
  controller!.persistenceFault = { observed in
    if observed == event {
      if event == .afterPublication {
        let parent = try fixture.main()
        let tree = try git.text(["rev-parse", "\(parent)^{tree}"])
        let next = try git.text(
          ["commit-tree", tree, "-p", parent], input: Data("Synthetic external advance\n".utf8),
          additions: Git.proposalIdentity)
        _ = try git.data(["update-ref", "refs/heads/main", next, parent])
      }
      throw MemoryError("synthetic process interruption")
    }
  }
  #expect(throws: (any Error).self) { try controller!.apply(preview) }
  let mainAfterFailure = try fixture.main()
  #expect((mainAfterFailure == original) == (event == .beforePublication))
  controller = nil
  let reopened = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: fixture.store(), environment: [:])
  let recovered = try reopened.list()
  #expect(
    recovered.first { $0.change.id == update.change.id }?.disposition
      == (event == .afterPublication ? .approved : .pending))
  #expect(try fixture.main() == mainAfterFailure)
  #expect(throws: (any Error).self) { try reopened.apply(preview) }
  if event == .afterPublication {
    #expect(recovered.first { $0.change.id == add.change.id }?.disposition == .blocked)
    try FileManager.default.removeItem(
      at: state.appendingPathComponent("outcome-\(update.change.id.rawValue).json"))
    #expect(
      try reopened.list().first { $0.change.id == update.change.id }?.disposition == .approved)
  } else {
    #expect(recovered.first { $0.change.id == add.change.id }?.disposition == .pending)
  }
}

@Test(arguments: [MemoryReviewPersistenceEvent.beforeDetach, .afterDetach])
func reviewDetachInterruptionNeverApprovesAnEntry(event: MemoryReviewPersistenceEvent) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let state = fixture.root.appendingPathComponent("review")
  var controller: MemoryReviewController? = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  _ = try controller!.list()
  let preview = try controller!.checkoutPreview()
  let main = try fixture.main()
  controller!.persistenceFault = { observed in
    if observed == event { throw MemoryError("synthetic detach interruption") }
  }
  #expect(throws: (any Error).self) { try controller!.confirmDetach(preview) }
  controller = nil
  let reopened = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: fixture.store(), environment: [:])
  #expect(try reopened.list().allSatisfy { $0.disposition == .pending })
  #expect(try fixture.main() == main)
  #expect(try reopened.checkoutPreview().isDetachRequired == (event == .beforeDetach))
}

@Test(arguments: ["short-write", "zero-write", "sync", "rename"])
func reviewPrivateWriteFailureDoesNotRejectOrApprove(failure: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let state = fixture.root.appendingPathComponent("review")
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  let candidate = try controller.list()[0].change.id
  let main = try fixture.main()
  switch failure {
  case "short-write": controller.fileIO.writeChunkBytes = 3
  case "zero-write": controller.fileIO.write = { _, _, _ in 0 }
  case "sync": controller.fileIO.sync = { _ in -1 }
  default: controller.fileIO.install = { _, _, _ in -1 }
  }
  if failure == "short-write" {
    try controller.reject(candidateID: candidate)
  } else {
    #expect(throws: (any Error).self) { try controller.reject(candidateID: candidate) }
  }
  controller.fileIO = MemoryReviewFileIO()
  let row = try controller.list().first { $0.change.id == candidate }!
  #expect(row.disposition == (failure == "short-write" ? .rejected : .pending))
  #expect(try fixture.main() == main)
}

@Test func reviewRetainedStateCapRefusesWithoutDroppingCandidatesOrPendingFiles() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let state = fixture.root.appendingPathComponent("review")
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  let rows = try controller.list()
  let file = state.appendingPathComponent(".pending-retained")
  let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
  #expect(descriptor >= 0)
  defer { _ = close(descriptor) }
  #expect(ftruncate(descriptor, off_t(MemoryReviewEncoding.maximumStateBytes + 1)) == 0)
  let names = try FileManager.default.contentsOfDirectory(atPath: state.path).sorted()
  let main = try fixture.main()
  #expect(throws: DreamRunError.limitExceeded) { try controller.list() }
  #expect(try FileManager.default.contentsOfDirectory(atPath: state.path).sorted() == names)
  #expect(names.filter { $0.hasPrefix("candidate-") }.count == rows.count)
  #expect(try fixture.main() == main)
}

@Test func reviewMainRaceAfterSavedAttemptCannotPublishAuditOrRefreshConfirmation() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  let id = try controller.list()[0].change.id
  try controller.confirmDetach(controller.checkoutPreview())
  let preview = try controller.preview(
    candidateID: id, clockDate: Date(timeIntervalSince1970: 1_783_036_799))
  let git = Git(repo: fixture.memory, environment: [:])
  var advanced: String?
  controller.persistenceFault = { event in
    if event == .beforePublication {
      let parent = try fixture.main()
      let tree = try git.text(["rev-parse", "\(parent)^{tree}"])
      let next = try git.text(
        ["commit-tree", tree, "-p", parent], input: Data("Synthetic main race\n".utf8),
        additions: Git.proposalIdentity)
      _ = try git.data(["update-ref", "refs/heads/main", next, parent])
      advanced = next
    }
  }
  #expect(throws: (any Error).self) { try controller.apply(preview) }
  #expect(try fixture.main() == advanced)
  #expect(
    try git.text(["for-each-ref", "--format=%(refname)", "refs/memory-review/approvals/"]).isEmpty)
  #expect(throws: (any Error).self) { try controller.apply(preview) }
  #expect(try controller.list().allSatisfy { $0.disposition == .blocked })
}

@Test(arguments: ["symbolic-audit", "missing-audit", "changed-attempt", "hardlink-state"])
func reviewRecoveryRefusesCorruptAuthorityRatherThanTrustOutcome(failure: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let state = fixture.root.appendingPathComponent("review")
  var controller: MemoryReviewController? = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  let id = try controller!.list()[0].change.id
  try controller!.confirmDetach(controller!.checkoutPreview())
  let preview = try controller!.preview(
    candidateID: id, clockDate: Date(timeIntervalSince1970: 1_783_036_799))
  let approval = try controller!.apply(preview)
  _ = try controller!.list()
  let git = Git(repo: fixture.memory, environment: [:])
  switch failure {
  case "symbolic-audit": _ = try git.data(["symbolic-ref", approval.auditRef, "refs/heads/main"])
  case "missing-audit": _ = try git.data(["update-ref", "-d", approval.auditRef])
  case "hardlink-state":
    #expect(
      link(
        state.appendingPathComponent("root.json").path,
        fixture.root.appendingPathComponent("linked-private-file").path) == 0)
  default:
    let file = state.appendingPathComponent("attempt-\(preview.digest.rawValue).json")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    object["resultTree"] = String(repeating: "0", count: 40)
    try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
    ).write(to: file)
  }
  let main = try fixture.main()
  let before = try fixture.snapshot(state)
  #expect(throws: (any Error).self) { try controller!.list() }
  controller = nil
  #expect(throws: (any Error).self) {
    let reopened = try MemoryReviewController(
      repository: fixture.memory, stateRoot: state, sources: fixture.store(), environment: [:])
    _ = try reopened.list()
  }
  #expect(try fixture.main() == main)
  #expect(try fixture.snapshot(state) == before)
}

@Test func reviewStalePreviewAndCancellationCannotPublishOrDetach() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  let id = try controller.list()[0].change.id
  let main = try fixture.main()
  let checkout = try controller.checkoutPreview()
  controller.isCancelled = { true }
  #expect(throws: (any Error).self) { try controller.confirmDetach(checkout) }
  #expect(try controller.checkoutPreview().isDetachRequired)
  controller.isCancelled = { false }
  try controller.confirmDetach(controller.checkoutPreview())
  let preview = try controller.preview(
    candidateID: id, clockDate: Date(timeIntervalSince1970: 1_783_036_799))
  controller.isCancelled = { true }
  #expect(throws: (any Error).self) { try controller.apply(preview) }
  #expect(try fixture.main() == main)
  controller.isCancelled = { false }
  #expect(throws: (any Error).self) { try controller.apply(preview) }
  let fresh = try controller.preview(
    candidateID: id, clockDate: Date(timeIntervalSince1970: 1_783_036_800))
  let git = Git(repo: fixture.memory, environment: [:])
  let tree = try git.text(["rev-parse", "\(main)^{tree}"])
  let next = try git.text(
    ["commit-tree", tree, "-p", main], input: Data("Synthetic external advance\n".utf8),
    additions: Git.proposalIdentity)
  _ = try git.data(["update-ref", "refs/heads/main", next, main])
  #expect(throws: (any Error).self) { try controller.apply(fresh) }
  #expect(try fixture.main() == next)
  #expect(try controller.list().allSatisfy { $0.disposition == .blocked })
}
