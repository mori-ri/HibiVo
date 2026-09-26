import SwiftUI

struct HUDView: View {
    let state: AppState

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
        case .recording: state.partialTranscript.isEmpty ? nil : state.partialTranscript
        case .processing: nil
        case .error(let message): message
        case .idle: nil
        }
    }
}

private struct LevelBars: View {
    let level: Float
    private let weights: [Float] = [0.55, 0.85, 1.0, 0.75, 0.5]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(.red)
                    .frame(width: 3, height: height(for: weights[i]))
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func height(for weight: Float) -> CGFloat {
        // Speech RMS is usually < 0.3, so scale up and clamp.
        let normalized = min(1, level * 5)
        return CGFloat(4 + 14 * normalized * weight)
    }
}
