import Foundation
import Testing

@testable import CoreMemories

let dreamOld = "2026-01-05T00:00:00.000Z"
let dreamNew = "2026-01-15T00:00:00.000Z"
let dreamWindow = EntryWindow(
  filesModifiedAfter: Date(timeIntervalSince1970: 1_768_003_200),
  entryFloor: Date(timeIntervalSince1970: 1_768_003_200),
  upper: Date(timeIntervalSince1970: 1_893_456_000))
let dreamSnippet = "Diagnose only. Do not edit files."
let dreamPrompt = "Review the reader diff and report findings."
let dreamSecondPrompt = "Check the census numbers against the store."

func dreamJSON(_ value: Any) -> String {
  let data = try? JSONSerialization.data(
    withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
  return String(decoding: data ?? Data(), as: UTF8.self)
}

func dreamObject(_ fields: [(String, String)]) -> String {
  "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
}

func dreamEntry(_ id: String, _ parent: String?, _ time: String, message: String) -> String {
  dreamObject([
    ("type", dreamJSON("message")), ("id", dreamJSON(id)),
    ("parentId", parent.map(dreamJSON) ?? "null"), ("timestamp", dreamJSON(time)),
    ("message", message),
  ])
}

func dreamText(_ text: String) -> String {
  dreamObject([("type", dreamJSON("text")), ("text", dreamJSON(text))])
}

func dreamUser(_ id: String, _ parent: String?, _ time: String, _ text: String) -> String {
  let message = dreamObject([("role", dreamJSON("user")), ("content", "[\(dreamText(text))]")])
  return dreamEntry(id, parent, time, message: message)
}

func dreamAssistant(
  _ id: String, _ parent: String?, _ time: String, _ blocks: [String], stop: String = "stop"
) -> String {
  let message = dreamObject([
    ("role", dreamJSON("assistant")), ("content", "[\(blocks.joined(separator: ","))]"),
    ("stopReason", dreamJSON(stop)),
  ])
  return dreamEntry(id, parent, time, message: message)
}

func dreamCall(_ id: String, _ name: String, _ arguments: [String: Any]) -> String {
  dreamObject([
    ("type", dreamJSON("toolCall")), ("id", dreamJSON(id)), ("name", dreamJSON(name)),
    ("arguments", dreamJSON(arguments)),
  ])
}

func dreamResult(
  _ id: String, _ parent: String?, call: String, tool: String, _ text: String,
  details: [String: Any]? = nil, isError: Bool = false
) -> String {
  let fields = [
    ("role", dreamJSON("toolResult")), ("toolCallId", dreamJSON(call)),
    ("toolName", dreamJSON(tool)), ("content", "[\(dreamText(text))]"),
  ]
  let message = dreamObject(
    fields + (details.map { [("details", dreamJSON($0))] } ?? []) + [("isError", "\(isError)")])
  return dreamEntry(id, parent, dreamNew, message: message)
}

func dreamHeader(_ id: String, cwd: String, parent: String? = nil, name: String?) -> String {
  var header: [String: Any] = [
    "type": "session", "version": 3, "id": id, "timestamp": "2026-01-04T00:00:00.000Z",
    "cwd": cwd,
  ]
  header["parentSession"] = parent
  let info = name.map { name in
    dreamObject([
      ("type", dreamJSON("session_info")), ("id", dreamJSON("info")), ("parentId", "null"),
      ("timestamp", dreamJSON(dreamOld)), ("name", dreamJSON(name)),
    ])
  }
  return ([dreamJSON(header)] + (info.map { [$0] } ?? [])).joined(separator: "\n")
}

func dreamAnswer(_ status: String, _ answers: [[String: Any]]) -> [String: Any] {
  ["status": status, "question": "Ship it?", "mode": "text", "answers": answers]
}

func dreamPrimaryLines(project: URL) -> [String] {
  let skill = "<skill name=\"fix\" location=\"/skills/fix/SKILL.md\">\nFix things.\n</skill>"
  let error: (String, String) -> [String] = { id, parent in
    [
      dreamAssistant(
        "e\(id)", parent, dreamNew, [dreamCall("b\(id)", "bash", ["command": "swift build"])]),
      dreamResult("x\(id)", "e\(id)", call: "b\(id)", tool: "bash", "error: boom", isError: true),
    ]
  }
  let record = dreamObject([
    ("type", dreamJSON("custom")), ("customType", dreamJSON("subagents:record")),
    ("data", dreamJSON(["id": "agent-1", "status": "completed", "result": "Recorded report."])),
    ("id", dreamJSON("k1")), ("parentId", dreamJSON("r2")), ("timestamp", dreamJSON(dreamNew)),
  ])
  let customMessage = dreamObject([
    ("type", dreamJSON("custom_message")), ("customType", dreamJSON("note")),
    ("content", dreamJSON("hidden")), ("id", dreamJSON("m1")), ("parentId", dreamJSON("a2")),
    ("timestamp", dreamJSON(dreamNew)),
  ])
  let surrogate = dreamUser("s1", "a2", dreamNew, "surrogate PLACEHOLDER text")
    .replacingOccurrences(of: "PLACEHOLDER", with: #"\ud83d"#)
  let typedAnswer = dreamAnswer(
    "answered", [["type": "text", "label": "yes please", "value": "yes please"]])
  let pickedAnswer = dreamAnswer(
    "answered",
    [
      ["type": "option", "label": "A", "value": "a", "index": 0],
      ["type": "option", "label": "B", "value": "b", "index": 1],
    ])
  let agentCall = dreamCall(
    "c1", "Agent",
    [
      "prompt": dreamPrompt, "subagent_type": "code-reviewer", "description": "Review",
      "run_in_background": true,
    ])
  let start = [
    dreamHeader("primary", cwd: project.path, name: "Feature work"),
    dreamUser("u0", nil, dreamOld, "Old human text that is context only."),
    dreamAssistant("a0", "u0", dreamOld, [dreamText("Earlier agent context sentence.")]),
    dreamUser("u1", "a0", dreamNew, "Please make the reader skip snippets."),
    dreamUser("u2", "u1", dreamNew, skill + "\n\nfix the failing census"),
    dreamUser("u3", "u2", dreamNew, skill),
    dreamUser("u4", "u3", dreamNew, dreamSnippet + "\n\nreal words here"),
    dreamUser("u5", "u4", dreamNew, dreamSnippet),
    dreamUser("u6", "u5", dreamNew, "OK"),
    dreamUser("u7", "u6", dreamNew, "<file name=\"a.md\">unterminated"),
    dreamUser(
      "u8", "u7", dreamNew, "<file name=\"a.md\">content</file>\n\nsummarize this file please"),
    dreamAssistant(
      "a1", "u8", dreamNew,
      [
        dreamText(String(repeating: "primary agent text ", count: 14)), agentCall,
        dreamCall("c2", "Agent", ["prompt": dreamSecondPrompt, "subagent_type": "implementer"]),
        dreamCall("c3", "read", ["path": project.path + "/Sources/x.swift"]),
        dreamCall("c4", "bash", ["command": "cat 'docs/notes.md' | rg term"]),
      ]),
    dreamResult(
      "r1", "a1", call: "c1", tool: "Agent",
      "Agent started in background.\nAgent ID: agent-1\nType: code-reviewer"),
    dreamResult(
      "r2", "r1", call: "c2", tool: "Agent",
      "Agent started in background.\nAgent ID: agent-2\nType: implementer"),
    record,
    dreamResult(
      "r3", "k1", call: "g1", tool: "get_subagent_result",
      "Agent: agent-1\nType: code-reviewer | Status: completed\n\nRecorded report."),
    dreamResult(
      "q1", "r3", call: "q1", tool: "ask_user_question", "User answered: yes please",
      details: typedAnswer),
    dreamResult(
      "q2", "q1", call: "q2", tool: "ask_user_question", "User selected: A",
      details: pickedAnswer),
    dreamResult(
      "q3", "q2", call: "q3", tool: "ask_user_question", "User cancelled",
      details: dreamAnswer("cancelled", [])),
  ]
  let end = [
    dreamResult("ok", "x3", call: "b4", tool: "bash", "fine"),
    dreamAssistant("a2", "ok", dreamNew, [dreamText("Cut off")], stop: "length"),
    customMessage, "{not json", surrogate, #"{"type":"message","id":"late""#,
  ]
  return start + error("1", "q3") + error("2", "x1") + error("3", "x2") + end
}

struct DreamStore {
  let root: URL
  let sessions: URL
  let snippets: URL
  let project: URL
  let primary: URL

  init() throws {
    let root = try temporaryDirectory()
    let sessions = root.appendingPathComponent("sessions")
    let project = root.appendingPathComponent("project")
    let snippets = root.appendingPathComponent("snippets")
    self.root = root
    self.sessions = sessions
    self.project = project
    self.snippets = snippets
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    _ = try Git(repo: project, environment: ProcessInfo.processInfo.environment).data([
      "init", "--initial-branch=main", "--template=",
    ])
    let snippet = "---\nname: diagnose\nplacement: prepend\n---\n\n\(dreamSnippet)\n"
    try Self.write(snippet, to: snippets.appendingPathComponent("diagnose.md"))
    func session(
      _ folder: String, _ name: String, _ lines: [String], isTerminated: Bool = true
    ) throws -> URL {
      let file = sessions.appendingPathComponent(folder).appendingPathComponent(name)
      try Self.write(lines.joined(separator: "\n") + (isTerminated ? "\n" : ""), to: file)
      return file
    }
    let primary = try session(
      "--primary--", "primary.jsonl", dreamPrimaryLines(project: project), isTerminated: false)
    self.primary = primary
    let missing = root.appendingPathComponent("removed-checkout").path
    let finding = String(repeating: "child finding ", count: 40)
    let childAnswer = dreamAnswer("answered", [["type": "text", "label": "yes", "value": "yes"]])
    _ = try session(
      "--checkout--", "child-one.jsonl",
      [
        dreamHeader(
          "child-one", cwd: missing, parent: primary.path, name: "code-reviewer#0a944051"),
        dreamUser("cu1", nil, dreamNew, dreamPrompt),
        dreamAssistant("ca1", "cu1", dreamNew, [dreamText(finding)]),
        dreamResult(
          "cr1", "ca1", call: "q", tool: "ask_user_question", "User answered: yes",
          details: childAnswer),
        dreamAssistant("ca2", "cr1", dreamNew, [dreamText("Child one final text.")]),
      ])
    _ = try session(
      "--checkout--", "child-two.jsonl",
      [
        dreamHeader(
          "child-two", cwd: missing, parent: primary.path, name: "implementer#1b2c3d4e"),
        dreamUser("du1", nil, dreamNew, dreamSecondPrompt),
        dreamAssistant("da1", "du1", dreamNew, [dreamText("Child two final text.")]),
      ])
    _ = try session(
      "--orphan--", "orphan.jsonl",
      [
        dreamHeader("orphan", cwd: missing, name: "general-purpose#85d52afb"),
        dreamUser("ou1", nil, dreamNew, "Orphan prompt."),
        dreamAssistant("oa1", "ou1", dreamNew, [dreamText("Orphan final text.")]),
      ])
    _ = try session(
      "--memory--", "observer.jsonl",
      [
        dreamHeader("observer", cwd: missing, name: "om-observer-obs-1"),
        dreamUser("x", nil, dreamNew, "observer"),
      ])
    _ = try session(
      "--comment--", "shape.jsonl",
      [
        dreamHeader("shape", cwd: missing, name: "comment-shape-1"),
        dreamUser("x", nil, dreamNew, "shape"),
      ])
    _ = try session("--broken--", "broken.jsonl", ["not a header"])
    let old = try session(
      "--old--", "old.jsonl",
      [dreamHeader("old", cwd: missing, name: nil), dreamUser("x", nil, dreamNew, "old")])
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: old.path)
    _ = try session(
      "--primary--/nested", "deep.jsonl",
      [dreamHeader("deep", cwd: project.path, name: nil), dreamUser("x", nil, dreamNew, "deep")])
  }

  func clean() {
    try? FileManager.default.removeItem(at: root)
  }

  private static func write(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }

  func snapshot() throws -> [String: [String: String]] {
    var state: [String: [String: String]] = [:]
    let enumerator = FileManager.default.enumerator(
      at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])
    while let file = enumerator?.nextObject() as? URL {
      let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
      let data = (try? Data(contentsOf: file)) ?? Data()
      state[file.path] = [
        "modified": "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)",
        "sha": SessionReader.sha256(String(decoding: data, as: UTF8.self)),
      ]
    }
    return state
  }
}

