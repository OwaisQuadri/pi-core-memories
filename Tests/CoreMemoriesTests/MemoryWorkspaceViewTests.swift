import AppKit
import SwiftUI
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

@Test @MainActor func memoryWorkspaceViewKeepsLoadingDistinctFromRetainedSaveRecovery() async throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = AppModel(configURL: fixture.configurationURL, autosaveDelay: .seconds(3600))
  model.section = "Memories"
  await model.load()
  try #require(model.failure == nil)
  model.retainedDraft = model.draft
  model.batchProjection = nil
  model.isBusy = true
  model.isReviewLoading = true
  let host = NSHostingView(rootView: MemoryWorkspaceView(model: model))
  host.frame = NSRect(x: 0, y: 0, width: 1000, height: 680)
  host.layoutSubtreeIfNeeded()
  #expect(!memoryWorkspaceDescendants(host).contains { $0 is NSSplitView })
  model.isReviewLoading = false
  host.layoutSubtreeIfNeeded()
  let split = try #require(memoryWorkspaceDescendants(host).compactMap { $0 as? NSSplitView }.first)
  let frame = host.convert(split.bounds, from: split)
  print("MemoryWorkspaceView retained recovery host=\(host.frame) split=\(frame)")
  #expect(frame.minY <= 1)
  #expect(frame.height >= 600)
  model.isBusy = false
  try await model.shutdown()
}

@MainActor private func memoryWorkspaceDescendants(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(memoryWorkspaceDescendants)
}
