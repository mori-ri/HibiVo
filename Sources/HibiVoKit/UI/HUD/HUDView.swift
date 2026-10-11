import SwiftUI

/// What the HUD's buttons do. Only the meeting HUD has buttons; elsewhere the whole HUD is one target.
struct HUDActions {
    var stopMeeting: @MainActor () -> Void = {}
    var toggleMeetingNotes: @MainActor () -> Void = {}
}

/// State of the HUD itself. Stopping a meeting from the HUD takes two clicks, because a stray click
/// would end a recording that can't be redone: the first arms the button, the second stops.
@MainActor
@Observable
final class HUDModel {
    static let confirmationWindow: Duration = .seconds(3)

    private(set) var stopArmed = false
    @ObservationIgnored private var disarm: Task<Void, Never>?

    /// A click on the stop button. True when it confirms an armed stop.
    func confirmStop() -> Bool {
        if stopArmed {
            reset()
            return true
        }
        stopArmed = true
        disarm?.cancel()
        disarm = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmationWindow)
            guard !Task.isCancelled else { return }
            self?.stopArmed = false
        }
        return false
    }

    func reset() {
        disarm?.cancel()
        stopArmed = false
    }
}

struct HUDView: View {
    let state: AppState
    let settings: SettingsStore
    var model = HUDModel()
    var actions = HUDActions()

    var body: some View {
        if state.phase == .idle, !state.learnedVocabulary.isEmpty {
            LearnedNotice(corrections: state.learnedVocabulary.map(\.correction))
        } else if state.phase == .meeting {
            meetingCapsule
        } else {
            capsule
        }
    }

    /// Laid out so the buttons stay put: the transcript has a fixed width, and stop sits at the far end,
    /// apart from the notes button, with the level meter between them.
    private var meetingCapsule: some View {
        HStack(spacing: 8) {
            MeetingBadge(startedAt: state.meetingStartedAt ?? Date())
            HUDPillButton(symbol: "note.text", title: "メモ", help: "メモを表示・非表示", action: actions.toggleMeetingNotes)
            if settings.showLiveTranscript || state.meetingReconnecting {
                Text(meetingLabel ?? String(localized: "聞き取り中…"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(meetingLabel == nil ? 0.45 : 1))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(width: 260, alignment: .leading)
            }
            // White: nothing is cleaned up or pasted in a meeting.
            LevelBars(level: state.audioLevel, colorful: false)
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 4)
            StopMeetingButton(armed: model.stopArmed, action: actions.stopMeeting)
        }
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .padding(.vertical, 6.4)
        .background(Capsule().fill(.black.opacity(0.78)))
        .fixedSize()
    }

    private var meetingLabel: String? {
        if state.meetingReconnecting { return String(localized: "再接続中…") }
        return state.partialTranscript.isEmpty ? nil : state.partialTranscript
    }

    private var capsule: some View {
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
        .padding(.vertical, 6.4)
        .background(Capsule().fill(.black.opacity(0.78)))
        .fixedSize()
    }

    @ViewBuilder
    private var indicator: some View {
        switch state.phase {
        case .recording:
            LevelBars(level: state.audioLevel, colorful: settings.cleanupEnabled)
        case .processing:
            ProgressView().controlSize(.small).tint(.white)
        case .meeting:
            EmptyView()
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
        case .meeting: nil
        case .error(let message): message
        case .idle: nil
        }
    }
}

/// The words just added to the dictionary. A card of its own with a hint of the brand gradient and a
/// short slide-in, because it appears while the user is busy typing and is easy to miss.
/// The whole card is the undo target (`HUDHostingView` takes the click).
private struct LearnedNotice: View {
    let corrections: [VocabularyCorrection]
    @State private var appeared = false
    private static let maxShown = 3

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(gradient))
            VStack(alignment: .leading, spacing: 3) {
                Text("辞書に追加しました")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                ForEach(corrections.prefix(Self.maxShown), id: \.self) { correction in
                    HStack(spacing: 6) {
                        Text(correction.original).foregroundStyle(.white.opacity(0.6))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.45))
                        Text(correction.corrected).fontWeight(.semibold)
                    }
                    .font(.system(size: 13))
                    .lineLimit(1)
                }
                if corrections.count > Self.maxShown {
                    Text("ほか \(corrections.count - Self.maxShown) 件")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: 300, alignment: .leading)
            Label("取り消す", systemImage: "arrow.uturn.backward")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.1)))
        }
        .foregroundStyle(.white)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.8))
            RoundedRectangle(cornerRadius: 14).strokeBorder(gradient.opacity(0.5), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .scaleEffect(appeared ? 1 : 0.95)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
        // Room for the shadow, which the panel would otherwise clip.
        .padding(10)
        .fixedSize()
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { appeared = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("クリックすると辞書への追加を取り消します")
    }

    private var gradient: LinearGradient { Theme.brandGradient }
}

/// A labelled button on the dark capsule.
private struct HUDPillButton: View {
    let symbol: String
    let title: LocalizedStringKey
    let help: LocalizedStringKey
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(.white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Square stop symbol, like a recorder. The first click turns it into a red "click again" pill.
private struct StopMeetingButton: View {
    let armed: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                if armed {
                    Text("もう一度押して終了").font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(.white.opacity(armed ? 1 : 0.85))
            .padding(.horizontal, armed ? 9 : 0)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(armed ? Color.red : .white.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(armed ? "もう一度押すとミーティングを終了します" : "ミーティングを終了(2 回押す)")
        .accessibilityLabel(armed ? "もう一度押してミーティングを終了" : "ミーティングを終了")
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: armed)
    }
}

/// Red dot and elapsed time, so a long meeting recording is always visibly on.
private struct MeetingBadge: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(Self.elapsed(from: startedAt, to: timeline.date))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct LevelBars: View {
    let level: Float
    /// Logo colours when AI cleanup is on, plain white when the raw transcript will be pasted.
    let colorful: Bool
    /// Centre-heavy envelope: the middle bars reach full height, the edges stay small.
    private let weights: [Float] = [0.3, 0.5, 0.8, 1.0, 0.8, 0.5, 0.3]
    private static let minHeight: CGFloat = 4
    private static let maxHeight: CGFloat = 24

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            // Bars act as a mask over the logo gradient, so the colours sweep across the whole wave.
            LinearGradient(
                colors: colorful ? [Theme.glowBlue, Theme.glowMagenta, Theme.glowOrange] : [.white],
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
        .animation(.easeInOut(duration: 0.2), value: colorful)
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
