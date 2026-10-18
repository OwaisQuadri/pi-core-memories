import Darwin
import Foundation

struct MemoryError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

struct CommandResult {
  let status: Int32
  let output: Data
  let error: Data

  var text: String { String(decoding: output, as: UTF8.self) }
  var errorText: String { String(decoding: error, as: UTF8.self) }
}

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("pi-core-memories-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return url
}

func launch(_ process: Process) throws -> DispatchGroup {
  let exit = DispatchGroup()
  exit.enter()
  process.terminationHandler = { _ in exit.leave() }
  do {
    try process.run()
  } catch {
    exit.leave()
    throw error
  }
  return exit
}

func runCommand(
  executable: URL, arguments: [String], environment: [String: String], input: Data = Data()
) throws -> CommandResult {
  let scratch = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: scratch) }
  let inputURL = scratch.appendingPathComponent("stdin")
  let outputURL = scratch.appendingPathComponent("stdout")
  let errorURL = scratch.appendingPathComponent("stderr")
  try input.write(to: inputURL)
  try Data().write(to: outputURL)
  try Data().write(to: errorURL)
  let stdin = try FileHandle(forReadingFrom: inputURL)
  let stdout = try FileHandle(forWritingTo: outputURL)
  let stderr = try FileHandle(forWritingTo: errorURL)
  defer {
    try? stdin.close()
    try? stdout.close()
    try? stderr.close()
  }
  let process = Process()
  process.executableURL = executable
  process.arguments = arguments
  process.environment = environment
  process.standardInput = stdin
  process.standardOutput = stdout
  process.standardError = stderr
  try launch(process).wait()
  return try CommandResult(
    status: process.terminationStatus, output: Data(contentsOf: outputURL),
    error: Data(contentsOf: errorURL))
}

struct Git: Sendable {
  let repo: URL
  let environment: [String: String]

  init(repo: URL, environment: [String: String]) {
    self.repo = repo
    var sanitized = environment.filter { !$0.key.hasPrefix("GIT_") }
    sanitized["GIT_CONFIG_NOSYSTEM"] = "1"
    sanitized["GIT_CONFIG_GLOBAL"] = "/dev/null"
    sanitized["GIT_NO_REPLACE_OBJECTS"] = "1"
    sanitized["GIT_NO_LAZY_FETCH"] = "1"
    sanitized["GIT_OPTIONAL_LOCKS"] = "0"
    sanitized["LC_ALL"] = "C"
    self.environment = sanitized
  }

