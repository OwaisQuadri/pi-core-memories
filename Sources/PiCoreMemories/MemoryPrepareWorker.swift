import CoreMemories
import CryptoKit
import Foundation

func executeMemoryPrepareWorker(arguments: [String]) throws -> Int32 {
  guard arguments == ["memory-prepare-worker"] else {
    throw UsageError(description: "memory preparation accepts no arguments")
  }
  let control = FileHandle(fileDescriptor: try reviewControlDescriptor(), closeOnDealloc: false)
  func readObject() throws -> [String: Any] {
    var bytes = Data()
    while bytes.count < 65_536 {
      guard let byte = try control.read(upToCount: 1), !byte.isEmpty else {
        throw UsageError(description: "preparation control channel closed")
      }
      if byte == Data([10]) {
        return try WorkerJSON.object(bytes)
      }
      bytes.append(byte)
    }
    throw UsageError(description: "preparation control frame too large")
  }
  func send(_ object: [String: Any]) throws {
    let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
  }
  let start = try readObject()
  let isEntryReview = Set(start.keys) == ["repo", "cwd", "base", "entry"]
  guard Set(start.keys) == ["repo"] || isEntryReview, let repo = start["repo"] as? String,
    repo.hasPrefix("/"), !repo.contains("\0")
  else { throw UsageError(description: "invalid preparation repository") }
  let manager = try MemoryManagement(repository: URL(fileURLWithPath: repo))
  if isEntryReview {
    guard let cwd = start["cwd"] as? String, cwd.hasPrefix("/"),
      let base = start["base"] as? String, let index = start["entry"] as? Int
    else { throw UsageError(description: "invalid native entry selection") }
    let catalog = try manager.reviewCatalog(cwd: URL(fileURLWithPath: cwd))
    guard catalog.base == base, catalog.entries.indices.contains(index) else {
      throw UsageError(description: "catalog changed; open native review again")
    }
    let entry = catalog.entries[index]
    let bytes = try JSONEncoder().encode(entry)
    let digest = SHA256.hash(data: Data(base.utf8) + bytes).map { String(format: "%02x", $0) }
      .joined()
    try send([
      "type": "entry", "digest": digest,
      "entry": try JSONSerialization.jsonObject(with: bytes),
    ])
    let choice = try readObject()
    guard Set(choice.keys) == ["digest", "action"], choice["digest"] as? String == digest,
      let action = choice["action"] as? String, ["confirm", "defer", "back"].contains(action)
    else { throw UsageError(description: "invalid native entry review choice") }
    if action == "confirm" { _ = try manager.confirmReviewed(base: base, entry: entry) }
    try send(["type": "result", "status": action == "confirm" ? "reviewed" : "unchanged"])
    return 0
  }
  let preview = try manager.checkoutPreview()
  try send([
    "type": "preview", "digest": preview.digest.rawValue, "commit": preview.commit,
    "main": preview.main, "isDetachRequired": preview.isDetachRequired,
  ])
  let choice = try readObject()
  guard Set(choice.keys) == ["digest", "action"],
    choice["digest"] as? String == preview.digest.rawValue,
    let action = choice["action"] as? String, ["decline", "detach"].contains(action)
  else { throw UsageError(description: "invalid preparation choice") }
  if action == "detach" { try manager.confirmDetach(preview) }
  try send(["type": "result", "status": action == "detach" ? "detached" : "unchanged"])
  return 0
}
