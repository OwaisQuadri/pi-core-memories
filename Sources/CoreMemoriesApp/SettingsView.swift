import AppKit
import CoreMemories
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @State private var projectDirectory = ""
  @State private var sharedProjectKey = ""

  var body: some View {
    Form {
      Section("Local Scope") {
        LabeledContent("Device", value: model.configuration.deviceKey ?? "Not configured")
          .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        Button("Set Up This Device") { Task { await model.saveSettings(isSettingUpDevice: true) } }
          .disabled(model.configuration.deviceKey != nil)
        TextField("Local project directory", text: $projectDirectory)
        TextField("Shared project key", text: $sharedProjectKey)
        Button("Bind Local Project") {
          let cwd = projectDirectory
          let key = sharedProjectKey
          Task {
            do {
              let common = try await Task.detached {
                try MemoryStore.projectBindingDirectory(cwd: URL(fileURLWithPath: cwd))
              }.value
              guard let common else { throw WorkspaceError("directory is outside Git") }
              try MemoryScopeConfiguration.validate(
                deviceKey: model.configuration.deviceKey,
                projectBindings: [common: key])
              model.configuration.projectBindings[common] = key
              await model.saveSettings()
            } catch { model.failure = String(describing: error) }
          }
        }
        ForEach(model.configuration.projectBindings.keys.sorted(), id: \.self) { path in
          HStack {
            LabeledContent(path, value: model.configuration.projectBindings[path] ?? "").font(
              .caption
            ).textSelection(.enabled)
            Button("Remove") {
              model.configuration.projectBindings.removeValue(forKey: path)
              Task { await model.saveSettings() }
            }
          }
        }
      }
      Section("Storage") {
        TextField("Agent directory", text: $model.configuration.settings.agentDirectory)
        TextField(
          "Memory repository", text: root(\.memory, fallback: model.configuration.memoryURL.path))
        TextField("Dream state", text: root(\.state, fallback: model.configuration.stateURL.path))
        TextField(
          "Sessions",
          text: root(
            \.sessions, fallback: model.configuration.settings.agentDirectory + "/sessions"))
        TextField("Draft journal", text: $model.configuration.journal)
        TextField("Review state", text: $model.configuration.reviewState)
        TextField("Invocation diagnostics", text: $model.configuration.diagnostics)
      }
      HStack {
        Text(model.configURL.path).font(.caption).textSelection(.enabled)
        Spacer()
        Button("Save Settings") { Task { await model.saveSettings() } }
      }
    }.formStyle(.grouped)
  }

  private func root(_ keyPath: WritableKeyPath<DreamControlRoots, String>, fallback: String)
    -> Binding<String>
  {
    Binding(
      get: { model.configuration.roots?[keyPath: keyPath] ?? fallback },
      set: { value in
        var roots =
          model.configuration.roots
          ?? DreamControlRoots(
            state: model.configuration.stateURL.path,
            sessions: model.configuration.settings.agentDirectory + "/sessions",
            memory: model.configuration.memoryURL.path, snippets: nil, prompts: nil,
            globalAgents: nil)
        roots[keyPath: keyPath] = value
        model.configuration.roots = roots
      })
  }
}
