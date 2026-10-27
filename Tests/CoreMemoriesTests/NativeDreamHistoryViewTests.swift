import AppKit
import SwiftUI
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

@Test @MainActor func nativeSavedDreamHistoryRendersWithoutStartingAWorker() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let before = try fixture.snapshot(fixture.root)
  let model = AppModel(configURL: fixture.root.appendingPathComponent("unused-profile.json"))
  model.configuration = queueConfiguration(fixture)
  model.isBusy = false
  _ = NSApplication.shared
  let controller = NSHostingController(
    rootView: DreamsView(model: model)
      .environment(\.colorScheme, .light)
      .background(Color(nsColor: .windowBackgroundColor)))
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
    styleMask: [.borderless], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.appearance = NSAppearance(named: .aqua)
  window.contentViewController = controller
  defer { window.close() }
  let host = controller.view
  host.frame = NSRect(x: 0, y: 0, width: 1000, height: 760)
  host.layoutSubtreeIfNeeded()
  window.displayIfNeeded()
  let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
  host.cacheDisplay(in: host.bounds, to: bitmap)
  let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
  #expect(!bytes.isEmpty)
  #expect(try fixture.snapshot(fixture.root) == before)
  if let directory = ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_CAPTURE_DIR"] {
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try bytes.write(to: root.appendingPathComponent("native-saved-dreams.png"), options: .atomic)
  }
}