@Test func classificationIsAnOrderedRuleTable() {
  func label(_ name: String?, parent: String? = nil) -> String {
    let (sessionClass, marker) = SessionReader.classify(
      SessionHeader(id: "s", cwd: "/", timestamp: Date(), parentSession: parent, name: name))
    return sessionClass.rawValue + "/" + (marker?.rawValue ?? "none")
  }
  #expect(label("om-observer-obs-1") == "infrastructure/none")
  #expect(label("om-consolidator-1", parent: "/p") == "infrastructure/none")
  #expect(label("comment-shape-1") == "infrastructure/none")
  #expect(label("Feature", parent: "/p") == "child/parentSession")
  #expect(label("general-purpose#85d52afb") == "child/agentName")
  #expect(label("code-reviewer#938949") == "child/agentName")
  let primaryNames: [String?] = [
    "code-reviewer#93894", "Code-reviewer#938949b9", "reviewer#93894g", "#938949b9", nil,
  ]
  for name in primaryNames {
    #expect(label(name) == "primary/none")
  }
}

@Test func humanTextLabelsOnlyWhatTheHumanTyped() {
  let snippets = [dreamSnippet, "Run unattended."]
  let skill = "<skill name=\"fix\" location=\"/s/SKILL.md\">\nBody\nmore\n</skill>"
  let cases: [(String, HumanText)] = [
    ("Plain words", .human("Plain words", .typed)),
    (skill + "\n\n  the arguments  ", .human("the arguments", .typedSkillArguments)),
    (skill, .skillOnly),
    (skill + "\n\n" + dreamSnippet, .skillOnly),
    (dreamSnippet + "\n\nkept\n\nRun unattended.", .human("kept", .typed)),
    ("Run unattended.\n\n" + dreamSnippet, .snippetOnly),
    (dreamSnippet + "\n\n" + dreamSnippet + "\n\ntwice", .human("twice", .typed)),
    ("text " + dreamSnippet, .human("text " + dreamSnippet, .typed)),
    ("<file name=\"x.md\">body</file>\n\nread it", .human("read it", .typed)),
    ("<file name=\"x.md\">body</file>", .empty),
    ("<file name=\"x.md\">a </file> b\n</file>\n\nread it", .unknownMarkup),
    (
      "<persistent-memory-recall>\nstale\n</persistent-memory-recall>\n\n<leader>sf",
      .human("<leader>sf", .typed)
    ),
    ("<inputs>\nname\n</inputs>", .human("<inputs>\nname\n</inputs>", .typed)),
    ("< 3 is less", .human("< 3 is less", .typed)),
    ("  Continue ", .acknowledgement),
    ("y", .acknowledgement),
    ("yes, and more", .human("yes, and more", .typed)),
    ("   ", .empty),
  ]
  for (raw, expected) in cases {
    #expect(SessionReader.humanText(raw, snippets: snippets) == expected, "\(raw)")
  }
  let templates = ["Look up `$1`.\n\nAnswer ${@:2}.", "Run the checks."]
  let expanded: [(String, HumanText)] = [
    (
      "Look up `react`.\n\nAnswer hooks please.", .human("react hooks please", .typedSkillArguments)
    ),
    ("Look up ``.\n\nAnswer .", .skillOnly),
    ("Run the checks.", .skillOnly),
    ("Run the checks now.", .human("Run the checks now.", .typed)),
  ]
  for (raw, expected) in expanded {
    #expect(
      SessionReader.humanText(raw, snippets: snippets, templates: templates) == expected, "\(raw)")
  }
  let long = String(repeating: "x", count: 5_000)
  guard case .human(let cut, .typed) = SessionReader.humanText(long, snippets: []) else {
    Issue.record("long text is typed")
    return
  }
  #expect(cut.hasPrefix(String(repeating: "x", count: 1_200) + "\n[… 3000 characters cut …]\n"))
}

