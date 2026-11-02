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

    @Test func mentionsANewerRelease() async {
        let sut = UpdateChecker(currentVersion: "0.5.1", isEnabled: { true }, fetchLatest: { "v0.6.0" })
        #expect(await sut.check())
        #expect(sut.availableVersion == "0.6.0")
    }

    @Test func staysQuietOnTheSameOrAnOlderRelease() async {
        for tag in ["v0.5.1", "v0.5.0"] {
            let sut = UpdateChecker(currentVersion: "0.5.1", isEnabled: { true }, fetchLatest: { tag })
            await sut.check()
            #expect(sut.availableVersion == nil)
        }
    }

    @Test func ignoresATagThatIsNotAVersion() async {
        let sut = UpdateChecker(currentVersion: "0.5.1", isEnabled: { true }, fetchLatest: { "9.9.9 click here" })
        await sut.check()
        #expect(sut.availableVersion == nil)
    }

    @Test func aFailedCheckAsksForARetryAndKeepsTheNotice() async {
        final class Source: @unchecked Sendable {
            var fails = false
        }
        let source = Source()
        let sut = UpdateChecker(
            currentVersion: "0.5.1", isEnabled: { true },
            fetchLatest: {
                if source.fails { throw Offline() }
                return "v0.6.0"
            })
        await sut.check()
        source.fails = true
        #expect(await sut.check() == false)
        #expect(sut.availableVersion == "0.6.0")
    }

    @Test func turningTheSettingOffSendsNothingAndClearsTheNotice() async {
        final class Calls: @unchecked Sendable {
            var count = 0
        }
        let calls = Calls()
        var enabled = true
        let sut = UpdateChecker(
            currentVersion: "0.5.1", isEnabled: { enabled },
            fetchLatest: {
                calls.count += 1
                return "v0.6.0"
            })
        await sut.check()
        enabled = false
        await sut.check()
        #expect(calls.count == 1)
        #expect(sut.availableVersion == nil)
    }

    @Test func aBuildWithoutAVersionNeverAsks() async {
        let sut = UpdateChecker(currentVersion: nil, isEnabled: { true }, fetchLatest: { throw Offline() })
        #expect(await sut.check())
        #expect(sut.availableVersion == nil)
    }
}
