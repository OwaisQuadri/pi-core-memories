import Darwin
import Foundation
import Testing

@testable import CoreMemories

private final class ControlEvents: @unchecked Sendable {
  let lock = NSLock()
  var events: [Data] = []
  func append(_ event: Data) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }
}

@Test func dreamControlRefusesUnregisteredCommandsWithoutPrompting() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let agent = fixture.root.appendingPathComponent("agent")
  try fixture.write(
    "export {}", file: agent.appendingPathComponent("extensions/core-memories/control.ts"))
  let script = fixture.root.appendingPathComponent("fake-pi")
  let log = fixture.root.appendingPathComponent("rpc-input")
  try fixture.write(
    """
    #!/bin/zsh
    IFS= read -r line
    printf '%s\\n' "$line" > '\(log.path)'
    printf '%s\\n' '{"type":"response","id":"commands","success":true,"data":{"commands":[]}}'
    while IFS= read -r line; do printf '%s\\n' "$line" >> '\(log.path)'; done
    """, file: script)
  #expect(chmod(script.path, 0o700) == 0)
  let settings = MemoryAppSettings(
    piExecutable: script.path, agentDirectory: agent.path,
    controlExtension: agent.appendingPathComponent("extensions/core-memories/control.ts").path)
  #expect(throws: (any Error).self) {
    try DreamControl().run(
      operation: .start, settings: settings, roots: nil,
      diagnostics: fixture.root.appendingPathComponent("diagnostics"), onEvent: { _ in })
  }
  let input = try String(contentsOf: log, encoding: .utf8)
  #expect(input.contains("get_commands"))
  #expect(!input.contains("prompt"))
}

@Test func dreamControlWaitsForTerminalReportAndMatchingPromptResponse() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let agent = fixture.root.appendingPathComponent("agent")
  try fixture.write(
    "export {}", file: agent.appendingPathComponent("extensions/core-memories/control.ts"))
  let script = fixture.root.appendingPathComponent("fake-pi")
  let log = fixture.root.appendingPathComponent("rpc-input")
  try fixture.write(
    """
    #!/bin/zsh
    IFS= read -r line
    printf '%s\\n' '{"type":"response","id":"commands","success":true,"data":{"commands":[{"name":"memory-dream-control"},{"name":"memory-dream-cancel"}]}}'
    IFS= read -r line
    printf '%s\\n' '{"type":"response","id":"state","success":true,"data":{"model":{"provider":"fixture","id":"selected"},"thinkingLevel":"off"}}'
    IFS= read -r line
    printf '%s\\n' "$line" > '\(log.path)'
    printf '%s\\n' 'Authorization: Bearer fixture-credential' >&2
    printf '%s\\n' '{"type":"extension_ui_request","method":"notify","message":"{\\"version\\":1,\\"type\\":\\"core-memory-control\\",\\"event\\":\\"batchReport\\",\\"report\\":{}}"}'
    printf '%s\\n' '{"type":"extension_ui_request","method":"notify","message":"{\\"version\\":1,\\"type\\":\\"core-memory-control\\",\\"event\\":\\"report\\",\\"report\\":{}}"}'
    printf '%s\\n' '{"type":"response","id":"dream","success":true}'
    while IFS= read -r line; do :; done
    """, file: script)
  #expect(chmod(script.path, 0o700) == 0)
  let events = ControlEvents()
  let control = DreamControl()
  try control.run(
    operation: .all,
    settings: MemoryAppSettings(
      piExecutable: script.path, agentDirectory: agent.path,
      controlExtension: agent.appendingPathComponent("extensions/core-memories/control.ts").path),
    roots: nil,
    diagnostics: fixture.root.appendingPathComponent("diagnostics"), onEvent: { events.append($0) })
  #expect(events.events.count == 3)
  let diagnostic = fixture.root.appendingPathComponent("diagnostics")
    .appendingPathComponent(control.invocationID.uuidString).appendingPathComponent("stderr.txt")
  #expect(
    try String(contentsOf: diagnostic, encoding: .utf8) == "Authorization: Bearer [redacted]\n")
  let frame = try JSONSerialization.jsonObject(with: Data(contentsOf: log)) as! [String: Any]
  let message = frame["message"] as! String
  #expect(message.hasPrefix("/memory-dream-control "))
  let request =
    try JSONSerialization.jsonObject(
      with: Data(message.dropFirst("/memory-dream-control ".count).utf8)) as! [String: Any]
  #expect(Set(request.keys) == ["operation", "roots"])
  #expect(request["roots"] is NSNull)
}

