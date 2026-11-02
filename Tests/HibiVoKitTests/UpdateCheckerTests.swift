import Foundation
import Testing

@testable import HibiVoKit

@Suite struct AppVersionTests {
    @Test func acceptsOnlyVersionShapedText() {
        #expect(AppVersion("0.6.0")?.text == "0.6.0")
        #expect(AppVersion("v0.6.0-beta.1")?.text == "0.6.0-beta.1")
        #expect(AppVersion("1.2") != nil)
        for text in ["", "v", "latest", "1.2.3.4", "0.6.0 <b>", "0.6.0-", "99999999.0.0"] {
            #expect(AppVersion(text) == nil)
        }
    }

    @Test func comparesNumericallyNotAsText() throws {
        #expect(try #require(AppVersion("0.10.0")) > #require(AppVersion("0.9.9")))
        #expect(try #require(AppVersion("1.0")) == #require(AppVersion("1.0.0")))
    }

    @Test func preReleaseSortsBeforeItsRelease() throws {
        #expect(try #require(AppVersion("0.6.0-beta.1")) < #require(AppVersion("0.6.0")))
        #expect(try #require(AppVersion("0.6.0-beta.1")) > #require(AppVersion("0.5.9")))
    }
}

@MainActor
@Suite struct UpdateCheckerTests {
    private struct Offline: Error {}

    nonisolated private static func releases(_ tags: String...) -> [PublishedRelease] {
        tags.map { PublishedRelease(tagName: $0, body: "## 新機能\n\n- \($0) の機能") }
    }

    @Test func mentionsANewerRelease() async {
        let sut = UpdateChecker(
            currentVersion: "0.5.1", isEnabled: { true }, fetchReleases: { Self.releases("v0.6.0", "v0.5.1") })
        #expect(await sut.check())
        #expect(sut.availableVersion == "0.6.0")
    }

    @Test func staysQuietOnTheSameOrAnOlderRelease() async {
        for tag in ["v0.5.1", "v0.5.0"] {
            let sut = UpdateChecker(currentVersion: "0.5.1", isEnabled: { true }, fetchReleases: { Self.releases(tag) })
            await sut.check()
            #expect(sut.availableVersion == nil)
        }
    }

    @Test func ignoresATagThatIsNotAVersion() async {
        let sut = UpdateChecker(
            currentVersion: "0.5.1", isEnabled: { true }, fetchReleases: { Self.releases("9.9.9 click here") })
        await sut.check()
        #expect(sut.availableVersion == nil)
        #expect(sut.notes.isEmpty)
    }

    @Test func leavesOutDraftsAndPreReleases() async {
        let sut = UpdateChecker(
            currentVersion: "0.5.1", isEnabled: { true },
            fetchReleases: {
                [
                    PublishedRelease(tagName: "v0.7.0", draft: true),
                    PublishedRelease(tagName: "v0.6.0-beta.1", prerelease: true),
                    PublishedRelease(tagName: "v0.5.1"),
                ]
            })
        await sut.check()
        #expect(sut.availableVersion == nil)
        #expect(sut.notes.map(\.version.text) == ["0.5.1"])
    }

    @Test func keepsTheNewestNotesFirst() async {
        let sut = UpdateChecker(
            currentVersion: "0.5.1", isEnabled: { true },
            fetchReleases: { Self.releases("v0.5.0", "v0.10.0", "v0.9.0", "v0.6.0", "v0.7.0", "v0.8.0") })
        await sut.check()
        #expect(sut.notes.map(\.version.text) == ["0.10.0", "0.9.0", "0.8.0", "0.7.0", "0.6.0"])
        let expected: [ReleaseNoteBlock] = [.heading("新機能"), .item(marker: "•", text: "v0.10.0 の機能", level: 0)]
        #expect(sut.notes.first?.blocks == expected)
    }

    @Test func aFailedCheckAsksForARetryAndKeepsTheNotice() async {
        final class Source: @unchecked Sendable {
            var fails = false
        }
        let source = Source()
        let sut = UpdateChecker(
            currentVersion: "0.5.1", isEnabled: { true },
            fetchReleases: {
                if source.fails { throw Offline() }
                return Self.releases("v0.6.0")
            })
        await sut.check()
        source.fails = true
        #expect(await sut.check() == false)
        #expect(sut.availableVersion == "0.6.0")
        #expect(sut.notes.count == 1)
        #expect(sut.loadFailed)
    }

    @Test func turningTheSettingOffSendsNothingAndClearsTheNotice() async {
        final class Calls: @unchecked Sendable {
            var count = 0
        }
        let calls = Calls()
        var enabled = true
        let sut = UpdateChecker(
            currentVersion: "0.5.1", isEnabled: { enabled },
            fetchReleases: {
                calls.count += 1
                return Self.releases("v0.6.0")
            })
        await sut.check()
        enabled = false
        await sut.check()
        #expect(calls.count == 1)
        #expect(sut.availableVersion == nil)
    }

    @Test func notesLoadOnRequestWithoutBringingBackTheNotice() async {
        let sut = UpdateChecker(
            currentVersion: "0.5.1", isEnabled: { false }, fetchReleases: { Self.releases("v0.6.0") })
        await sut.loadNotes()
        #expect(sut.notes.map(\.version.text) == ["0.6.0"])
        #expect(sut.availableVersion == nil)
    }

    @Test func aBuildWithoutAVersionNeverAsks() async {
        let sut = UpdateChecker(currentVersion: nil, isEnabled: { true }, fetchReleases: { throw Offline() })
        #expect(await sut.check())
        #expect(sut.availableVersion == nil)
    }

    @Test func notesAreUnreadUntilTheNewestHasBeenShown() async {
        let sut = UpdateChecker(
            currentVersion: "0.6.0", isEnabled: { true }, fetchReleases: { Self.releases("v0.7.0", "v0.6.0") })
        #expect(!sut.hasUnreadNotes(lastSeen: nil))
        await sut.check()
        #expect(sut.hasUnreadNotes(lastSeen: nil))
        #expect(sut.hasUnreadNotes(lastSeen: "0.6.0"))
        #expect(!sut.hasUnreadNotes(lastSeen: "0.7.0"))
    }

    @Test func decodesGitHubsReleaseList() throws {
        let json = """
            [{"tag_name": "v0.7.0", "body": "## 新機能", "published_at": "2026-10-01T12:00:00Z",
              "prerelease": false, "draft": false, "html_url": "https://github.com/"}]
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let releases = try decoder.decode([PublishedRelease].self, from: Data(json.utf8))
        #expect(releases.first?.tagName == "v0.7.0")
        #expect(releases.first?.publishedAt == Date(timeIntervalSince1970: 1_790_856_000))
    }
}
