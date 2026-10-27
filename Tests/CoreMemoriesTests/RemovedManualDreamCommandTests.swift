import Darwin
import Foundation
import Testing

@testable import CoreMemories

@Test(arguments: ["start", "all", "retry", "replace"])
func removedManualDreamCommandsFailWithoutLaunchingPiOrChangingSavedState(_ operation: String)
  throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try savedRecoveryPendingAddition(fixture)
  let pi = fixture.root.appendingPathComponent("fake-pi")
  let marker = fixture.root.appendingPathComponent("pi-started")
  try fixture.write("#!/bin/zsh\nprintf launched > '\(marker.path)'\nexit 97\n", file: pi)
  #expect(chmod(pi.path, 0o700) == 0)
  var configuration = queueConfiguration(fixture)
  configuration.settings = MemoryAppSettings(
    piExecutable: pi.path, agentDirectory: fixture.root.path,
    provider: "synthetic", modelID: "fixture", thinkingLevel: "off",
    controlExtension: fixture.root.appendingPathComponent("absent-control.ts").path)
  let configURL = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: configURL)
  let before = try fixture.snapshot(fixture.root)
  let binary = try #require(
    ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_BIN"]
      ?? ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_EXECUTABLE"])
  let result = try runCommand(
    executable: URL(fileURLWithPath: binary),
    arguments: ["dream", operation, "--config", configURL.path],
    environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path], input: Data())
  #expect(result.status != 0)
  #expect(result.errorText.contains("manual dream operations are unavailable"))
  #expect(!FileManager.default.fileExists(atPath: marker.path))
  #expect(try fixture.snapshot(fixture.root) == before)
}