@Test func promptArgumentsPreserveBoundariesAndExcludeDefaults() {
  let cases: [(String, String, HumanText)] = [
    ("Review $@", "Review ", .skillOnly),
    ("$@ review", " review", .skillOnly),
    ("Review ${1:-the branch}", "Review the branch", .skillOnly),
    ("Review ${1:-the branch}", "Review my change", .human("my change", .typedSkillArguments)),
    ("$1 then ${@:2}", "a then cat", .human("a cat", .typedSkillArguments)),
    ("Check $1 and $1", "Check parser and parser", .human("parser", .typedSkillArguments)),
    ("Review ${@:2:1}", "Review parser", .human("parser", .typedSkillArguments)),
    ("Review $ARGUMENTS", "Review parser tests", .human("parser tests", .typedSkillArguments)),
  ]
  for (template, expanded, expected) in cases {
    #expect(SessionReader.humanText(expanded, snippets: [], templates: [template]) == expected)
  }
}

@Test func askUserQuestionAnswersCarryEvidence() {
  func labels(_ answers: [[String: Any]], status: String = "answered") -> [String] {
    SessionReader.answers(dreamAnswer(status, answers)).map { "\($0.evidence):\($0.text)" }
  }
  let typed = SessionReader.answers(
    dreamAnswer("answered", [["type": "text", "label": " go on "]]))
  #expect(typed.count == 1 && typed.first?.question == "Ship it?")
  #expect(labels([["type": "text", "label": " go on "]]) == ["answered:go on"])
  #expect(
    labels([["type": "option", "label": "A"], ["type": "other", "label": "C"]]) == [
      "answered:C", "picked:A",
    ])
  #expect(
    labels([["type": "option", "label": "A"], ["type": "option", "label": "B"]]) == ["picked:A; B"])
  for status in ["cancelled", "invalid", "unavailable"] {
    #expect(labels([["type": "text", "label": "x"]], status: status).isEmpty)
  }
  #expect(labels([]).isEmpty)
  #expect(labels([["type": "text", "label": " "]]).isEmpty)
}

