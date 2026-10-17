import Darwin
import Foundation
import Testing

@testable import CoreMemories

private final class ControlEvents: @unchecked Sendable {
  let lock = NSLock()
  var events: [Data] = []
  func append(_ event: Data) { lock.lock(); events.append(event); lock.unlock() }
}

@Test func dreamControlRefusesUnregisteredCommandsWithoutPrompting() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let agent = fixture.root.appendingPathComponent("agent")
  try fixture.write("export {}", file: agent.appendingPathComponent("extensions/core-memories/control.ts"))
  let script = fixture.root.appendingPathComponent("fake-pi")
  let log = fixture.root.appendingPathComponent("rpc-input")
  try fixture.write("""
    #!/bin/zsh
    IFS= read -r line
    printf '%s\\n' "$line" > '\(log.path)'
    printf '%s\\n' '{"type":"response","id":"commands","success":true,"data":{"commands":[]}}'
    while IFS= read -r line; do printf '%s\\n' "$line" >> '\(log.path)'; done
    """, file: script)
  #expect(chmod(script.path, 0o700) == 0)
  let settings = MemoryAppSettings(piExecutable: script.path, agentDirectory: agent.path)
  #expect(throws: (any Error).self) {
    try DreamControl().run(operation: .start, settings: settings, roots: nil,
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
  try fixture.write("export {}", file: agent.appendingPathComponent("extensions/core-memories/control.ts"))
  let script = fixture.root.appendingPathComponent("fake-pi")
  let log = fixture.root.appendingPathComponent("rpc-input")
  try fixture.write("""
    #!/bin/zsh
    IFS= read -r line
    printf '%s\\n' '{"type":"response","id":"commands","success":true,"data":{"commands":[{"name":"memory-dream-control"},{"name":"memory-dream-cancel"}]}}'
    IFS= read -r line
    printf '%s\\n' "$line" > '\(log.path)'
    printf '%s\\n' '{"type":"extension_ui_request","method":"notify","message":"{\\"version\\":1,\\"type\\":\\"core-memory-control\\",\\"event\\":\\"batchReport\\",\\"report\\":{}}"}'
    printf '%s\\n' '{"type":"extension_ui_request","method":"notify","message":"{\\"version\\":1,\\"type\\":\\"core-memory-control\\",\\"event\\":\\"report\\",\\"report\\":{}}"}'
    printf '%s\\n' '{"type":"response","id":"dream","success":true}'
    while IFS= read -r line; do :; done
    """, file: script)
  #expect(chmod(script.path, 0o700) == 0)
  let events = ControlEvents()
  try DreamControl().run(operation: .all,
    settings: MemoryAppSettings(piExecutable: script.path, agentDirectory: agent.path), roots: nil,
    diagnostics: fixture.root.appendingPathComponent("diagnostics"), onEvent: { events.append($0) })
  #expect(events.events.count == 2)
  let frame = try JSONSerialization.jsonObject(with: Data(contentsOf: log)) as! [String: Any]
  let message = frame["message"] as! String
  #expect(message.hasPrefix("/memory-dream-control "))
  let request = try JSONSerialization.jsonObject(with: Data(message.dropFirst("/memory-dream-control ".count).utf8)) as! [String: Any]
  #expect(Set(request.keys) == ["operation", "roots"])
  #expect(request["roots"] is NSNull)
}
