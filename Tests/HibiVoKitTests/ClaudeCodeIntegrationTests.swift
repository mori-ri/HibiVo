import Foundation
import Testing

@testable import HibiVoKit

/// Runs the real Claude Code CLI with the user's subscription login. Opt-in:
///   HIBIVO_INTEGRATION=1 scripts/test.sh --filter ClaudeCodeIntegration
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HIBIVO_INTEGRATION"] == "1"))
struct ClaudeCodeIntegrationTests {
    @Test func writesMinutesFromATranscript() async throws {
        let executable = try #require(ClaudeCodeMinutesWriter.locate(configuredPath: ""))
        let transcript = """
            [00:00:01] **話者1** アップシングの新機能のリリースは来週の水曜日にします。
            [00:00:06] **話者2** では、私がリリースノートを月曜までに書きます。
            [00:00:12] **話者1** お願いします。テストは話者3さんに頼みましょう。
            """
        let written = try await ClaudeCodeMinutesWriter(executable: executable)
            .writeMinutes(
                transcript: transcript, vocabulary: [.init(preferred: "AppSync", spokenForms: ["アップシンク"])],
                model: "haiku")
        #expect(written.usage == nil)
        let minutes = written.text
        let title = MeetingMinutesTitle.split(minutes).title
        print("Minutes title: \(title ?? "(none)")")
        #expect(title != nil)
        #expect(minutes.contains("決定事項"))
        // A near miss of the dictionary's spoken form is corrected to its spelling.
        #expect(minutes.contains("AppSync"))
        #expect(!minutes.contains("アップシング"))
        #expect(minutes.contains("ToDo"))
    }
}