@Test func surrogateRepairReplacesOnlyLoneEscapes() throws {
  func decoded(_ text: String) throws -> String? {
    let data = SessionReader.repairSurrogates(Data(text.utf8))
    return try (JSONSerialization.jsonObject(with: data) as? [String: Any])?["t"] as? String
  }
  #expect(try decoded(#"{"t":"a\ud83db"}"#) == "a\u{FFFD}b")
  #expect(try decoded(#"{"t":"a\udc00"}"#) == "a\u{FFFD}")
  #expect(try decoded(#"{"t":"\ud83d\ude00"}"#) == "😀")
  #expect(try decoded(#"{"t":"\\ud83d"}"#) == #"\ud83d"#)
  #expect(try decoded(#"{"t":"\u00e9\n"}"#) == "é\n")
}

@Test func middleCutKeepsBothEnds() {
  #expect(SessionReader.middleCut("short", limit: 10) == "short")
  #expect(SessionReader.middleCut("0123456789", limit: 10) == "0123456789")
  let cut = SessionReader.middleCut("abcdefghijklmnopqrst", limit: 10)
  #expect(cut == "abcdef\n[… 10 characters cut …]\nqrst")
  let family = "👩‍👩‍👧"
  let emoji = SessionReader.middleCut(String(repeating: family, count: 20), limit: 10)
  #expect(emoji.hasPrefix(String(repeating: family, count: 6) + "\n[… 10 characters cut …]\n"))
}

