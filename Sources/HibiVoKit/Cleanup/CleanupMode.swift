public enum CleanupMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case raw
    case natural
    case business
    case prompt
    /// Follows instructions the user wrote in settings (`SettingsStore.customCleanupInstructions`).
    case custom

    /// Most characters the custom instructions may have. Keeps the system prompt, sent with every utterance, small:
    /// about as long as the longest built-in mode's own rules (Business, ~460 characters).
    public static let customInstructionsLimit = 500

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .raw: String(localized: "Raw（そのまま）")
        case .natural: String(localized: "Natural（自然な文章）")
        case .business: String(localized: "Business（丁寧な文章）")
        case .prompt: String(localized: "Prompt（AI への指示）")
        case .custom: String(localized: "Custom（カスタム指示）")
        }
    }
}

extension CleanupMode {
    /// One line on what the mode does, shown next to its sample.
    public var summary: String {
        switch self {
        case .raw: String(localized: "AI を使わず、文字起こしの結果をそのまま入力します。フィラーや言い直しも残ります。")
        case .natural: String(localized: "フィラーと言い直しを除き、話した口調のまま読みやすく整えます。")
        case .business: String(localized: "敬語に直し、メールやチャットでそのまま送れる丁寧な文章にします。")
        case .prompt: String(localized: "AI への指示として整えます。口調は変えず、列挙した項目は箇条書きにします。")
        case .custom: String(localized: "Natural と同じ基本の整形に加えて、設定に書いた指示に従います。")
        }
    }

    /// What this mode would make of `CleanupSample.spoken`. Hand-written to show the differences; real output
    /// depends on the model. nil for Custom, whose output depends on the user's own instructions.
    public var sampleOutput: String? {
        switch self {
        case .raw:
            CleanupSample.spoken
        case .natural:
            "昨日送ったデザイン案なんだけど、見出しの色をもうちょっと明るくして、余白も広げてほしい。\n金曜までにできるか教えて。"  // no-l10n
        case .business:
            "昨日お送りしたデザイン案ですが、見出しの色をもう少し明るくして、余白も広げていただきたいです。\n金曜までにできるか教えていただけますか。"  // no-l10n
        case .prompt:
            "昨日送ったデザイン案なんだけど、\n- 見出しの色をもうちょっと明るくする\n- 余白を広げる\nをしてほしい。\n金曜までにできるか教えて。"  // no-l10n
        case .custom:
            nil
        }
    }
}

/// The utterance every mode's `sampleOutput` starts from, so the samples can be compared side by side.
public enum CleanupSample {
    public static let spoken =
        "えーと昨日送ったデザイン案なんだけど、ボタンの色を、あ、いや、見出しの色をもうちょっと明るくして、あと余白も広げてほしい。で金曜までにできるか教えて"  // no-l10n
}
