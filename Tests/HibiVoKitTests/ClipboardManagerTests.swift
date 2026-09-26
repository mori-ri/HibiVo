import AppKit
import Testing

@testable import HibiVoKit

@MainActor
@Suite struct ClipboardManagerTests {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("HibiVoTests-\(UUID().uuidString)"))
    var sut: ClipboardManager { ClipboardManager(pasteboard: pasteboard) }

    @Test(arguments: [
        "今日の15時からAWSのAppSyncについて打ち合わせをします",
        "1行目\n2行目\n\n3行目",
        "了解です🙏👍🏻 よろしく🎉",
        "https://docs.aws.amazon.com/appsync/latest/devguide/ を参照",
        "mori@example.co.jp に送ってください",
        "ABC123 def-456_ghi",
    ])
    func writesTextExactly(_ text: String) {
        _ = sut.write(text, transient: true)
        #expect(pasteboard.string(forType: .string) == text)
    }

    @Test func transientWriteIsMarkedForClipboardManagers() {
        _ = sut.write("x", transient: true)
        #expect(pasteboard.types?.contains(ClipboardManager.transientType) == true)
        _ = sut.write("x", transient: false)
        #expect(pasteboard.types?.contains(ClipboardManager.transientType) == false)
    }

    @Test func restoresMultipleItemsWithAllRepresentations() throws {
        let rtf = Data("{\\rtf1 hello}".utf8)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let first = NSPasteboardItem()
        first.setString("hello", forType: .string)
        first.setData(rtf, forType: .rtf)
        let second = NSPasteboardItem()
        second.setData(png, forType: .png)
        pasteboard.clearContents()
        pasteboard.writeObjects([first, second])

        let snapshot = sut.snapshot()
        let changeCount = sut.write("文字起こし結果", transient: true)
        #expect(sut.restore(snapshot, ifChangeCountIs: changeCount))

        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.count == 2)
        #expect(items[0].string(forType: .string) == "hello")
        #expect(items[0].data(forType: .rtf) == rtf)
        #expect(items[1].data(forType: .png) == png)
        #expect(pasteboard.types?.contains(ClipboardManager.transientType) == false)
    }

    @Test func doesNotRestoreIfUserCopiedSomethingMeanwhile() {
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        let snapshot = sut.snapshot()
        let changeCount = sut.write("transcript", transient: true)

        pasteboard.clearContents()
        pasteboard.setString("user copied this", forType: .string)

        #expect(!sut.restore(snapshot, ifChangeCountIs: changeCount))
        #expect(pasteboard.string(forType: .string) == "user copied this")
    }

    @Test func restoresEmptyClipboard() {
        pasteboard.clearContents()
        let snapshot = sut.snapshot()
        let changeCount = sut.write("transcript", transient: true)
        #expect(sut.restore(snapshot, ifChangeCountIs: changeCount))
        #expect(pasteboard.string(forType: .string) == nil)
    }
}