@Test func pathTouchesComeFromToolArguments() {
  func paths(_ tool: String, _ key: String, _ value: String) -> [String] {
    SessionReader.paths(tool: tool, arguments: [key: value], cwd: "/work/repo")
  }
  #expect(paths("read", "path", "/work/repo/a/b.swift") == ["a/b.swift"])
  #expect(paths("grep", "path", "/elsewhere/x") == ["/elsewhere/x"])
  #expect(paths("edit", "path", "/work/repository/x") == ["/work/repository/x"])
  #expect(paths("ls", "path", "/work/repo/x").isEmpty)
  let command = "cat \"/work/repo/docs/a.md\" README.md; curl https://x.test/y && swift build"
  #expect(paths("bash", "command", command) == ["docs/a.md", "README.md"])
}

@Test func entryWindowAdmitsOnlyNewEntries() {
  let floor = Date(timeIntervalSince1970: 100)
  let upper = Date(timeIntervalSince1970: 200)
  let window = EntryWindow(filesModifiedAfter: floor, entryFloor: floor, upper: upper)
  #expect(!window.isNew(floor))
  #expect(window.isNew(Date(timeIntervalSince1970: 101)))
  #expect(window.isNew(upper))
  #expect(!window.isNew(Date(timeIntervalSince1970: 201)))
  let open = EntryWindow(filesModifiedAfter: floor, entryFloor: nil, upper: upper)
  #expect(open.isNew(Date(timeIntervalSince1970: 0)))
}

