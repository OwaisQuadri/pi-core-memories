import Darwin
import Foundation

final class ReviewGitObjects {
  struct Header: Equatable {
    let oid: String
    let type: String
    let size: Int

    init(_ bytes: Data, oid: String) throws {
      let fields = String(decoding: bytes, as: UTF8.self).split(separator: " ")
      guard fields.count == 3, fields[0] == oid,
        ["blob", "tree", "commit", "tag"].contains(fields[1]),
        fields[2].utf8.allSatisfy({ (48...57).contains($0) }),
        let size = Int(fields[2]), size >= 0
      else { throw DreamRunError.corruption }
      self.oid = oid
      self.type = String(fields[1])
      self.size = size
    }
  }

  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let exit: DispatchGroup
  private var isClosed = false

  init(git: Git) throws {
    let input = Pipe()
    let output = Pipe()
    guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
      throw DreamRunError.corruption
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = [
      "-C", git.repo.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
      "-c", "core.fsmonitor=false", "cat-file", "--batch-command",
    ]
    process.environment = git.environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    self.process = process
    self.input = input.fileHandleForWriting
    self.output = output.fileHandleForReading
    self.exit = try launch(process)
    try? input.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
  }

  deinit { close() }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    try? input.close()
    try? output.close()
    if exit.wait(timeout: .now() + 1) == .timedOut {
      _ = kill(process.processIdentifier, SIGKILL)
      exit.wait()
    }
  }

  func info(_ oid: String) throws -> Header {
    try request("info", oid: oid) { deadline in
      try header(oid: oid, deadline: deadline)
    }
  }

  func contents(_ oid: String, type: String, maximumBytes: Int) throws -> Data {
    let expected = try info(oid)
    guard expected.type == type else {
      close()
      throw DreamRunError.corruption
    }
    guard expected.size <= maximumBytes else {
      close()
      throw DreamRunError.limitExceeded
    }
    return try request("contents", oid: oid) { deadline in
      let actual = try header(oid: oid, deadline: deadline)
      guard actual == expected else { throw DreamRunError.corruption }
      let bytes = try read(actual.size, deadline: deadline)
      guard try read(1, deadline: deadline) == Data([10]) else {
        throw DreamRunError.corruption
      }
      return bytes
    }
  }

  private func request<T>(
    _ command: String, oid: String, read: (ContinuousClock.Instant) throws -> T
  ) throws -> T {
    do {
      guard !isClosed, [40, 64].contains(oid.utf8.count),
        oid.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw DreamRunError.corruption }
      try input.write(contentsOf: Data("\(command) \(oid)\n".utf8))
      return try read(.now.advanced(by: .seconds(30)))
    } catch {
      close()
      throw error
    }
  }

  private func header(oid: String, deadline: ContinuousClock.Instant) throws -> Header {
    var bytes = Data()
    while bytes.count < 128 {
      let byte = try read(1, deadline: deadline)
      if byte == Data([10]) { return try Header(bytes, oid: oid) }
      bytes.append(byte)
    }
    throw DreamRunError.corruption
  }

  private func read(_ count: Int, deadline: ContinuousClock.Instant) throws -> Data {
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: min(count, 65_536))
    while bytes.count < count {
      let duration = ContinuousClock.now.duration(to: deadline)
      guard duration > .zero else { throw DreamRunError.corruption }
      let remaining = duration.components
      let milliseconds = min(
        30_000, remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000 + 1)
      var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
      let ready = poll(&descriptor, 1, Int32(milliseconds))
      if ready < 0 && errno == EINTR { continue }
      guard ready > 0 else { throw DreamRunError.corruption }
      let received = Darwin.read(
        output.fileDescriptor, &buffer, min(buffer.count, count - bytes.count))
      if received < 0 && errno == EINTR { continue }
      guard received > 0 else { throw DreamRunError.corruption }
      bytes.append(contentsOf: buffer.prefix(received))
    }
    return bytes
  }
}
