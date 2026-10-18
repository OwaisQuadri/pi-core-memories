import CoreMemories
import SwiftUI

struct DreamsView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label(model.dreamPhase, systemImage: "moon.stars").font(.title2.bold())
        Spacer()
        if model.isDreamRunning {
          ProgressView().controlSize(.small)
          Button("Cancel") { model.cancelDream() }
        } else {
          Button("Start") { model.run(.start) }
          Button("Process All") { model.run(.all) }
          Menu("Recovery") {
            Button("Retry Interrupted Call…") { model.isConfirmingRetry = true }
            Button("Replace Invalid Reply…") { model.isConfirmingReplacement = true }
          }
        }
      }
      LabeledContent(
        "Requested",
        value: [
          model.configuration.settings.provider ?? "Pi default",
          model.configuration.settings.modelID ?? "Pi default",
          model.configuration.settings.thinkingLevel ?? "Pi default",
        ].joined(separator: " / "))
      LabeledContent("Resolved", value: model.resolvedSelection)
      if !model.dreamDetail.isEmpty { Text(model.dreamDetail).textSelection(.enabled) }
      HSplitView {
        List {
          if model.inspection?.isBusy == true { Text("Another invocation owns the dream writer") }
          if model.inspection?.isPresent == false { Text("No saved dreams") }
          ForEach(model.inspection?.runs ?? []) { run in
            DisclosureGroup {
              ForEach(run.attempts) { attempt in
                VStack(alignment: .leading, spacing: 5) {
                  Text("Attempt \(attempt.number) · \(attempt.status)").fontWeight(.medium)
                  Text("\(attempt.provider) / \(attempt.modelID) / \(attempt.thinkingLevel)")
                    .font(.caption).textSelection(.enabled)
                  if let diagnostic = attempt.diagnostic {
                    Text(diagnostic).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                  }
                }.padding(.vertical, 5)
              }
              ForEach(run.artifacts) { artifact in
                Button {
                  Task { await model.inspect(artifact) }
                } label: {
                  HStack {
                    Text(artifact.name)
                    Spacer()
                    Text(artifact.byteCount.formatted()).foregroundStyle(.secondary)
                  }
                }.buttonStyle(.plain)
              }
            } label: {
              VStack(alignment: .leading) {
                Text(run.isCompleted ? "Completed" : "Pending").fontWeight(.medium)
                Text(run.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if let diagnostic = run.attempts.last?.diagnostic ?? run.diagnostic {
                  Text(diagnostic).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
              }
            }
          }
        }.frame(minWidth: 280, idealWidth: 340)
        VStack(alignment: .leading) {
          HStack {
            Text(model.selectedArtifact?.name ?? "Saved Artifacts").font(.headline)
            Spacer()
            Button("Reveal in Finder") { Task { await model.revealArtifact() } }.disabled(
              model.selectedArtifact == nil)
          }
          PlainTextView(text: model.artifactText)
        }.padding(12).frame(minWidth: 300)
      }
      if !model.dreamEvents.isEmpty {
        DisclosureGroup("Invocation Events") {
          PlainTextView(text: model.dreamEvents.joined(separator: "\n\n")).frame(height: 150)
        }
      }
    }.padding(20)
      .alert("Retry Interrupted Call?", isPresented: $model.isConfirmingRetry) {
        Button("Cancel", role: .cancel) {}
        Button("Retry") { model.run(.retry) }
      } message: {
        Text(
          "This can make another billable call using the saved request and your current selection.")
      }
      .alert("Replace Invalid Reply?", isPresented: $model.isConfirmingReplacement) {
        Button("Cancel", role: .cancel) {}
        Button("Replace") { model.run(.replace) }
      } message: {
        Text(
          "The rejected reply is retained. A replacement can make another billable call and uses the same frozen validation rules."
        )
      }
  }
}
