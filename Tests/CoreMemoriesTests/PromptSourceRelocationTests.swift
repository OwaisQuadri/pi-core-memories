import Darwin
import Foundation
import Testing

@testable import CoreMemories

private struct PromptRelocationFixture {
  let transaction: TransactionFixture
  let prompts: URL
  let replacement: URL
  let roles: DreamSourceRoles
  let baselineRunID: String

  init(
    isSnippetsPresent: Bool = true, isCompleted: Bool = true,
    definitionBody: String = dreamPrompt, promptsName: String = "arbitrary-old-definitions"
  ) throws {
    let fixture = try TransactionFixture()
    transaction = fixture
    prompts = fixture.root.appendingPathComponent(promptsName)
    replacement = fixture.root.appendingPathComponent("replacement-definitions")
    roles = DreamSourceRoles(isSnippetsPresent: isSnippetsPresent, isPromptsPresent: true)
    let definition = "---\ndescription: Synthetic review\n---\n\n" + definitionBody + "\n"
    for folder in [prompts, replacement] {
      try fixture.write(definition, file: folder.appendingPathComponent("review.md"))
    }
    try fixture.populate()
    let store = try DreamRunStore(
      stateRoot: fixture.state, sessionsRoot: fixture.sessions,
      memoryRepository: fixture.memory,
      strippingRoots: (isSnippetsPresent ? [fixture.snippets] : []) + [prompts])
    let result = try store.run(
      selection: fixture.selection, sourceRoles: roles,
      prepare: { progress, sources in
        try SessionReader(
          sessions: sources.sessions, snippets: sources.snippets,
          prompts: sources.prompts, environment: [:]
        ).prepare(progress: progress, limits: DreamInputLimits())
      },
      call: { request in
        if !isCompleted { throw CancellationError() }
        return try transactionAdd(request)
      })
    switch result {
    case .completed(let report): baselineRunID = report.runID
    case .pending(let report): baselineRunID = report.runID
    default: throw MemoryError("expected captured relocation baseline")
    }
    try FileManager.default.removeItem(at: prompts)
  }

  func store() throws -> DreamRunStore {
    try DreamRunStore(
      stateRoot: transaction.state, sessionsRoot: transaction.sessions,
      memoryRepository: transaction.memory,
      strippingRoots: (roles.isSnippetsPresent ? [transaction.snippets] : []) + [prompts])
  }

  func preview(_ store: DreamRunStore? = nil) throws -> PromptRelocationPreview {
    try (store ?? self.store()).previewPromptRelocation(
      baselineRunID: baselineRunID,
      replacement: replacement, sourceRoles: roles)
  }

