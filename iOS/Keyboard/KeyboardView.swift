import SwiftUI
import UIKit

struct KeyboardView: View {
    let model: KeyboardModel
    let keys: KeyboardKeys

    var body: some View {
        VStack(spacing: 8) {
            status
                .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
            HStack {
                cancelButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
                micButton
                    .padding(.horizontal, 20)
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 1)
            }
            .frame(maxHeight: .infinity)
            keyRow
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.phase)
    }

    // MARK: - Status

    @ViewBuilder
    private var status: some View {
        if let notice = model.notice {
            Label(notice, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 13))
                .lineLimit(2)
        } else if !model.hasFullAccess {
            Text("「設定」›「一般」›「キーボード」›「キーボード」›「HibiVo」で「フルアクセスを許可」をオンにしてください")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        } else {
            switch model.phase {
            case .inactive:
                hint(model.isChecking ? "" : "マイクを押すと HibiVo が開きます。開いたら、この画面に戻ってください")
            case .ready:
                hint("マイクを押して話す")
            case .recording:
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: true)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Theme.glowBlue, Theme.glowMagenta, Theme.glowOrange], startPoint: .leading,
                                endPoint: .trailing))
                    Text(model.partial.isEmpty ? String(localized: "聞いています…") : model.partial)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        // Keep the newest words in view.
                        .truncationMode(.head)
                }
            case .processing:
                hint("入力しています…")
            }
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }

    // MARK: - Microphone

    private var micButton: some View {
        Button(action: model.micTapped) {
            ZStack {
                Circle().fill(model.phase == .recording ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                if model.phase == .processing || model.isChecking {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 72, height: 72)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!model.hasFullAccess || model.phase == .processing || model.isChecking)
        .opacity(model.hasFullAccess ? 1 : 0.4)
        .accessibilityLabel(model.phase == .recording ? Text("録音を終了") : Text("音声入力"))
    }

    @ViewBuilder
    private var cancelButton: some View {
        if model.phase == .recording || model.phase == .processing {
            Button(action: model.cancelTapped) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(KeyStyle.fill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("キャンセル"))
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
    }

    // MARK: - Keys

    private var keyRow: some View {
        HStack(spacing: 6) {
            if let inputModeSwitch = keys.inputModeSwitch {
                inputModeSwitch
                    .frame(width: 44, height: KeyStyle.height)
                    .background(KeyStyle.fill, in: KeyStyle.shape)
            }
            textKey("、")
            textKey("。")
            Button {
                keys.insert(" ")
            } label: {
                Text("空白")
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, minHeight: KeyStyle.height)
                    .background(KeyStyle.fill, in: KeyStyle.shape)
            }
            Button(action: keys.deleteBackward) {
                Image(systemName: "delete.left")
                    .frame(width: 48, height: KeyStyle.height)
                    .background(KeyStyle.fill, in: KeyStyle.shape)
            }
            .buttonRepeatBehavior(.enabled)
            .accessibilityLabel(Text("削除"))
            Button {
                keys.insert("\n")
            } label: {
                Image(systemName: "return")
                    .frame(width: 56, height: KeyStyle.height)
                    .background(KeyStyle.fill, in: KeyStyle.shape)
            }
            .accessibilityLabel(Text("改行"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func textKey(_ text: String) -> some View {
        Button {
            keys.insert(text)
        } label: {
            Text(verbatim: text)
                .font(.system(size: 18))
                .frame(width: 40, height: KeyStyle.height)
                .background(KeyStyle.fill, in: KeyStyle.shape)
        }
    }
}

/// Keys look like the system keyboard's: white on the light keyboard, translucent white on the dark one.
private enum KeyStyle {
    static let height: CGFloat = 44
    static let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    static let fill = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.22) : .white
        })
}
