import AppKit
import CoreMemories
import SwiftUI

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
  var model: AppModel?
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard model != nil else { return .terminateNow }
    Task { sender.reply(toApplicationShouldTerminate: await isTerminationReady()) }
    return .terminateLater
  }

  func isTerminationReady() async -> Bool {
    guard let model else { return true }
    do {
      try await model.shutdown()
      return true
    } catch {
      model.failure = String(describing: error)
      return false
    }
  }
}

@main struct CoreMemoriesApplication: App {
  @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
  @StateObject private var model: AppModel

  init() {
    let arguments = CommandLine.arguments
    let url: URL
    if let index = arguments.firstIndex(of: "--config"), arguments.indices.contains(index + 1) {
      url = URL(fileURLWithPath: arguments[index + 1])
    } else {
      url = MemoryConfiguration.defaultURL
    }
    _model = StateObject(wrappedValue: AppModel(configURL: url))
  }

  var body: some Scene {
    WindowGroup("Core Memories") {
      WorkspaceView(model: model).frame(minWidth: 1000, minHeight: 680)
        .task {
          delegate.model = model
          await model.load()
        }
        .onDisappear {
          model.cancelDream()
          Task {
            do { try await model.shutdown() } catch { model.failure = String(describing: error) }
          }
        }
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Memory") { model.add() }.keyboardShortcut("n").disabled(model.isBusy)
      }
      CommandGroup(replacing: .saveItem) {
        Button("Save Changes") { Task { await model.save() } }.keyboardShortcut("s")
          .disabled(model.operations.isEmpty || model.isBusy)
      }
      CommandGroup(after: .toolbar) {
        Button("Refresh") { Task { await model.refresh() } }.keyboardShortcut("r")
        Button("Cancel Dream") { model.cancelDream() }.keyboardShortcut(".").disabled(
          !model.isDreamRunning)
      }
    }
    Settings { SettingsView(model: model).padding(24).frame(width: 650) }
  }
}

struct WorkspaceView: View {
  @ObservedObject var model: AppModel
  private let sections = ["Dreams", "Review", "Memories", "Changes", "Settings"]
  private let icons = [
    "moon.stars", "checkmark.seal", "text.book.closed", "square.and.pencil", "gearshape",
  ]

  var body: some View {
    NavigationSplitView {
      List(selection: $model.section) {
        ForEach(Array(sections.enumerated()), id: \.element) { index, section in
          Label(section, systemImage: icons[index]).tag(section)
        }
      }.navigationTitle("Core Memories").navigationSplitViewColumnWidth(min: 170, ideal: 190)
    } detail: {
      VStack(spacing: 0) {
        Group {
          switch model.section {
          case "Dreams": DreamsView(model: model)
          case "Review": ReviewView(model: model)
          case "Memories": MemoriesView(model: model)
          case "Changes": ChangesView(model: model)
          default: ScrollView { SettingsView(model: model).padding(24) }
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(model.isBusy)
        Divider()
        HStack {
          if model.isBusy { ProgressView().controlSize(.small) }
          Text(model.message).font(.caption).lineLimit(2).textSelection(.enabled)
          Spacer()
          if !model.operations.isEmpty {
            Text(model.operations.count == 1 ? "1 change" : "\(model.operations.count) changes")
              .font(.caption)
          }
        }.padding(.horizontal, 16).padding(.vertical, 9)
      }.navigationTitle(model.section)
        .toolbar {
          Button {
            Task { await model.refresh() }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          Button {
            Task { await model.prepareCheckout() }
          } label: {
            Label("Prepare Checkout", systemImage: "lock.open")
          }
          Button {
            Task { await model.save() }
          } label: {
            Label("Save Changes", systemImage: "square.and.arrow.down")
          }
          .disabled(model.operations.isEmpty || model.isBusy)
        }
    }
    .alert(
      "Operation failed",
      isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })
    ) {
      Button("OK", role: .cancel) { model.failure = nil }
    } message: {
      Text(model.failure ?? "")
    }
    .sheet(
      isPresented: Binding(get: { model.checkout != nil }, set: { if !$0 { model.checkout = nil } })
    ) {
      VStack(alignment: .leading, spacing: 18) {
        Text("Prepare Checkout").font(.title2.bold())
        if let checkout = model.checkout {
          Text(
            checkout.isDetachRequired
              ? "Detach the initialization checkout before publishing. Its commit, index, and working files stay unchanged. This does not approve memory."
              : "The checkout is already prepared.")
          Text(checkout.commit).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          HStack {
            Spacer()
            Button("Cancel", role: .cancel) { model.checkout = nil }.keyboardShortcut(.cancelAction)
            if checkout.isDetachRequired {
              Button("Detach Checkout") { Task { await model.detach() } }
            }
          }
        }
      }.padding(24).frame(width: 530)
    }
  }
}

struct PlainTextView: NSViewRepresentable {
  let text: String
  func makeNSView(context: Context) -> NSScrollView {
    let view = NSTextView()
    view.isEditable = false
    view.isSelectable = true
    view.isRichText = false
    view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    view.autoresizingMask = [.width]
    view.textContainerInset = NSSize(width: 10, height: 10)
    view.textContainer?.widthTracksTextView = true
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = view
    return scroll
  }
  func updateNSView(_ view: NSScrollView, context: Context) {
    guard let editor = view.documentView as? NSTextView else { return }
    if editor.string != text { editor.string = text }
  }
}