  func confirm(_ preview: PromptRelocationPreview, store: DreamRunStore? = nil) throws {
    _ = try (store ?? self.store()).confirmPromptRelocation(
      baselineRunID: baselineRunID,
      replacement: replacement, sourceRoles: roles,
      expectedPreviewHash: #require(preview.previewHash), authorization: .explicitCaller)
  }

  func run(
    _ store: DreamRunStore? = nil,
    call: (DreamModelRequest) throws -> DreamCompletedResponse = transactionNotes
  ) throws -> DreamTransactionResult {
    try (store ?? self.store()).run(
      selection: transaction.selection, sourceRoles: roles,
      prepare: { progress, sources in
        try SessionReader(
          sessions: sources.sessions, snippets: sources.snippets,
          prompts: sources.prompts, environment: [:]
        ).prepare(progress: progress, limits: DreamInputLimits())
      }, call: call)
  }

  var configuration: MemoryConfiguration {
    var config = queueConfiguration(transaction)
    config.roots?.snippets = roles.isSnippetsPresent ? transaction.snippets.path : nil
    config.roots?.prompts = prompts.path
    return config
  }

  var recordURL: URL { transaction.state.appendingPathComponent("prompt-relocation.json") }
}

struct PromptSourceRelocationTests {
  @Test(arguments: [false, true])
  func previewAndConfirmationPreserveHistoricalReviewAndManualAuthority(isSnippetsPresent: Bool)
    throws
  {
    let relocation = try PromptRelocationFixture(isSnippetsPresent: isSnippetsPresent)
    let fixture = relocation.transaction
    defer { fixture.clean() }
    let store = try relocation.store()
    let binding = try store.reviewSourceBinding()
    let review = try MemoryReviewController(
      repository: fixture.memory,
      stateRoot: URL(fileURLWithPath: relocation.configuration.reviewState), sources: store,
      environment: [:])
    let candidate = try #require(review.list().first)
    try review.deferCandidate(candidateID: candidate.change.id)
    let deferred = try #require(review.list().first)
    #expect(deferred.change.id == candidate.change.id && deferred.disposition == .deferred)
    #expect(try review.selection(candidate.change.id.rawValue) == .deferred)
    let drafts = try MemoryDraftStore(
      repository: fixture.memory,
      journal: URL(fileURLWithPath: relocation.configuration.journal))
    let main = try fixture.main()
    let draft = try drafts.create(
      base: main,
      operations: [
        MemoryManagementRequest(
          operation: .add, base: main, path: "MEMORY.md", replacement: fact("Keep manual intent."),
          reason: "Synthetic intent")
      ])
    let git = Git(repo: fixture.memory, environment: [:])
    let refs = try git.data(["for-each-ref", "--format=%(refname) %(objectname)"])
    let history = try DreamRunEncoding.encode(DreamInspection.read(stateRoot: fixture.state))
    let before = try fixture.snapshot(fixture.root)
    let preview = try relocation.preview(store)
    #expect(preview.isCompatible && preview.mismatches.isEmpty)
    #expect(preview.baseline.runID == relocation.baselineRunID)
    #expect(preview.baselineInventory.entryCount == 1)
    #expect(preview.baselineInventory == preview.replacementInventory)
    #expect(preview.roles == relocation.roles)
    #expect(preview.coverage.isCompleted && !preview.coverage.isNewerCompletedCapturePresent)
    #expect(try fixture.snapshot(fixture.root) == before)
    try fixture.advance()
    let advancedMain = try fixture.main()
    let advancedRefs = try git.data(["for-each-ref", "--format=%(refname) %(objectname)"])
    #expect(advancedMain != main && advancedRefs != refs)
    let blockedBeforeConfirmation = try #require(review.list().first)
    #expect(blockedBeforeConfirmation.change.id == candidate.change.id)
    #expect(blockedBeforeConfirmation.disposition == .blocked)
    #expect(
      blockedBeforeConfirmation.limitation
        == "main contains changes outside verified memory publications")
    #expect(try review.selection(candidate.change.id.rawValue) == .deferred)
    let confirmationBefore = try fixture.snapshot(fixture.root)
    try relocation.confirm(preview, store: store)
    var after = try fixture.snapshot(fixture.root)
    let installedRecord = after.removeValue(forKey: relocation.recordURL.path)
    let record = try #require(installedRecord)
    #expect(after == confirmationBefore)
    #expect(record.bytes.count <= 1_048_576)
    var metadata = stat()
    #expect(lstat(relocation.recordURL.path, &metadata) == 0)
    #expect(
      metadata.st_mode & 0o7777 == 0o600 && metadata.st_nlink == 1 && metadata.st_uid == geteuid())
    #expect(try store.reviewSourceBinding() == binding)
    #expect(try relocation.store().reviewSourceBinding() == binding)
    #expect(store.acceptedSources.stripping.last == relocation.prompts)
    #expect(try fixture.main() == advancedMain)
    #expect(try git.data(["for-each-ref", "--format=%(refname) %(objectname)"]) == advancedRefs)
    #expect(try DreamRunEncoding.encode(DreamInspection.read(stateRoot: fixture.state)) == history)
    let blockedAfterConfirmation = try #require(review.list().first)
    #expect(blockedAfterConfirmation.change.id == candidate.change.id)
    #expect(blockedAfterConfirmation.disposition == blockedBeforeConfirmation.disposition)
    #expect(blockedAfterConfirmation.limitation == blockedBeforeConfirmation.limitation)
    #expect(
      blockedAfterConfirmation.frozenLimitations == blockedBeforeConfirmation.frozenLimitations)
    #expect(try review.selection(candidate.change.id.rawValue) == .deferred)
    #expect(try drafts.read(draft.draftID, revision: draft.revision).operations.count == 1)
    guard case .noNewRecords(let generation, _) = try relocation.run() else {
      throw MemoryError("durable mapping did not resolve fresh preparation")
    }
    #expect(generation == 1)
    #expect(
      DreamQueueSnapshot.read(configuration: relocation.configuration).coverage?.segments != nil)
    #expect(throws: (any Error).self) { try relocation.confirm(preview) }
    #expect(throws: (any Error).self) {
      try relocation.store().run(
        selection: fixture.selection,
        prepare: transactionUncalledPrepare, call: transactionUncalled)
    }
  }

  @Test(arguments: ["missing", "extra", "renamed", "frontmatter", "body", "empty", "invalidUTF8"])
  func completeRawInventoryMismatchCannotAuthorizeConfirmation(_ variant: String) throws {
    let relocation = try PromptRelocationFixture()
    let fixture = relocation.transaction
    defer { fixture.clean() }
    let definition = relocation.replacement.appendingPathComponent("review.md")
    switch variant {
    case "missing": try FileManager.default.removeItem(at: definition)
    case "extra":
      try fixture.write(
        "Extra template", file: relocation.replacement.appendingPathComponent("extra.md"))
    case "renamed":
      try FileManager.default.moveItem(
        at: definition, to: relocation.replacement.appendingPathComponent("renamed.md"))
    case "frontmatter":
      let bytes = try String(contentsOf: definition, encoding: .utf8)
      try fixture.write(
        bytes.replacingOccurrences(of: "Synthetic review", with: "Changed review"), file: definition
      )
    case "body": try fixture.write("Changed template body", file: definition)
    case "empty": try fixture.write(" \n", file: definition)
    default: try Data([0xff]).write(to: definition)
    }
    let before = try fixture.snapshot(fixture.root)
    if variant == "empty" || variant == "invalidUTF8" {
      #expect(throws: (any Error).self) { try relocation.preview() }
    } else {
      let preview = try relocation.preview()
      #expect(!preview.isCompatible && preview.previewHash == nil && !preview.mismatches.isEmpty)
    }
    #expect(throws: (any Error).self) {
      try relocation.store().confirmPromptRelocation(
        baselineRunID: relocation.baselineRunID,
        replacement: relocation.replacement, sourceRoles: relocation.roles,
        expectedPreviewHash: String(repeating: "0", count: 64), authorization: .explicitCaller)
    }
    #expect(try fixture.snapshot(fixture.root) == before)
  }

  @Test(arguments: [
    "targetBytes", "targetPath", "head", "admission", "revival", "storeIdentity",
    "repositoryIdentity", "record",
  ])
  func stalePreviewCannotInstallARecord(_ variant: String) throws {
    let relocation = try PromptRelocationFixture()
    let fixture = relocation.transaction
    defer { fixture.clean() }
    let store = try relocation.store()
    let preview = try relocation.preview(store)
    var target = relocation.replacement
    switch variant {
    case "targetBytes":
      try fixture.write("Changed", file: target.appendingPathComponent("review.md"))
    case "targetPath":
      target = fixture.root.appendingPathComponent("other-target")
      try FileManager.default.copyItem(at: relocation.replacement, to: target)
    case "head", "admission":
      try FileManager.default.copyItem(at: relocation.replacement, to: relocation.prompts)
      try fixture.append(dreamUser("next", nil, dreamOld, "Another preference.") + "\n")
      if variant == "head" {
        _ = try relocation.run()
      } else {
        _ = try relocation.run(call: { _ in throw CancellationError() })
      }
      try FileManager.default.removeItem(at: relocation.prompts)
    case "revival": try FileManager.default.copyItem(at: target, to: relocation.prompts)
    case "storeIdentity":
      try FileManager.default.moveItem(
        at: fixture.state, to: fixture.root.appendingPathComponent("old-state"))
      try FileManager.default.createDirectory(
        at: fixture.state, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    case "repositoryIdentity":
      let saved = fixture.root.appendingPathComponent("old-repository")
      try FileManager.default.moveItem(at: fixture.memory, to: saved)
      try FileManager.default.copyItem(at: saved, to: fixture.memory)
    default: try relocation.confirm(preview, store: store)
    }
    let before = try fixture.snapshot(fixture.root)
    #expect(throws: (any Error).self) {
      try store.confirmPromptRelocation(
        baselineRunID: relocation.baselineRunID,
        replacement: target, sourceRoles: relocation.roles,
        expectedPreviewHash: #require(preview.previewHash), authorization: .explicitCaller)
    }
    #expect(try fixture.snapshot(fixture.root) == before)
  }

  @Test(arguments: [false, true])
  func explicitAdmittedAndNonlatestCompletedBaselinesHaveBoundedCoverage(isCompleted: Bool) throws {
    let relocation = try PromptRelocationFixture(isCompleted: isCompleted)
    let fixture = relocation.transaction
    defer { fixture.clean() }
    if isCompleted {
      try FileManager.default.copyItem(at: relocation.replacement, to: relocation.prompts)
      try fixture.write(
        "Different later template", file: relocation.prompts.appendingPathComponent("review.md"))
      try fixture.write(
        "---\nname: changed\n---\n\nChanged snippet",
        file: fixture.snippets.appendingPathComponent("strip.md"))
      try fixture.append(dreamUser("next", nil, dreamOld, "Another preference.") + "\n")
      _ = try relocation.run()
      try FileManager.default.removeItem(at: relocation.prompts)
    }
    let preview = try relocation.preview()
    #expect(preview.isCompatible)
    #expect(preview.coverage.isCompleted == isCompleted)
    #expect(preview.coverage.isNewerCompletedCapturePresent == isCompleted)
    #expect(preview.coverage.differingInventories.count == (isCompleted ? 1 : 0))
    #expect(preview.coverage.claim == "complete-template-subset-of-selected-input-only")
    try relocation.confirm(preview)
    if !isCompleted {
      _ = try transactionPending(
        relocation.store().run(
          selection: fixture.selection,
          prepare: transactionUncalledPrepare, call: transactionUncalled), reason: .interruptedCall)
    }
  }

  @Test func orphanInputAndForgedCacheCannotNominateABaseline() throws {
    let relocation = try PromptRelocationFixture()
    let fixture = relocation.transaction
    defer { fixture.clean() }
    let orphanID = UUID().uuidString.lowercased()
    try FileManager.default.copyItem(
      at: fixture.state.appendingPathComponent("runs/\(relocation.baselineRunID)"),
      to: fixture.state.appendingPathComponent("runs/\(orphanID)"))
    let bytes = try Data(contentsOf: fixture.state.appendingPathComponent("state.json"))
    var state = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    state["runID"] = orphanID
    state["admissionHash"] = String(repeating: "0", count: 64)
    try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(
      to: fixture.state.appendingPathComponent("state.json"))
    let before = try fixture.snapshot(fixture.root)
    #expect(throws: (any Error).self) {
      try relocation.store().previewPromptRelocation(
        baselineRunID: orphanID,
        replacement: relocation.replacement, sourceRoles: relocation.roles)
    }
    #expect(try fixture.snapshot(fixture.root) == before)
  }

  @Test(arguments: [
    "beforeWrite", "beforeFileSync", "beforeInstall", "afterInstall", "beforeDirectorySync",
  ])
  func persistenceFailureNeverReportsSuccessfulConfirmation(_ variant: String) throws {
    let relocation = try PromptRelocationFixture()
    let fixture = relocation.transaction
    defer { fixture.clean() }
    let store = try relocation.store()
    let preview = try relocation.preview(store)
    let before = try fixture.snapshot(fixture.root)
    store.persistenceFault = { event in
      let name = "prompt-relocation.json"
      let expected: DreamPersistenceEvent
      switch variant {
      case "beforeWrite": expected = .beforeWrite(name)
      case "beforeFileSync": expected = .beforeFileSync(name)
      case "beforeInstall": expected = .beforeInstall(name)
      case "afterInstall": expected = .afterInstall(name)
      default: expected = .beforeDirectorySync(name)
      }
      if event == expected { throw CancellationError() }
    }
    #expect(throws: DreamRunError.persistenceFailure) {
      try relocation.confirm(preview, store: store)
    }
    var after = try fixture.snapshot(fixture.root)
    after.removeValue(forKey: relocation.recordURL.path)
    #expect(after == before)
    if variant == "afterInstall" || variant == "beforeDirectorySync" {
      #expect(DreamQueueSnapshot.read(configuration: relocation.configuration).coverage != nil)
    } else {
      #expect(!FileManager.default.fileExists(atPath: relocation.recordURL.path))
    }
  }

  @Test(arguments: [
    "malformed", "unsupported", "wrongMode", "hardLink", "symlink", "oversize", "absent",
    "unreadable",
  ])
  func frozenReplayAndManualUseIgnoreUnsafeOptionalRelocation(_ variant: String) throws {
    let relocation = try PromptRelocationFixture()
    let fixture = relocation.transaction
    defer { fixture.clean() }
    try relocation.confirm(relocation.preview())
    let history = try DreamRunEncoding.encode(DreamInspection.read(stateRoot: fixture.state))
    let record = relocation.recordURL
    switch variant {
    case "malformed": try Data("{".utf8).write(to: record)
    case "unsupported":
      let bytes = try String(contentsOf: record, encoding: .utf8)
      try Data(
        bytes.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99").utf8
      ).write(to: record)
    case "wrongMode": #expect(chmod(record.path, 0o644) == 0)
    case "unreadable": #expect(chmod(record.path, 0o000) == 0)
    case "hardLink":
      #expect(link(record.path, fixture.root.appendingPathComponent("linked-record").path) == 0)
    case "symlink":
      let saved = fixture.root.appendingPathComponent("saved-record")
      try FileManager.default.moveItem(at: record, to: saved)
      try FileManager.default.createSymbolicLink(at: record, withDestinationURL: saved)
    case "oversize": try Data(repeating: 32, count: 1_048_577).write(to: record)
    default: try FileManager.default.removeItem(at: record)
    }
    try FileManager.default.removeItem(at: relocation.replacement)
    let store = try relocation.store()
    #expect(try DreamRunEncoding.encode(DreamInspection.read(stateRoot: fixture.state)) == history)
    let report = try transactionCompleted(
      store.run(
        selection: fixture.selection,
        resume: .retryInterruptedCall, prepare: transactionUncalledPrepare,
        call: transactionUncalled))
    #expect(report.generation == 1 && report.runID == relocation.baselineRunID)
    #expect(try store.verifiedCompletedReviewCandidates().count == 1)
    let draft = try MemoryDraftStore(
      repository: fixture.memory,
      journal: URL(fileURLWithPath: relocation.configuration.journal))
    let saved = try draft.create()
    #expect(try draft.read(saved.draftID, revision: saved.revision).operations.isEmpty)
    #expect(DreamQueueSnapshot.read(configuration: relocation.configuration).coverage == nil)
    #expect(throws: (any Error).self) { try relocation.run(call: transactionUncalled) }
    if variant == "unreadable" { #expect(chmod(record.path, 0o600) == 0) }
  }

  @Test func copiedRecordAndRoleSubstitutionCannotResolveAnotherStore() throws {
    let relocation = try PromptRelocationFixture()
    let foreign = try PromptRelocationFixture()
    defer {
      relocation.transaction.clean()
      foreign.transaction.clean()
    }
    try relocation.confirm(relocation.preview())
    try FileManager.default.copyItem(at: relocation.recordURL, to: foreign.recordURL)
    let before = try foreign.transaction.snapshot(foreign.transaction.root)
    #expect(throws: (any Error).self) { try foreign.run(call: transactionUncalled) }
    #expect(DreamQueueSnapshot.read(configuration: foreign.configuration).coverage == nil)
    #expect(try foreign.transaction.snapshot(foreign.transaction.root) == before)
    let store = try relocation.store()
    #expect(throws: (any Error).self) {
      try store.run(
        selection: relocation.transaction.selection,
        sourceRoles: DreamSourceRoles(isSnippetsPresent: false, isPromptsPresent: true),
        prepare: { _, _ in throw MemoryError("must not prepare") }, call: transactionUncalled)
    }
  }

  @Test(arguments: ["state", "memory", "sessions", "snippets", "alias", "file", "worldWritable"])
  func unsafeReplacementCannotAuthorizeAvailability(_ variant: String) throws {
    let relocation = try PromptRelocationFixture()
    let fixture = relocation.transaction
    defer { fixture.clean() }
    let target: URL
    switch variant {
    case "state": target = fixture.state.appendingPathComponent("nested-prompts")
    case "memory": target = fixture.memory
    case "sessions": target = fixture.sessions
    case "snippets": target = fixture.snippets
    case "alias":
      target = fixture.root.appendingPathComponent("alias")
      try FileManager.default.createSymbolicLink(
        at: target, withDestinationURL: relocation.replacement)
    case "file": target = relocation.replacement.appendingPathComponent("review.md")
    default:
      target = relocation.replacement
      #expect(chmod(target.path, 0o777) == 0)
    }
    if variant == "state" {
      try FileManager.default.createDirectory(
        at: target, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    #expect(throws: (any Error).self) {
      try relocation.store().previewPromptRelocation(
        baselineRunID: relocation.baselineRunID,
        replacement: target, sourceRoles: relocation.roles)
    }
    #expect(!FileManager.default.fileExists(atPath: relocation.recordURL.path))
  }

  @Test(arguments: [false, true])
  func actualWorkerAndQueueUseTheSameRelocatedDefinitions(isSnippetsPresent: Bool) throws {
    let relocation = try PromptRelocationFixture(
      isSnippetsPresent: isSnippetsPresent,
      definitionBody: "Check $1 and $1")
    let fixture = relocation.transaction
    defer { fixture.clean() }
    try relocation.confirm(relocation.preview())
    try fixture.append(dreamUser("expanded", nil, dreamOld, "Check parser and parser") + "\n")
    let queue = DreamQueueSnapshot.read(configuration: relocation.configuration)
    #expect(queue.unavailableReason == nil && queue.coverage?.plannedBytes == 6)
    let worker = try DreamWorkerProcess()
    defer { worker.clean() }
    try worker.send([
      "version": 1, "type": "start", "invocationID": "synthetic-relocation",
      "roots": [
        "state": fixture.state.path, "sessions": fixture.sessions.path,
        "memory": fixture.memory.path,
        "snippets": isSnippetsPresent ? fixture.snippets.path as Any : NSNull(),
        "prompts": relocation.prompts.path, "globalAgents": NSNull(),
      ],
      "selection": [
        "provider": fixture.selection.provider, "modelID": fixture.selection.modelID,
        "thinkingLevel": fixture.selection.thinkingLevel,
      ],
      "resume": "inspectOrContinue", "batchTextBytes": 262_144,
    ])
    let request = try worker.frame()
    #expect(request["type"] as? String == "modelRequest")
    let messages = try #require(request["messages"] as? [[String: Any]])
    let text = try #require(messages.first?["text"] as? String)
    let context = try #require(
      JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let evidence = try #require(context["primaryEvidence"] as? [[String: Any]])
    #expect(evidence.count == 1)
    #expect(evidence.first?["text"] as? String == "parser")
    #expect(evidence.first?["kind"] as? String == "typedSkillArguments")
    #expect(worker.progressFrames.first?["plannedBytes"] as? UInt64 == queue.coverage?.plannedBytes)
    let decisions: [[String: Any]] = [
      [
        "kind": "noChange", "sources": [evidence[0]["source"]!],
        "reasonCode": "notDurable", "explanation": "Synthetic argument only.",
      ]
    ]
    let response = try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 1,
        "contextHash": request["contextHash"]!, "decisions": decisions,
      ], options: [.sortedKeys])
    var reply: [String: Any] = [
      "version": 1, "type": "modelResponse",
      "text": String(decoding: response, as: UTF8.self),
    ]
    for key in ["invocationID", "requestID", "runID", "inputHash", "contextHash", "requestHash"] {
      reply[key] = request[key]
    }
    try worker.send(reply)
    let final = try worker.frame()
    #expect(final["status"] as? String == "completed" && final["generation"] as? String == "2")
    try worker.finish()
    #expect(
      DreamQueueSnapshot.read(configuration: relocation.configuration).coverage?.undreamtBytes == 0)
  }

  @Test func configuredCommandParserAndPreviewConfirmationNeverStartInference() throws {
    let relocation = try PromptRelocationFixture()
    let fixture = relocation.transaction
    defer { fixture.clean() }
    let configURL = fixture.root.appendingPathComponent("profile/config.json")
    try relocation.configuration.save(to: configURL)
    let binary = try #require(ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_BIN"])
    func command(_ arguments: [String]) throws -> CommandResult {
      try runCommand(
        executable: URL(fileURLWithPath: binary), arguments: ["dream"] + arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path])
    }
    let options = [
      "--config", configURL.path, "--baseline-run", relocation.baselineRunID,
      "--to", relocation.replacement.path,
    ]
    let before = try fixture.snapshot(fixture.root)
    for arguments in [
      ["relocate-prompts-preview"] + options + ["--state", fixture.state.path],
      ["relocate-prompts-preview"] + options + ["--confirm", "yes"],
      ["relocate-prompts-preview"] + options + ["--to", relocation.replacement.path],
      ["relocate-prompts-preview", "--config", configURL.path],
      ["relocate-prompts-preview"] + options + ["--unknown", "value"],
      ["relocate-prompts-confirm"] + options,
      ["relocate-prompts-confirm"] + options + [
        "--preview", String(repeating: "0", count: 64), "--confirm", "no",
      ],
    ] {
      let result = try command(arguments)
      #expect(result.status != 0 && result.output.isEmpty)
      #expect(try fixture.snapshot(fixture.root) == before)
    }
    let preview = try command(["relocate-prompts-preview"] + options)
    #expect(preview.status == 0, "\(preview.errorText)")
    let output = try #require(JSONSerialization.jsonObject(with: preview.output) as? [String: Any])
    let hash = try #require(output["previewHash"] as? String)
    #expect(output["isCompatible"] as? Bool == true)
    #expect(try fixture.snapshot(fixture.root) == before)
    let confirmed = try command(
      ["relocate-prompts-confirm"] + options + ["--preview", hash, "--confirm", "yes"])
    #expect(confirmed.status == 0, "\(confirmed.errorText)")
    var after = try fixture.snapshot(fixture.root)
    let installedRecord = after.removeValue(forKey: relocation.recordURL.path)
    #expect(installedRecord != nil)
    #expect(after == before)
    #expect(!String(decoding: confirmed.output, as: UTF8.self).contains("modelRequest"))
  }

  @Test func savedResponseReuseDoesNotReadCorruptRelocationOrMissingTarget() throws {
    let relocation = try PromptRelocationFixture()
    let fixture = relocation.transaction
    defer { fixture.clean() }
    try relocation.confirm(relocation.preview())
    try fixture.append(dreamUser("next", nil, dreamOld, "Retain another preference.") + "\n")
    let store = try relocation.store()
    store.beforePublication = { _ in throw CancellationError() }
    #expect(throws: CancellationError.self) {
      try relocation.run(store, call: { try transactionAdd($0) })
    }
    try Data("{bad".utf8).write(to: relocation.recordURL)
    try FileManager.default.removeItem(at: relocation.replacement)
    let result = try transactionCompleted(
      relocation.store().run(
        selection: fixture.selection,
        prepare: transactionUncalledPrepare, call: transactionUncalled))
    #expect(result.generation == 2 && result.proposals.count == 1)
  }

  @Test(arguments: [false, true])
  func recordAppearingDuringConfirmationIsNeverOverwritten(isIdentical: Bool) throws {
    let relocation = try PromptRelocationFixture()
    let fixture = relocation.transaction
    defer { fixture.clean() }
    let store = try relocation.store()
    let preview = try relocation.preview(store)
    let before = try fixture.snapshot(fixture.root)
    var installedBytes: Data?
    store.persistenceFault = { event in
      guard event == .beforeInstall("prompt-relocation.json") else { return }
      let names = try FileManager.default.contentsOfDirectory(atPath: fixture.state.path)
      let pending = try #require(names.first { $0.hasPrefix(".pending-") })
      let bytes =
        try isIdentical
        ? Data(contentsOf: fixture.state.appendingPathComponent(pending)) : Data("{}".utf8)
      try bytes.write(to: relocation.recordURL)
      #expect(chmod(relocation.recordURL.path, 0o600) == 0)
      installedBytes = bytes
    }
    #expect(throws: (any Error).self) { try relocation.confirm(preview, store: store) }
    #expect(try Data(contentsOf: relocation.recordURL) == #require(installedBytes))
    var after = try fixture.snapshot(fixture.root)
    after.removeValue(forKey: relocation.recordURL.path)
    #expect(after == before)
    #expect(throws: (any Error).self) { try relocation.confirm(preview) }
  }

  @Test func defaultRolesComeFromHistoricalPathsRatherThanTheReplacement() throws {
    let relocation = try PromptRelocationFixture(isSnippetsPresent: false, promptsName: "prompts")
    let fixture = relocation.transaction
    defer { fixture.clean() }
    try relocation.confirm(relocation.preview())
    var config = relocation.configuration
    config.roots = nil
    config.settings.agentDirectory = fixture.root.path
    let store = try relocation.store()
    let historical = try store.historicalSourceIdentities
    let roles = try config.queueSourceRoles(
      sessions: historical.sessions, stripping: historical.stripping)
    #expect(roles == relocation.roles)
    #expect(historical.stripping == [relocation.prompts])
    #expect(
      try store.inspectQueue(
        isSnippetsPresent: roles.isSnippetsPresent,
        isPromptsPresent: roles.isPromptsPresent
      ).segments != nil)
    #expect(throws: (any Error).self) {
      try config.queueSourceRoles(sessions: fixture.sessions, stripping: [relocation.replacement])
    }
  }

  @Test(arguments: ["malformed", "unsupported"])
  func corruptRecordsFailManagementAndFreshResolutionWithoutBlockingHistory(_ variant: String)
    throws
  {
    let relocation = try PromptRelocationFixture()
    let fixture = relocation.transaction
    defer { fixture.clean() }
    let preview = try relocation.preview()
    try relocation.confirm(preview)
    let history = try DreamRunEncoding.encode(DreamInspection.read(stateRoot: fixture.state))
    let expected: String
    if variant == "malformed" {
      try Data("{".utf8).write(to: relocation.recordURL)
      expected = "corrupt prompt relocation record"
    } else {
      let bytes = try String(contentsOf: relocation.recordURL, encoding: .utf8)
      try Data(
        bytes.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99").utf8
      )
      .write(to: relocation.recordURL)
      expected = "unsupported prompt relocation record"
    }
    let before = try fixture.snapshot(fixture.root)
    let store = try relocation.store()
    for operation in [
      { _ = try relocation.preview(store) },
      { try relocation.confirm(preview, store: store) },
      { _ = try relocation.run(store, call: transactionUncalled) },
    ] {
      do {
        try operation()
        Issue.record("invalid mapping was accepted")
      } catch { #expect(String(describing: error) == expected) }
    }
    let queue = DreamQueueSnapshot.read(configuration: relocation.configuration)
    #expect(queue.coverage == nil && queue.unavailableReason == "Queue unavailable: \(expected)")
    #expect(try DreamRunEncoding.encode(DreamInspection.read(stateRoot: fixture.state)) == history)
    #expect(try fixture.snapshot(fixture.root) == before)
  }

  @Test func mappingCannotSurviveRemovalOfItsActivationAncestor() throws {
    let relocation = try PromptRelocationFixture()
    let fixture = relocation.transaction
    defer { fixture.clean() }
    try relocation.confirm(relocation.preview())
    try FileManager.default.removeItem(
      at: fixture.state.appendingPathComponent("generations/1.json"))
    let before = try fixture.snapshot(fixture.root)
    #expect(throws: (any Error).self) {
      try relocation.store().inspectQueue(isSnippetsPresent: true, isPromptsPresent: true)
    }
    #expect(DreamQueueSnapshot.read(configuration: relocation.configuration).coverage == nil)
    #expect(try fixture.snapshot(fixture.root) == before)
  }

  @Test(arguments: ["topLevel", "nested", "otherName"])
  func onlyTheExactTopLevelDreamOverlayIsExcludedFromAuthorityTraversal(_ variant: String) throws {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    _ = try fixture.store().run(
      selection: fixture.selection,
      prepare: { try fixture.prepare($0) }, call: transactionUncalled)
    let directory = try DreamStateDirectory.openRoot(fixture.state, isCreating: false)
    let relative: String
    switch variant {
    case "nested": relative = "runs/prompt-relocation.json"
    case "otherName": relative = "other-relocation.json"
    default: relative = "prompt-relocation.json"
    }
    let overlay = fixture.state.appendingPathComponent(relative)
    try FileManager.default.createSymbolicLink(
      at: overlay,
      withDestinationURL: fixture.root.appendingPathComponent("unavailable-private-entry"))
    #expect(throws: DreamRunError.unsafeState) {
      try directory.retainedBytes(maximum: 1_073_741_824)
    }
    if variant == "topLevel" {
      #expect(try directory.retainedBytes(maximum: 1_073_741_824, isDreamAuthority: true) > 0)
      #expect(try DreamInspection.read(stateRoot: fixture.state).runs.isEmpty)
    } else {
      #expect(throws: DreamRunError.unsafeState) {
        try directory.retainedBytes(maximum: 1_073_741_824, isDreamAuthority: true)
      }
    }
  }

  @Test func ordinaryDefinitionUpdatesAndSamePathPackageReplacementRemainSupported() throws {
    let relocation = try PromptRelocationFixture()
    let fixture = relocation.transaction
    defer { fixture.clean() }
    try relocation.confirm(relocation.preview())
    let binding = try relocation.store().reviewSourceBinding()
    let originalInput = try Data(contentsOf: fixture.payload("input.json"))
    let first = try #require(
      (JSONSerialization.jsonObject(with: originalInput) as? [String: Any])?["batch"]
        as? [String: Any])
    let oldPackage = fixture.root.appendingPathComponent("old-package")
    try FileManager.default.moveItem(at: relocation.replacement, to: oldPackage)
    try fixture.write(
      "Updated ordinary definition $@\n",
      file: relocation.replacement.appendingPathComponent("updated.md"))
    var oldIdentity = stat()
    var newIdentity = stat()
    #expect(
      lstat(oldPackage.path, &oldIdentity) == 0
        && lstat(relocation.replacement.path, &newIdentity) == 0)
    #expect(oldIdentity.st_ino != newIdentity.st_ino)
    try fixture.append(dreamUser("next", nil, dreamOld, "A later human preference.") + "\n")
    #expect(
      DreamQueueSnapshot.read(configuration: relocation.configuration).coverage?.undreamtBytes == 25
    )
    let report = try transactionCompleted(relocation.run())
    #expect(report.generation == 2)
    let updatedInput = try Data(contentsOf: fixture.payload("input.json", generation: 1))
    let updated = try #require(
      (JSONSerialization.jsonObject(with: updatedInput) as? [String: Any])?["batch"]
        as? [String: Any])
    #expect(first["strippingInputHash"] as? String != updated["strippingInputHash"] as? String)
    #expect(try relocation.store().reviewSourceBinding() == binding)
  }
}
