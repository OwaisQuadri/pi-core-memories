import CoreMemories
import Foundation

struct NativeMemoryScopeNames: Sendable {
  private var projects: [String: Set<String>] = [:]

  static func prepare(
    configuration: MemoryConfiguration, candidates: [MemoryReviewCandidate]
  ) -> Self {
    var result = Self()
    for (directory, key) in configuration.projectBindings {
      if let name = projectName(gitDirectory: directory) {
        result.projects[key, default: []].insert(name)
      }
    }
    var contexts: [String: Set<String>] = [:]
    for candidate in candidates {
      let key: String
      switch DreamMemoryScope(path: candidate.change.path) {
      case .project(let project), .deviceProject(_, let project): key = project
      default: continue
      }
      for source in candidate.change.sources {
        if let directory = source.projectScope, directory.hasPrefix("/") {
          contexts[directory, default: []].insert(key)
        }
      }
    }
    for (directory, targets) in contexts {
      let cwd = URL(fileURLWithPath: directory)
      guard
        let key = try? MemoryStore.projectKey(
          cwd: cwd, projectBindings: configuration.projectBindings), targets.contains(key),
        let canonical = try? MemoryStore.projectBindingDirectory(cwd: cwd),
        let name = projectName(gitDirectory: canonical)
      else { continue }
      result.projects[key, default: []].insert(name)
    }
    return result
  }

  func label(path: String, deviceKey: String?) -> String {
    switch DreamMemoryScope(path: path) {
    case .global: "Global"
    case .project(let key): projectLabel(key)
    case .device(let key): key == deviceKey ? "This device" : "Another device"
    case .deviceProject(let device, let project):
      projectLabel(project) + " · " + (device == deviceKey ? "This device" : "Another device")
    case nil: "Unknown scope"
    }
  }

  private func projectLabel(_ key: String) -> String {
    guard let names = projects[key], !names.isEmpty else { return "Project (name unavailable)" }
    return names.count == 1 ? names.first! : "Project (ambiguous name)"
  }

  private static func projectName(gitDirectory: String) -> String? {
    let url = URL(fileURLWithPath: gitDirectory)
    let name =
      url.lastPathComponent == ".git"
      ? url.deletingLastPathComponent().lastPathComponent
      : (url.pathExtension == "git" ? url.deletingPathExtension() : url).lastPathComponent
    guard !name.isEmpty, name != "/",
      name.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) == nil
    else { return nil }
    return name
  }
}

extension AppModel {
  func scopeLabel(path: String) -> String {
    memoryScopeNames.label(path: path, deviceKey: configuration.deviceKey)
  }

  func memoryPath(for item: MemoryBatchItem) -> String? {
    switch item.intent {
    case .manual(let intent): intent.request.path
    case .confirmReviewed(let intent): intent.entry.path
    case .candidate(let intent):
      (candidates + (batchProjection?.retainedCandidates ?? [])).first {
        $0.change.id.rawValue == intent.candidateID
      }?.change.path
    }
  }

  func configuredProjectDirectories(path: String) -> [String] {
    let key: String
    switch DreamMemoryScope(path: path) {
    case .project(let project), .deviceProject(_, let project): key = project
    default: return []
    }
    return configuration.projectBindings.filter { $0.value == key }.keys.sorted()
  }

  var selectedMemoryPath: String? {
    if let item = selectedItem { return memoryPath(for: item) }
    if let candidate = selectedCandidate { return candidate.change.path }
    switch selection {
    case .entry(let path, _): return path
    case .newMemory: return editorPath
    default: return nil
    }
  }
}