  func run(_ arguments: [String], input: Data = Data(), additions: [String: String] = [:]) throws
    -> CommandResult
  {
    try runCommand(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "-C", repo.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
        "-c", "core.fsmonitor=false",
      ] + arguments,
      environment: environment.merging(additions) { _, new in new }, input: input)
  }

  func directRefTransaction(_ commands: String, refs: [String], isolatedHead: String) throws
    -> CommandResult
  {
    try directRefTransaction(commands, refs: refs, isolatedHead: isolatedHead, enrollment: nil)
  }

  func enrollSavedRecovery(
    _ commands: String, refs: [String], isolatedHead: String,
    installCheckpoint: () throws -> Void
  ) throws -> CommandResult {
    try withoutActuallyEscaping(installCheckpoint) { enrollment in
      try directRefTransaction(
        commands, refs: refs, isolatedHead: isolatedHead, enrollment: enrollment)
    }
  }

  private func directRefTransaction(
    _ commands: String, refs: [String], isolatedHead: String,
    enrollment: (() throws -> Void)?
  ) throws -> CommandResult {
    guard [40, 64].contains(isolatedHead.utf8.count),
      isolatedHead.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      try text(["cat-file", "-t", isolatedHead]) == "commit",
      let common = try commonDirectory(), let resolved = realpath(common.path, nil)
    else { throw MemoryError("invalid isolated ref-transaction identity") }
    defer { free(resolved) }
    let commonPath = String(cString: resolved)
    guard !commonPath.contains("\n"), !commonPath.contains("\r") else {
      throw MemoryError("unsafe common-directory spelling")
    }
    let scratch = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let privateGit = scratch.appendingPathComponent("git")
    try FileManager.default.createDirectory(
      at: privateGit, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for (name, bytes) in [
      ("HEAD", Data((isolatedHead + "\n").utf8)),
      ("commondir", Data((commonPath + "\n").utf8)),
    ] {
      guard
        FileManager.default.createFile(
          atPath: privateGit.appendingPathComponent(name).path, contents: bytes,
          attributes: [.posixPermissions: 0o600])
      else { throw MemoryError("cannot create private Git identity") }
    }
    let errorURL = scratch.appendingPathComponent("stderr")
    guard
      FileManager.default.createFile(
        atPath: errorURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    else { throw MemoryError("cannot create private Git diagnostics") }
    let stderr = try FileHandle(forWritingTo: errorURL)
    defer { try? stderr.close() }
    let input = Pipe()
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = [
      "-C", repo.path, "--git-dir=\(privateGit.path)",
      "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
      "-c", "core.fsmonitor=false", "-c", "core.filesRefLockTimeout=5000",
      "update-ref", "--no-deref", "--stdin",
    ]
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = stderr
    let exit = try launch(process)
    defer {
      try? input.fileHandleForWriting.close()
      exit.wait()
      try? output.fileHandleForReading.close()
    }
    try input.fileHandleForWriting.write(contentsOf: Data("start\n\(commands)prepare\n".utf8))
    let prepared = Data("start: ok\nprepare: ok\n".utf8)
    var reply = Data()
    while reply.count < prepared.count {
      let bytes = try output.fileHandleForReading.read(upToCount: prepared.count - reply.count)
      guard let bytes, !bytes.isEmpty else { break }
      reply.append(bytes)
    }
    if reply == prepared {
      for ref in refs {
        let symbolic = try run(["symbolic-ref", "--quiet", ref])
        guard symbolic.status == 1 else {
          throw MemoryError("ref must be direct: \(ref)")
        }
      }
      try enrollment?()
      try input.fileHandleForWriting.write(contentsOf: Data("commit\n".utf8))
    }
    try input.fileHandleForWriting.close()
    reply.append(try output.fileHandleForReading.readToEnd() ?? Data())
    exit.wait()
    if process.terminationStatus == 0 && reply != prepared + Data("commit: ok\n".utf8) {
      throw MemoryError("Git did not commit the ref transaction")
    }
    return try CommandResult(
      status: process.terminationStatus, output: reply, error: Data(contentsOf: errorURL))
  }

  func data(_ arguments: [String], input: Data = Data(), additions: [String: String] = [:]) throws
    -> Data
  {
    let result = try run(arguments, input: input, additions: additions)
    guard result.status == 0 else {
      throw MemoryError(result.errorText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return result.output
  }

  func text(_ arguments: [String], input: Data = Data(), additions: [String: String] = [:]) throws
    -> String
  {
    String(decoding: try data(arguments, input: input, additions: additions), as: UTF8.self)
      .trimmingCharacters(in: .newlines)
  }

  func commonDirectory() throws -> URL? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw MemoryError("directory does not exist") }
    let result = try run(["rev-parse", "--path-format=absolute", "--git-common-dir"])
    if result.status != 0 {
      if result.errorText.contains("not a git repository") { return nil }
      throw MemoryError(result.errorText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return URL(fileURLWithPath: result.text.trimmingCharacters(in: .newlines))
  }

  func committedChangedPathBytes(from base: String, to target: String) throws -> Data {
    let scratch = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    return try data(
      ["diff-tree", "-r", "--no-renames", "--name-only", "-z", base, target],
      additions: ["GIT_INDEX_FILE": scratch.appendingPathComponent("index").path])
  }

  func reviewCheckout() throws -> ReviewCheckoutDirectory {
    try ReviewCheckoutDirectory(git: self)
  }

  static let proposalIdentity = [
    "GIT_AUTHOR_NAME": "pi-core-memories", "GIT_AUTHOR_EMAIL": "proposal@invalid",
    "GIT_COMMITTER_NAME": "pi-core-memories", "GIT_COMMITTER_EMAIL": "proposal@invalid",
    "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z",
  ]
}

final class ReviewCheckoutDirectory {
  let descriptor: Int32
  private let repositoryDescriptor: Int32
  private let git: Git
  private var headLock: Int32 = -1
  private var indexLock: Int32 = -1
  private var lease: ReviewCheckoutLease?
  private var leaseState: DreamStateDirectory?

  init(git: Git) throws {
    let repository = open(git.repo.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard repository >= 0 else { throw MemoryError("unsafe review checkout root") }
    let directory = openat(repository, ".git", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else {
      _ = close(repository)
      throw MemoryError("review requires a dedicated checkout")
    }
    do {
      var status = stat()
      guard fstat(directory, &status) == 0, status.st_uid == geteuid(),
        status.st_mode & 0o022 == 0,
        try git.text(["rev-parse", "--is-bare-repository"]) == "false",
        let common = try git.commonDirectory(), let commonPath = realpath(common.path, nil)
      else { throw MemoryError("unsafe review Git layout") }
      defer { free(commonPath) }
      var commonStatus = stat()
      guard lstat(commonPath, &commonStatus) == 0,
        commonStatus.st_dev == status.st_dev, commonStatus.st_ino == status.st_ino
      else { throw MemoryError("review refuses a linked checkout") }
      for name in ["objects", "refs"] {
        let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw MemoryError("unsafe review Git directory: \(name)") }
        defer { _ = close(child) }
        var childStatus = stat()
        guard fstat(child, &childStatus) == 0, childStatus.st_uid == geteuid(),
          childStatus.st_mode & 0o022 == 0
        else { throw MemoryError("unsafe review Git directory: \(name)") }
      }
      var configStatus = stat()
      guard fstatat(directory, "config", &configStatus, AT_SYMLINK_NOFOLLOW) == 0,
        configStatus.st_mode & S_IFMT == S_IFREG, configStatus.st_uid == geteuid(),
        configStatus.st_nlink == 1, configStatus.st_mode & 0o022 == 0
      else { throw MemoryError("unsafe review Git configuration") }
      for name in [
        "commondir", "shallow", "objects/info/alternates", "info/grafts", "info/sparse-checkout",
      ] {
        var fileStatus = stat()
        guard fstatat(directory, name, &fileStatus, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT
        else {
          throw MemoryError("unsupported review Git layout: \(name)")
        }
      }
      self.descriptor = directory
      self.repositoryDescriptor = repository
      self.git = git
    } catch {
      _ = close(repository)
      _ = close(directory)
      throw error
    }
  }

  deinit {
    releaseLock(indexLock, name: "index.lock")
    releaseLock(headLock, name: "HEAD.lock")
    if let lease, let leaseState {
      try? removeLease(lease, state: leaseState)
    }
    _ = close(repositoryDescriptor)
    _ = close(descriptor)
  }

  func withLeaseState<T>(_ operation: (DreamStateDirectory) throws -> T) throws -> T {
    guard let resolved = realpath(git.repo.path, nil) else {
      throw MemoryError("cannot resolve memory checkout for private leases")
    }
    defer { free(resolved) }
    let stateURL = URL(fileURLWithPath: String(cString: resolved))
      .appendingPathComponent(".git/memory-management")
    let state = try DreamStateDirectory.openRoot(stateURL)
    var parent = stat()
    var held = stat()
    guard fstatat(state.descriptor, "..", &parent, AT_SYMLINK_NOFOLLOW) == 0,
      fstat(descriptor, &held) == 0,
      parent.st_dev == held.st_dev, parent.st_ino == held.st_ino
    else { throw MemoryError("memory checkout changed before lease acquisition") }
    let ownership = try state.openLock()
    defer {
      _ = flock(ownership.descriptor, LOCK_UN)
      _ = close(ownership.descriptor)
    }
    guard flock(ownership.descriptor, LOCK_EX | LOCK_NB) == 0 else { throw DreamRunError.busy }
    try state.verifyLock(ownership.descriptor)
    try recoverLease(state: state)
    return try operation(state)
  }

  func lock(state: DreamStateDirectory, detachedHead: Data) throws {
    guard headLock < 0, indexLock < 0, lease == nil else {
      throw MemoryError("checkout lock already held")
    }
    let identity = UUID()
    let headName = anchorName(identity, lock: "HEAD.lock")
    let indexName = anchorName(identity, lock: "index.lock")
    guard try !state.isPresent("checkout-lease.json") else {
      throw MemoryError("checkout lease already exists")
    }
    defer {
      if lease == nil {
        releaseLock(indexLock, name: indexName)
        releaseLock(headLock, name: headName)
        indexLock = -1
        headLock = -1
      }
    }
    headLock = try acquireLock(headName)
    indexLock = try acquireLock(indexName)
    var directory = stat()
    var head = stat()
    var index = stat()
    guard fstat(descriptor, &directory) == 0, fstat(headLock, &head) == 0,
      fstat(indexLock, &index) == 0, fsync(headLock) == 0, fsync(indexLock) == 0,
      fsync(descriptor) == 0
    else { throw DreamRunError.persistenceFailure }
    let value = ReviewCheckoutLease(
      owner: getpid(), identity: identity,
      gitDevice: UInt64(directory.st_dev), gitInode: UInt64(directory.st_ino),
      headDevice: UInt64(head.st_dev), headInode: UInt64(head.st_ino),
      indexDevice: UInt64(index.st_dev), indexInode: UInt64(index.st_ino),
      detachedHead: detachedHead)
    lease = value
    leaseState = state
    try state.installReviewFile(MemoryReviewEncoding.encode(value), name: "checkout-lease.json")
    guard linkat(descriptor, headName, descriptor, "HEAD.lock", 0) == 0,
      linkat(descriptor, indexName, descriptor, "index.lock", 0) == 0,
      fsync(descriptor) == 0
    else { throw MemoryError("checkout has an existing or unavailable Git lock") }
  }

  func recoverLease(state: DreamStateDirectory) throws {
    guard try state.isPresent("checkout-lease.json") else { return }
    let value = try MemoryReviewEncoding.decode(
      ReviewCheckoutLease.self,
      bytes: state.read("checkout-lease.json", maximum: MemoryReviewEncoding.maximumFileBytes))
    guard [41, 65].contains(value.detachedHead.count), value.detachedHead.last == 10,
      value.detachedHead.dropLast().allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }
      ),
      value.owner > 0, value.owner != getpid(), kill(value.owner, 0) == -1,
      errno == ESRCH
    else { throw MemoryError("checkout lease owner is not proven dead") }
    try removeLease(value, state: state)
  }

  private func anchorName(_ identity: UUID, lock: String) -> String {
    "memory-review-\(identity.uuidString)-\(lock)"
  }

  private func removeLease(_ value: ReviewCheckoutLease, state: DreamStateDirectory) throws {
    var directory = stat()
    guard
      try state.read("checkout-lease.json", maximum: MemoryReviewEncoding.maximumFileBytes)
        == MemoryReviewEncoding.encode(value),
      fstat(descriptor, &directory) == 0,
      UInt64(directory.st_dev) == value.gitDevice, UInt64(directory.st_ino) == value.gitInode
    else { throw MemoryError("checkout lease directory changed") }
    var removals: [(String, UInt64, UInt64)] = []
    for (name, device, inode, allowed) in [
      ("HEAD.lock", value.headDevice, value.headInode, [value.detachedHead]),
      ("index.lock", value.indexDevice, value.indexInode, [Data()]),
    ] {
      let anchor = anchorName(value.identity, lock: name)
      var present: [String] = []
      for path in [anchor, name] {
        var status = stat()
        if fstatat(descriptor, path, &status, AT_SYMLINK_NOFOLLOW) != 0 {
          guard errno == ENOENT else { throw MemoryError("cannot inspect checkout lease") }
          continue
        }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(),
          status.st_mode & 0o777 == 0o600,
          UInt64(status.st_dev) == device, UInt64(status.st_ino) == inode
        else { throw MemoryError("foreign or changed checkout lock: \(path)") }
        present.append(path)
      }
      if !present.isEmpty {
        guard present.contains(anchor) else { throw MemoryError("checkout lock anchor is missing") }
        let file = openat(descriptor, anchor, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw MemoryError("cannot inspect checkout lock anchor") }
        defer { _ = close(file) }
        var renamed = stat()
        let isRenamed =
          name == "HEAD.lock"
          && fstatat(descriptor, "HEAD", &renamed, AT_SYMLINK_NOFOLLOW) == 0
          && UInt64(renamed.st_dev) == device && UInt64(renamed.st_ino) == inode
        var status = stat()
        guard fstat(file, &status) == 0, UInt64(status.st_dev) == device,
          UInt64(status.st_ino) == inode,
          status.st_nlink == present.count + (isRenamed ? 1 : 0), status.st_size >= 0,
          status.st_size <= value.detachedHead.count
        else { throw MemoryError("checkout lock anchor contents or links changed") }
        let bytes =
          try FileHandle(fileDescriptor: file, closeOnDealloc: false).readToEnd() ?? Data()
        guard
          allowed.contains(bytes)
            || (name == "HEAD.lock" && !isRenamed && value.detachedHead.starts(with: bytes))
        else { throw MemoryError("checkout lock anchor contents changed") }
      }
      removals += present.reversed().map { ($0, device, inode) }
    }
    for (name, device, inode) in removals {
      var status = stat()
      guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
        UInt64(status.st_dev) == device, UInt64(status.st_ino) == inode,
        unlinkat(descriptor, name, 0) == 0
      else { throw MemoryError("checkout lease changed during cleanup") }
    }
    guard fsync(descriptor) == 0,
      unlinkat(state.descriptor, "checkout-lease.json", 0) == 0, fsync(state.descriptor) == 0
    else { throw DreamRunError.persistenceFailure }
  }

  func witness(isLocked: Bool = false) throws -> ReviewCheckoutWitness {
    if !isLocked {
      for name in ["HEAD.lock", "index.lock"] {
        var status = stat()
        guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
          throw MemoryError(
            "checkout has an existing \(name); do not remove unknown locks automatically. For a legacy native review lease, reopen /mem-review with its original explicit configuration."
          )
        }
      }
    } else {
      try verifyHeldLock(headLock, name: "HEAD.lock")
      try verifyHeldLock(indexLock, name: "index.lock")
    }
    let head = try read("HEAD")
    let commit = try git.text(["rev-parse", "--verify", "HEAD^{commit}"])
    let main = try git.text(["rev-parse", "--verify", "refs/heads/main^{commit}"])
    guard try git.run(["symbolic-ref", "--quiet", "refs/heads/main"]).status == 1 else {
      throw MemoryError("approved main must be a direct ref")
    }
    let snapshot = try MemoryStore(repo: git.repo, environment: git.environment).reviewSnapshot(
      base: commit)
    for document in snapshot.documents {
      let components = document.path.split(separator: "/").map(String.init)
      var directory = repositoryDescriptor
      var opened: [Int32] = []
      defer { for file in opened { _ = close(file) } }
      for component in components.dropLast() {
        let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw MemoryError("unsafe tracked memory directory") }
        opened.append(next)
        directory = next
      }
      guard try read(components.last!, directory: directory) == document.bytes else {
        throw MemoryError("tracked checkout bytes changed")
      }
    }
    guard head == Data("ref: refs/heads/main\n".utf8) || head == Data((commit + "\n").utf8) else {
      throw MemoryError("review requires main or a detached HEAD")
    }
    let worktrees = try git.text(["worktree", "list", "--porcelain"])
    let mainUses = worktrees.split(separator: "\n").filter { $0 == "branch refs/heads/main" }.count
    guard mainUses == (head == Data("ref: refs/heads/main\n".utf8) ? 1 : 0) else {
      throw MemoryError("another worktree uses main")
    }
    let url = git.repo.appendingPathComponent(".git")
    let sharedNames = try FileManager.default.contentsOfDirectory(atPath: url.path)
      .filter { $0.hasPrefix("sharedindex.") }.sorted()
    guard sharedNames.count <= 128 else { throw MemoryError("too many shared indexes") }
    var shared: [String: Data] = [:]
    var total = 0
    for name in sharedNames {
      let bytes = try read(name)
      total += bytes.count
      guard total <= MemoryReviewEncoding.maximumFileBytes else {
        throw DreamRunError.limitExceeded
      }
      shared[name] = bytes
    }
    let index = try read("index")
    let config = try read("config")
    try verifyCleanStatus(commit: commit, index: index, config: config, shared: shared)
    guard try read("HEAD") == head, try read("index") == index, try read("config") == config,
      try git.text(["rev-parse", "--verify", "HEAD^{commit}"]) == commit,
      try git.text(["rev-parse", "--verify", "refs/heads/main^{commit}"]) == main,
      try shared.allSatisfy({ try read($0.key) == $0.value })
    else { throw MemoryError("checkout changed while collecting its witness") }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw MemoryError("lost checkout directory") }
    return ReviewCheckoutWitness(
      gitDevice: UInt64(status.st_dev), gitInode: UInt64(status.st_ino), head: head,
      commit: commit, main: main, index: index, config: config, sharedIndexes: shared)
  }

  func detach(_ expected: ReviewCheckoutWitness) throws {
    guard headLock >= 0, indexLock >= 0,
      expected.head == Data("ref: refs/heads/main\n".utf8),
      try witness(isLocked: true) == expected
    else { throw MemoryError("stale checkout preview") }
    let bytes = Data((expected.commit + "\n").utf8)
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(headLock, buffer.baseAddress! + offset, buffer.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw MemoryError("cannot write detached HEAD") }
        offset += count
      }
    }
    guard fsync(headLock) == 0 else { throw MemoryError("cannot synchronize detached HEAD lock") }
    try verifyHeldLock(headLock, name: "HEAD.lock", expected: bytes)
    try verifyHeldLock(indexLock, name: "index.lock")
    guard renameat(descriptor, "HEAD.lock", descriptor, "HEAD") == 0
    else { throw MemoryError("cannot install detached HEAD") }
    guard fsync(descriptor) == 0 else {
      throw MemoryReviewMutationFailure(
        mutation: .detached, commit: expected.commit, auditRef: nil,
        followUpFailure: "cannot synchronize detached HEAD")
    }
    _ = close(headLock)
    headLock = -1
  }

  private func verifyCleanStatus(commit: String, index: Data, config: Data, shared: [String: Data])
    throws
  {
    let scratch = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let common = try git.commonDirectory(), let resolved = realpath(common.path, nil) else {
      throw MemoryError("cannot locate checkout common directory")
    }
    defer { free(resolved) }
    var files = shared
    files["HEAD"] = Data((commit + "\n").utf8)
    let commonPath = String(cString: resolved)
    guard !commonPath.contains("\n"), !commonPath.contains("\r") else {
      throw MemoryError("unsafe checkout common-directory spelling")
    }
    files["index"] = index
    files["config"] = config
    for name in ["objects", "refs"] {
      try FileManager.default.createDirectory(
        at: scratch.appendingPathComponent(name), withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    for (name, bytes) in files {
      guard
        FileManager.default.createFile(
          atPath: scratch.appendingPathComponent(name).path, contents: bytes,
          attributes: [.posixPermissions: 0o600])
      else { throw MemoryError("cannot create private checkout index witness") }
    }
    let status = try git.data(
      [
        "--git-dir=\(scratch.path)", "--work-tree=\(git.repo.path)",
        "status", "--porcelain=v1", "--untracked-files=all", "--ignored=matching",
      ],
      additions: [
        "GIT_INDEX_FILE": scratch.appendingPathComponent("index").path,
        "GIT_OBJECT_DIRECTORY": commonPath + "/objects",
      ])
    guard status.isEmpty else {
      throw MemoryError("review requires clean tracked and untracked files")
    }
  }

  private func read(_ name: String, directory: Int32? = nil) throws -> Data {
    let file = openat(directory ?? descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard file >= 0 else { throw MemoryError("missing checkout witness: \(name)") }
    defer { _ = close(file) }
    var status = stat()
    guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(), status.st_nlink == 1, status.st_mode & 0o022 == 0,
      status.st_size >= 0, status.st_size <= MemoryReviewEncoding.maximumFileBytes
    else { throw MemoryError("unsafe checkout witness: \(name)") }
    let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
    var bytes = Data()
    while bytes.count <= status.st_size {
      let next = try handle.read(upToCount: Int(status.st_size) + 1 - bytes.count) ?? Data()
      if next.isEmpty { break }
      bytes.append(next)
    }
    guard bytes.count == status.st_size else { throw MemoryError("checkout witness changed") }
    return bytes
  }

  private func verifyHeldLock(_ file: Int32, name: String, expected: Data = Data()) throws {
    var held = stat()
    var named = stat()
    guard file >= 0, fstat(file, &held) == 0,
      fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      held.st_dev == named.st_dev, held.st_ino == named.st_ino,
      held.st_uid == geteuid(), held.st_mode & S_IFMT == S_IFREG,
      held.st_mode & 0o777 == 0o600, held.st_nlink == 2, held.st_size == expected.count
    else { throw MemoryError("checkout lock identity or size changed: \(name)") }
    var bytes = [UInt8](repeating: 0, count: expected.count + 1)
    var count: Int
    repeat {
      count = bytes.withUnsafeMutableBytes {
        Darwin.pread(file, $0.baseAddress, $0.count, 0)
      }
    } while count < 0 && errno == EINTR
    guard count == expected.count, Data(bytes.prefix(max(0, count))) == expected else {
      throw MemoryError("checkout lock contents changed: \(name)")
    }
  }

  private func acquireLock(_ name: String) throws -> Int32 {
    let file = openat(
      descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw MemoryError("checkout has an existing \(name)") }
    return file
  }

  private func releaseLock(_ file: Int32, name: String) {
    guard file >= 0 else { return }
    var held = stat()
    var named = stat()
    if fstat(file, &held) == 0, fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      held.st_dev == named.st_dev, held.st_ino == named.st_ino
    {
      _ = unlinkat(descriptor, name, 0)
    }
    _ = close(file)
  }
}
