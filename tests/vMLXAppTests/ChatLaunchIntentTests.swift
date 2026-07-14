import XCTest
@testable import vMLXApp

final class ChatLaunchIntentTests: XCTestCase {
    func testOnboardingHandoffCreatesNewConversationWithPreparedDraft() {
        let handoff = StudioChatPromptHandoff(
            title: "Local coding chat",
            prompt: "Review this local change",
            status: "Prepared"
        )

        XCTAssertEqual(
            ChatLaunchIntent(handoff: handoff),
            ChatLaunchIntent(
                action: .newConversation,
                initialTitle: "Local coding chat",
                initialDraft: "Review this local change"
            )
        )
    }

    func testVMLXChatDeepLinksUseTheSameActions() throws {
        let sessionID = UUID()
        XCTAssertEqual(
            ChatLaunchIntent.chatURL(try XCTUnwrap(URL(string: "vmlx://chat/new"))),
            ChatLaunchIntent(action: .newConversation)
        )
        XCTAssertEqual(
            ChatLaunchIntent.chatURL(
                try XCTUnwrap(URL(string: "vmlx://chat/\(sessionID.uuidString)"))
            ),
            ChatLaunchIntent(action: .openSession(sessionID))
        )
    }

    func testHistoricalSchemeRemainsCompatibleButNonChatRoutesAreIgnored() throws {
        XCTAssertEqual(
            ChatLaunchIntent.chatURL(try XCTUnwrap(URL(string: "mlxstudio://chat/new"))),
            ChatLaunchIntent(action: .newConversation)
        )
        XCTAssertNil(ChatLaunchIntent.chatURL(try XCTUnwrap(URL(string: "vmlx://server/new"))))
        XCTAssertNil(ChatLaunchIntent.chatURL(try XCTUnwrap(URL(string: "https://chat/new"))))
    }

    func testResolvedStarterIdentityIsCarriedWithoutLoading() {
        let identity = ModelIdentity(
            name: "LFM2.5-350M",
            path: "/bundle/Models/LiquidAI/LFM2.5-350M",
            repo: "LiquidAI/LFM2.5-350M"
        )
        XCTAssertEqual(StarterModelResolution.included(identity).resolvedIdentity, identity)
        XCTAssertNil(
            StarterModelResolution.downloadRequired(repo: identity.repo!, bytes: 10, freeBytes: 20)
                .resolvedIdentity
        )
    }
}
