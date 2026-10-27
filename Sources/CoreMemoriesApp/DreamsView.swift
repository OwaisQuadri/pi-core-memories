import CoreMemories
import SwiftUI

struct DreamsView: View {
  @ObservedObject var model: AppModel
  @State private var isShowingDetails = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Label("Saved dreams", systemImage: "moon.stars").font(.title2.bold())
        Text(statusTitle).font(.headline)
        if !model.dreamDetail.isEmpty, model.invocationStatus?.isPublicationBlocked != true,
          model.dreamPhase != "Status unavailable"
        {
          Text(model.dreamDetail).textSelection(.enabled)
        }
        DreamQueueView(model: model)
        HStack {
          if model.savedRecoveryRunID != nil {
            Button("Prepare Saved Suggestions…") {
              Task { await model.prepareSavedRecovery() }
            }.fixedSize()
          }
          Button(model.reviewActionTitle) { model.section = "Memories" }.fixedSize()
          Spacer()
        }
        DisclosureGroup("Details", isExpanded: $isShowingDetails) {
          details
        }
      }.padding(20)
    }
    .sheet(
      isPresented: Binding(
        get: { model.savedRecovery != nil },
        set: { if !$0 { Task { await model.cancelSavedRecovery() } } })
    ) {
      VStack(alignment: .leading, spacing: 16) {
        Text("Prepare Saved Suggestions").font(.title2.bold())
        Text(
          "No model call or charge. Nothing is saved into memory now. Review and stage each suggestion, then choose Save Changes once."
        )
        if let recovery = model.savedRecovery {
          Text("\(recovery.actionableCount) ready to review").font(.headline)
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              ForEach(recovery.suggestions, id: \.change.id) { suggestion in
                VStack(alignment: .leading, spacing: 6) {
                  Text(MemoryDocument.reviewText(suggestion.change.after))
                  Text(
                    MemoryScopeConfiguration.label(
                      path: suggestion.change.path, deviceKey: model.configuration.deviceKey)
                  )
                  .font(.caption).foregroundStyle(.secondary)
                  if let blocker = suggestion.blocker {
                    Text(blocker).foregroundStyle(.orange)
                  }
                }
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
          HStack {
            Spacer()
            Button("Cancel", role: .cancel) { Task { await model.cancelSavedRecovery() } }
            Button("Prepare for Review") { Task { await model.confirmSavedRecovery() } }
              .disabled(model.isBusy)
          }
        }
      }.padding(24).frame(width: 640, height: 520)
        .environment(\.isEnabled, true)
    }
  }

  private var statusTitle: String {
    if model.dreamInspectionFailure != nil { return "Saved dream details unavailable" }
    if let status = model.invocationStatus {
      switch status.status {
      case "completed": return "Saved processing completed"
      case "noNewRecords": return "Last saved report: no new conversations"
      case "pending":
        return status.isPublicationBlocked
          ? "Saved suggestions are waiting" : "Saved work needs attention"
      default: return "Last saved report: \(status.title)"
      }
    }
    if model.dreamPhase == "Status unavailable" { return model.dreamPhase }
    if let run = model.inspection?.runs.first, !run.isCompleted {
      return runTitle(run)
    }
    return model.dreamPhase == "Idle"
      ? "No saved invocation status" : model.dreamPhase
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let unavailable = model.dreamInspectionFailure {
        Text(unavailable).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if model.invocationStatus?.isPublicationBlocked == true
        || model.dreamPhase == "Status unavailable"
      {
        Text(model.dreamDetail).textSelection(.enabled)
      }
      if let detail = model.invocationStatus?.detail, !detail.isEmpty {
        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if let unavailable = model.queueSnapshot?.unavailableReason {
        Text(unavailable).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if let date = model.invocationStatus?.observedAt {
        LabeledContent(
          "Last saved report", value: date.formatted(date: .abbreviated, time: .standard))
      }
      HSplitView {
        List {
          if model.inspection?.isBusy == true { Text("Another invocation is saving dream work") }
          if model.inspection?.isPresent == false { Text("No saved dream work") }
          ForEach(model.inspection?.runs ?? []) { run in
            DisclosureGroup {
              Text(run.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              ForEach(run.attempts) { attempt in
                VStack(alignment: .leading, spacing: 5) {
                  Text("Attempt \(attempt.number + 1) · \(attempt.status)").fontWeight(.medium)
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
                Text(runTitle(run)).fontWeight(.medium)
                if let generation = run.generation {
                  Text("Saved batch · generation \(generation)").font(.caption).monospacedDigit()
                }
                if let diagnostic = run.attempts.last?.diagnostic ?? run.diagnostic {
                  Text(diagnostic).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
              }
            }
          }
        }.frame(minWidth: 260, idealWidth: 320)
        VStack(alignment: .leading) {
          HStack {
            Text(model.selectedArtifact?.name ?? "Saved Artifacts").font(.headline)
            Spacer()
            Button("Reveal in Finder") { Task { await model.revealArtifact() } }.disabled(
              model.selectedArtifact == nil
            ).fixedSize()
          }
          PlainTextView(text: model.artifactText)
        }.padding(12).frame(minWidth: 300)
      }.frame(height: 320)
    }.padding(.top, 12)
  }

  private func runTitle(_ run: SavedDreamRun) -> String {
    if model.invocationStatus?.runID == run.id {
      return model.invocationStatus?.isPublicationBlocked == true
        ? "Saved suggestions are waiting"
        : model.invocationStatus?.title ?? "Saved work needs attention"
    }
    if run.isCompleted { return "Processing completed" }
    switch run.attempts.last?.status {
    case "Reply valid": return "Saved suggestions are waiting"
    case "Rejected reply": return "Saved reply was rejected"
    default: return "Saved work; completion not established"
    }
  }
}