@Test func scanDigestsPrimaryAndChildSessionsReadOnly() throws {
  let store = try DreamStore()
  defer { store.clean() }
  let before = try store.snapshot()
  let reader = try SessionReader(sessions: store.sessions, snippets: store.snippets)
  let (digests, census) = try reader.scan(window: dreamWindow, sampleLimit: 2)
  #expect(try store.snapshot() == before)

  #expect(census.files == 7)
  #expect(census.sessions == [.primary: 1, .child: 3, .infrastructure: 2, .unreadable: 1])
  #expect(census.infrastructure == ["om-observer": 1, "comment-shape": 1])
  #expect(census.childMarkers == [.parentSession: 2, .agentName: 1])
  #expect(census.isSnippetsLoaded && !census.isPromptsLoaded)
  #expect(
    census.agent == [
      .primaryText: 1, .childText: 1, .subagentReport: 1, .orchestration: 3, .childFinalText: 3,
    ])
  #expect(
    census.folders == [
      .primary: ["other": 1], .child: ["other": 3], .infrastructure: ["other": 2],
      .unreadable: ["other": 1],
    ])
  #expect(census.projectsResolved == 1 && census.projectsViaParent == 2)
  #expect(census.projectsUnresolved == 1)
  #expect(census.samples[.typed] == ["Please make the reader skip snippets.", "real words here"])

  let primaryDigest = try #require(digests.first { $0.path == store.primary.path })
  guard case .primary(let primary) = primaryDigest else {
    Issue.record("primary digest")
    return
  }
  let key = try #require(try MemoryStore.projectKey(cwd: store.project))
  #expect(primary.projectKey == key && primary.projectAlias == "project")
  #expect(
    primary.human.map(\.text) == [
      "Please make the reader skip snippets.", "fix the failing census", "real words here",
      "summarize this file please", "yes please", "A; B", "surrogate \u{FFFD} text",
    ])
  #expect(
    primary.human.map(\.evidence) == [
      .typed, .typedSkillArguments, .typed, .typed, .answered, .picked, .typed,
    ])
  #expect(primary.human[0].agentContext == "Earlier agent context sentence.")
  #expect(primary.human[0].citation.reference == "pi:primary#u1")
  #expect(primary.human[4].question == "Ship it?")
  let counts = primary.counts
  #expect(counts.human == [.typed: 4, .typedSkillArguments: 1, .answered: 1, .picked: 1])
  #expect(counts.skillOnly == 1 && counts.snippetOnly == 1 && counts.acknowledgements == 1)
  #expect(counts.unknownMarkup == 1 && counts.customMessages == 1)
  #expect(counts.undecodableLines == 1 && counts.inFlightLines == 1)
  #expect(primary.agent.map(\.source) == [.primaryText])
  #expect(primary.paths.map(\.path) == ["Sources/x.swift", "docs/notes.md"])
  #expect(primary.stuck.map(\.kind) == [.repeatedToolError, .lengthStop, .repeatedCommand])
  #expect(primary.stuck[0].citations.map(\.entry) == ["x1", "x2", "x3"])

  #expect(primary.exchanges.count == 2)
  let first = primary.exchanges[0]
  #expect(first.agentId == "agent-1" && first.subagentType == "code-reviewer")
  #expect(first.childSession == "child-one")
  #expect(first.report?.text == "Recorded report." && first.report?.source == .subagentReport)
  let second = primary.exchanges[1]
  #expect(second.agentId == "agent-2" && second.childSession == "child-two")
  #expect(second.report?.text == "Child two final text.")
  #expect(second.report?.source == .childFinalText)

  let childDigest = try #require(digests.first { $0.path.hasSuffix("child-one.jsonl") })
  guard case .child(let child) = childDigest else {
    Issue.record("child digest")
    return
  }
  #expect(child.marker == .parentSession && child.projectKey == key)
  #expect(child.projectAlias == "removed-checkout")
  #expect(child.counts.childAnswers == 1 && child.counts.human.isEmpty)
  #expect(child.orchestration.map(\.text) == [dreamPrompt])
  #expect(child.agent.map(\.source) == [.childText])
  #expect(child.finalText?.text == "Child one final text.")

  let orphanDigest = try #require(digests.first { $0.path.hasSuffix("orphan.jsonl") })
  guard case .child(let orphan) = orphanDigest else {
    Issue.record("orphan digest")
    return
  }
  #expect(orphan.marker == .agentName && orphan.projectKey == nil)
  #expect(orphan.exchanges.count == 1)
  #expect(orphan.exchanges.first?.prompt == "Orphan prompt.")
  #expect(orphan.exchanges.first?.subagentType == "general-purpose")
  #expect(orphan.exchanges.first?.report?.text == "Orphan final text.")
}

@Test func projectKeysFollowParentSessions() throws {
  let store = try DreamStore()
  defer { store.clean() }
  var keys = ProjectKeys(environment: ProcessInfo.processInfo.environment)
  let key = try #require(try MemoryStore.projectKey(cwd: store.project))
  let direct = keys.key(cwd: store.project.path, parentPath: nil)
  #expect(direct.key == key && !direct.isViaParent && direct.alias == "project")
  let viaParent = keys.key(cwd: "/missing/dream/a", parentPath: store.primary.path)
  #expect(viaParent.key == key && viaParent.isViaParent && viaParent.alias == "a")
  let missing = keys.key(cwd: "/missing/dream/b", parentPath: "/missing/parent.jsonl")
  #expect(missing.key == nil && !missing.isViaParent && missing.alias == "b")
  let outside = keys.key(cwd: store.root.path, parentPath: store.primary.path)
  #expect(outside.key == nil && !outside.isViaParent)
  #expect(keys.resolved == 1 && keys.viaParent == 1 && keys.unresolved == 2)
}
