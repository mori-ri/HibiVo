import SwiftUI

struct HUDView: View {
    let state: AppState
    let settings: SettingsStore

    var body: some View {
        HStack(spacing: 8) {
            indicator
            if let label {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.78)))
        .fixedSize()
    }

    @ViewBuilder
    private var indicator: some View {
        switch state.phase {
        case .recording:
            LevelBars(level: state.audioLevel)
        case .processing:
            ProgressView().controlSize(.small).tint(.white)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .idle:
            EmptyView()
        }
    }

    private var label: String? {
        switch state.phase {
        case .recording:
            settings.showLiveTranscript && !state.partialTranscript.isEmpty ? state.partialTranscript : nil
        case .processing: nil
        case .error(let message): message
        case .idle: nil
        }
    }
}

private struct LevelBars: View {
    let level: Float
    /// Centre-heavy envelope: the middle bars reach full height, the edges stay small.
    private let weights: [Float] = [0.3, 0.5, 0.8, 1.0, 0.8, 0.5, 0.3]
    private static let minHeight: CGFloat = 4
    private static let maxHeight: CGFloat = 30

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            // Bars act as a mask over the logo gradient, so the colours sweep across the whole wave.
            LinearGradient(
                colors: [Theme.glowBlue, Theme.glowMagenta, Theme.glowOrange],
                startPoint: .leading, endPoint: .trailing
            )
            .mask {
                HStack(spacing: 2) {
                    ForEach(weights.indices, id: \.self) { i in
                        Capsule().frame(width: 3, height: height(for: i, time: time))
                    }
                }
            }
        }
        .frame(width: CGFloat(weights.count) * 5 - 2, height: Self.maxHeight)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func height(for index: Int, time: TimeInterval) -> CGFloat {
        // Speech RMS is usually < 0.3; boost it and take the square root so quiet speech still
        // moves the bars noticeably, then clamp.
        let normalized = min(1, (level * 8).squareRoot())
        // Each bar wobbles at its own speed while there is sound; the centre wobbles hardest.
        let centreness = 1 - abs(Float(index) - Float(weights.count - 1) / 2) / (Float(weights.count) / 2)
        let wobble = Float(sin(time * (9 + Double(index) * 2.3) + Double(index) * 1.7))
        let amplitude = normalized * weights[index] * (1 + 0.45 * centreness * wobble)
        return Self.minHeight + (Self.maxHeight - Self.minHeight) * CGFloat(min(1, max(0, amplitude)))
    }
}
