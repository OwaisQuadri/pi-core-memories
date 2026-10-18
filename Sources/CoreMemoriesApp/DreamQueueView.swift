import CoreMemories
import SwiftUI

struct DreamQueueView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Dream queue").font(.headline)
        if model.isQueueLoading {
          ProgressView().controlSize(.small).accessibilityLabel("Reading queue")
        }
        Spacer()
        Text("Last \(Int(SessionReader.dreamWindow / 86_400)) days").foregroundStyle(.secondary)
        Text("Undreamt cap \(bytes(SessionReader.dreamBacklogBytes))").foregroundStyle(.secondary)
      }
      if let segments = model.queueCoverage?.segments {
        GeometryReader { geometry in
          HStack(spacing: 0) {
            segment(
              segments.dreamt, total: segments.total, width: geometry.size.width,
              color: .accentColor)
            segment(
              segments.undreamt, total: segments.total, width: geometry.size.width,
              color: .secondary)
            segment(
              segments.free, total: segments.total, width: geometry.size.width,
              color: Color(nsColor: .quaternaryLabelColor))
          }.clipShape(RoundedRectangle(cornerRadius: 3))
        }.frame(height: 10)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Dream queue")
          .accessibilityValue(
            "Dreamt \(segments.dreamt) bytes, undreamt \(segments.undreamt) bytes, free \(segments.free) bytes"
          )
        HStack(spacing: 24) {
          Label("Dreamt \(bytes(segments.dreamt))", systemImage: "checkmark.circle.fill")
            .foregroundStyle(Color.accentColor)
          Label("Undreamt \(bytes(segments.undreamt))", systemImage: "circle.lefthalf.filled")
          Text("Free \(bytes(segments.free))").foregroundStyle(.secondary)
        }.monospacedDigit()
      } else {
        Text(
          model.isQueueLoading ? "Reading queue…" : "Dreamt, undreamt and free capacity are unknown"
        )
        .foregroundStyle(.secondary)
      }
      HStack(spacing: 24) {
        let batch = model.eventCoverage
        Text(
          "\(model.isDreamRunning ? "Current" : "Last") batch \(batch.map { bytes($0.plannedBytes) } ?? "unknown")"
        )
        Text("Next batch \(batch?.nextBytes.map(bytes) ?? "unknown")")
        Spacer()
        if let date = model.queueObservedAt {
          Text("As of \(date.formatted(date: .omitted, time: .standard))").foregroundStyle(
            .secondary)
        }
      }.font(.caption).monospacedDigit()
      if let unavailable = model.queueSnapshot?.unavailableReason {
        Text(unavailable).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
  }

  private func segment(_ count: UInt64, total: UInt64, width: CGFloat, color: Color) -> some View {
    Rectangle().fill(color).frame(width: total == 0 ? 0 : width * Double(count) / Double(total))
  }

  private func bytes(_ count: UInt64) -> String {
    if count == 0 { return "0 B" }
    if count < 1024 { return "\(count) B" }
    if count < 1_048_576 {
      return "\((Double(count) / 1024).formatted(.number.precision(.fractionLength(1)))) KiB"
    }
    return "\((Double(count) / 1_048_576).formatted(.number.precision(.fractionLength(1)))) MiB"
  }
}
