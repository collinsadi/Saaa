import AnthropicKit
import Core
import Foundation
import Testing
@testable import Copilot

@MainActor
@Suite struct SendImageTests {

    static var withImage: ScreenSnapshot {
        var snapshot = ScreenSnapshot(appName: "Figma", windowTitle: "Checkout", text: "Pay now", scene: .other)
        snapshot.image = ScreenImage(data: Data([0xFF, 0xD8, 0xFF]), mediaType: "image/jpeg", width: 1_568, height: 980, maskedRegions: 1)
        return snapshot
    }

    static let textOnly = ScreenSnapshot(appName: "Figma", windowTitle: "Checkout", text: "Pay now", scene: .other)

    func defaults(sendImage: Bool) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "saaa.image.\(UUID().uuidString)")!
        defaults.set(sendImage, forKey: LookSettings.sendImageKey)
        return defaults
    }

    func makeEngine(_ claude: MockClaude, sendImage: Bool) -> CopilotEngine {
        let transcript = makeTranscript(lines: 4)
        return CopilotEngine(
            playbook: .general, context: SessionContext(), service: claude, defaults: defaults(sendImage: sendImage),
            transcript: { transcript }, callTime: { 30 },
            screenReader: { SendImageTests.textOnly }, imageReader: { SendImageTests.withImage })
    }

    @Test func thePictureRidesInTheTailBeforeItsText() throws {
        let composer = PromptComposer(playbook: .general, context: SessionContext())
        let request = composer.liveRequest(.look(Self.withImage, question: nil), transcript: makeTranscript(lines: 4), now: 30, recent: [], model: "m")
        let content = try #require(request.messages.first?.content)
        #expect(content[content.count - 2] == .image(mediaType: "image/jpeg", base64: "/9j/"))
        #expect(text(of: try #require(content.last)).contains("A picture of the window is attached too, with secret-looking lines blacked out"))
        // Without a picture the screen block reads exactly as before.
        let plain = composer.liveRequest(.look(Self.textOnly, question: nil), transcript: makeTranscript(lines: 4), now: 30, recent: [], model: "m")
        #expect(!(plain.messages.first?.content.contains { if case .image = $0 { true } else { false } } ?? true))
        #expect(!text(of: try #require(plain.messages.first?.content.last)).contains("picture"))
    }

    @Test func sendImageNeedsTheSetting() async {
        let claude = MockClaude()
        let engine = makeEngine(claude, sendImage: false)
        #expect(!engine.canSendImage)
        engine.look(withImage: true)
        #expect(!engine.isLooking)
        #expect(claude.requests.isEmpty)
    }

    @Test func sendImageSendsOnePictureAndSaysSo() async throws {
        let claude = MockClaude()
        let engine = makeEngine(claude, sendImage: true)
        #expect(engine.canSendImage)
        engine.look(question: "Is this checkout clear?", withImage: true)
        await waitUntil { !engine.isLooking && !engine.isStreaming }
        let exchange = try #require(engine.latest)
        #expect(exchange.title == "Look with image")
        #expect(engine.screenSnapshots[exchange.id]?.image != nil)
        let content = try #require(claude.requests.first?.messages.first?.content)
        #expect(content.contains(.image(mediaType: "image/jpeg", base64: "/9j/")))
        // An ordinary Look still sends text only.
        engine.look()
        await waitUntil { !engine.isLooking && !engine.isStreaming }
        #expect(!(claude.requests.last?.messages.first?.content.contains { if case .image = $0 { true } else { false } } ?? true))
    }

    @Test func codeAssistSendsThePictureToo() async throws {
        let claude = MockClaude()
        let engine = CodeAssistEngine(
            service: claude, defaults: defaults(sendImage: true),
            screenReader: { SendImageTests.textOnly }, imageReader: { SendImageTests.withImage },
            environment: { WatchEnvironment(bundleID: nil, appName: "", windowID: nil, secondsSinceTyping: 9) },
            isCallLive: { false }, startWatching: false)
        engine.look(withImage: true)
        await waitUntil { !engine.isReading && !engine.isStreaming }
        let content = try #require(claude.requests.first?.messages.first?.content)
        #expect(content.first == .image(mediaType: "image/jpeg", base64: "/9j/"))
        #expect(engine.latest?.snapshot.image != nil)
    }
}