@Test func dreamControlFailsClosedStdoutWithoutWaitingForChildExit() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let controlURL = fixture.root.appendingPathComponent("control.ts")
  try fixture.write("export {}", file: controlURL)
  let script = fixture.root.appendingPathComponent("fake-pi")
  try fixture.write(
    """
    #!/bin/zsh
    IFS= read -r line
    printf '%s\\n' '{"type":"response","id":"commands","success":true,"data":{"commands":[{"name":"memory-dream-control"},{"name":"memory-dream-cancel"}]}}'
    IFS= read -r line
    printf '%s\\n' '{"type":"response","id":"state","success":true,"data":{"model":{"provider":"fixture","id":"selected"},"thinkingLevel":"off"}}'
    IFS= read -r line
    exec 1>&-
    exec 2>&-
    /bin/sleep 5
    """, file: script)
  #expect(chmod(script.path, 0o700) == 0)
  let started = Date()
  do {
    try DreamControl().run(
      operation: .start,
      settings: MemoryAppSettings(
        piExecutable: script.path,
        agentDirectory: fixture.root.path, controlExtension: controlURL.path), roots: nil,
      diagnostics: fixture.root.appendingPathComponent("diagnostics"), onEvent: { _ in })
    Issue.record("closed stdout was accepted without a terminal report")
  } catch {
    #expect(String(describing: error).contains("RPC closed"))
    #expect(Date().timeIntervalSince(started) < 5)
  }
}

@Test func dreamControlRefusesResolvedSelectionMismatchAndUsesConfiguredAgentDirectory() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let controlURL = fixture.root.appendingPathComponent("control.ts")
  try fixture.write("export {}", file: controlURL)
  let script = fixture.root.appendingPathComponent("fake-pi")
  let log = fixture.root.appendingPathComponent("rpc-input")
  try fixture.write(
    """
    #!/bin/zsh
    printf '%s\\n' "$PI_CODING_AGENT_DIR" > '\(log.path)'
    IFS= read -r line
    printf '%s\\n' "$line" >> '\(log.path)'
    printf '%s\\n' '{"type":"response","id":"commands","success":true,"data":{"commands":[{"name":"memory-dream-control"},{"name":"memory-dream-cancel"}]}}'
    IFS= read -r line
    printf '%s\\n' "$line" >> '\(log.path)'
    printf '%s\\n' '{"type":"response","id":"state","success":true,"data":{"model":{"provider":"fixture","id":"different"},"thinkingLevel":"off"}}'
    while IFS= read -r line; do printf '%s\\n' "$line" >> '\(log.path)'; done
    """, file: script)
  #expect(chmod(script.path, 0o700) == 0)
  do {
    try DreamControl().run(
      operation: .start,
      settings: MemoryAppSettings(
        piExecutable: script.path, agentDirectory: fixture.root.path,
        provider: "fixture", modelID: "requested", thinkingLevel: "off",
        controlExtension: controlURL.path),
      roots: nil, diagnostics: fixture.root.appendingPathComponent("diagnostics"), onEvent: { _ in }
    )
    Issue.record("an explicit selection mismatch was accepted")
  } catch {
    #expect(String(describing: error).contains("different explicit"))
  }
  let input = try String(contentsOf: log, encoding: .utf8)
  #expect(input.hasPrefix(fixture.root.path + "\n"))
  #expect(!input.contains("prompt"))
}
