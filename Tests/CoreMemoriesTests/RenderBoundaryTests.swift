import Foundation
import Testing

@testable import CoreMemories

@Test func approvedRenderBoundaryPreservesParagraphAndProjectThematicBreak() throws {
  let annotation = " [source: owner; added: 2024-02-29]"
  for global in [
    "Global" + annotation,
    "Global" + annotation + "\n",
    "Global" + annotation + "\r\n",
    "Global\ncontinued" + annotation,
    "Global\r\ncontinued" + annotation + "\r\n",
    "- Global list item\n  continued" + annotation,
    "- Global list item" + annotation + "\n",
    "- Global list item\r\n  continued" + annotation + "\r\n",
  ] {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let project = try fixture.project("Boundary project")
    let key = try #require(try MemoryStore.projectKey(cwd: project))
    let path = "projects/\(key).md"
    let local = "---\nProject paragraph" + annotation + "\n"
    try fixture.write(global, path: "MEMORY.md")
    try fixture.write(local, path: path)
    try fixture.commit()
    let git = Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment)
    let commit = try fixture.store.approvedCommit()
    let tree = try git.data(["ls-tree", "-r", commit])
    let expected = global + (global.utf8.last == 10 ? "\n" : "\n\n") + local
    #expect(try fixture.store.render(cwd: project) == expected)
    let rendered = try fixture.cli(["render", "--repo", fixture.repo.path, "--cwd", project.path])
    #expect(rendered.status == 0 && rendered.error.isEmpty)
    #expect(rendered.output == Data(expected.utf8))
    let options = AttributedString.MarkdownParsingOptions(appliesSourcePositionAttributes: true)
    let parsed = try AttributedString(markdown: expected, options: options)
    let paragraphs = Set(
      parsed.runs.compactMap { run -> Int? in
        guard let intent = run.presentationIntent?.components.first, intent.kind == .paragraph
        else {
          return nil
        }
        return intent.identity
      })
    #expect(paragraphs.count == 2)
    #expect(
      parsed.runs.contains { $0.presentationIntent?.components.first?.kind == .thematicBreak })
    #expect(
      !parsed.runs.contains {
        guard let kind = $0.presentationIntent?.components.first?.kind else { return false }
        if case .header = kind { return true }
        return false
      })
    #expect(try fixture.store.render(cwd: fixture.root) == global)
    let globalOnly = try fixture.cli([
      "render", "--repo", fixture.repo.path, "--cwd", fixture.root.path,
    ])
    #expect(globalOnly.status == 0 && globalOnly.error.isEmpty)
    #expect(globalOnly.output == Data(global.utf8))
    #expect(try git.data(["cat-file", "blob", "\(commit):MEMORY.md"]) == Data(global.utf8))
    #expect(try git.data(["cat-file", "blob", "\(commit):\(path)"]) == Data(local.utf8))
    #expect(try fixture.store.approvedCommit() == commit)
    #expect(try git.data(["ls-tree", "-r", commit]) == tree)
    #expect(try fixture.store.check().isEmpty)
  }
}

@Test func crlfProjectBoundaryAddsOnlyTheRequiredLF() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let project = try fixture.project("CRLF boundary project")
  let key = try #require(try MemoryStore.projectKey(cwd: project))
  let global = fact("Global 🐢\ncontinued").replacingOccurrences(of: "\n", with: "\r\n")
  let local = ("---\n" + fact("Project 🦊")).replacingOccurrences(of: "\n", with: "\r\n")
  try fixture.write(global, path: "MEMORY.md")
  try fixture.write(local, path: "projects/\(key).md")
  try fixture.commit()
  let expected = Data((global + "\n" + local).utf8)
  #expect(try Data(fixture.store.render(cwd: project).utf8) == expected)
  let rendered = try fixture.cli(["render", "--repo", fixture.repo.path, "--cwd", project.path])
  #expect(rendered.status == 0 && rendered.error.isEmpty && rendered.output == expected)
}
