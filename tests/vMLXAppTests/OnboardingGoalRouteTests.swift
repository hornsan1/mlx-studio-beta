import XCTest
@testable import vMLXApp

final class OnboardingGoalRouteTests: XCTestCase {
    func testBeginnerGoalRoutesLandOnPromisedWorkflow() {
        XCTAssertEqual(OnboardingGoalRoute.chat.landingMode, .chat)
        XCTAssertEqual(OnboardingGoalRoute.coding.landingMode, .chat)
        XCTAssertEqual(OnboardingGoalRoute.research.landingMode, .chat)
        XCTAssertEqual(OnboardingGoalRoute.images.landingMode, .create)
    }

    func testRouteLabelsMatchLandingModes() {
        for route in OnboardingGoalRoute.allCases {
            XCTAssertEqual(route.landingName, route.landingMode.rawValue)
        }
    }

    func testBeginnerChatRoutesProvideConcretePromptHandoffs() {
        XCTAssertNil(OnboardingGoalRoute.images.chatPromptHandoff)

        let chat = OnboardingGoalRoute.chat.chatPromptHandoff
        XCTAssertEqual(chat?.title, "First local chat")
        XCTAssertTrue(chat?.prompt.contains("first local AI reply") == true)
        XCTAssertEqual(OnboardingGoalRoute.chat.handoffSuccessText, "Prompt ready")

        let coding = OnboardingGoalRoute.coding.chatPromptHandoff
        XCTAssertEqual(coding?.title, "Local coding chat")
        XCTAssertTrue(coding?.prompt.contains("review a code change") == true)
        XCTAssertEqual(OnboardingGoalRoute.coding.handoffSuccessText, "Coding prompt")

        let research = OnboardingGoalRoute.research.chatPromptHandoff
        XCTAssertEqual(research?.title, "Research brief")
        XCTAssertTrue(research?.prompt.contains("research question") == true)
        XCTAssertEqual(OnboardingGoalRoute.research.handoffSuccessText, "Research prompt")
    }

    func testPreparationCopyDoesNotPromiseFolderScanOrTokenSaveBeforeOptIn() {
        let state = OnboardingPreparationState(
            route: .chat,
            landingName: "Chat",
            selectedDirectoryName: nil,
            hasRecommendedStarter: true,
            starterPhase: nil,
            hfToken: ""
        )

        XCTAssertEqual(state.handoffPrepText, "Starter offered")
        XCTAssertEqual(state.modelStepTitle, "Choose model source")
        XCTAssertEqual(state.modelStepCaption, "Starter available")
        XCTAssertTrue(state.folderTokenHelpText.contains("No folder or token selected"))
        XCTAssertFalse(state.folderTokenHelpText.contains("will scan"))
        XCTAssertFalse(state.folderTokenHelpText.contains("save the token"))
    }

    func testPreparationCopyReportsFolderAndTokenWorkWhenSelected() {
        let state = OnboardingPreparationState(
            route: .images,
            landingName: "Create",
            selectedDirectoryName: "LocalModels",
            hasRecommendedStarter: true,
            starterPhase: nil,
            hfToken: " hf_secret "
        )

        XCTAssertEqual(state.handoffPrepText, "Local folder")
        XCTAssertEqual(state.modelStepTitle, "Scan model folder")
        XCTAssertEqual(state.modelStepCaption, "Folder selected")
        XCTAssertTrue(state.folderTokenHelpText.contains("scan LocalModels"))
        XCTAssertTrue(state.folderTokenHelpText.contains("save the token in Keychain"))
        XCTAssertTrue(state.folderTokenHelpText.contains("land you in Create"))
    }

    func testImageRouteKeepsProofGatedPreparationCopy() {
        let state = OnboardingPreparationState(
            route: .images,
            landingName: "Create",
            selectedDirectoryName: nil,
            hasRecommendedStarter: true,
            starterPhase: nil,
            hfToken: ""
        )

        XCTAssertEqual(state.handoffPrepText, "Proof check")
        XCTAssertEqual(state.modelStepTitle, "Check image runtime")
        XCTAssertEqual(state.modelStepCaption, "Proof-gated canvas")
    }

    func testStarterInstallStateUsesSharedInstallVocabulary() {
        let state = OnboardingPreparationState(
            route: .chat,
            landingName: "Chat",
            selectedDirectoryName: nil,
            hasRecommendedStarter: true,
            starterPhase: .downloading,
            hfToken: ""
        )

        XCTAssertEqual(state.handoffPrepText, "Downloading")
        XCTAssertEqual(state.modelStepTitle, "Prepare model")
        XCTAssertEqual(state.modelStepCaption, "Downloading")
    }

    func testAdvancedPreparationCopyPromisesRouteNotServerStartup() {
        let serverState = AdvancedOnboardingPreparationState(openServerAfterSetup: true)

        XCTAssertEqual(serverState.landingName, "Server")
        XCTAssertEqual(serverState.handoffText, "Finish opens Server")
        XCTAssertTrue(serverState.helpText.contains("manual Start/Stop controls"))
        XCTAssertTrue(serverState.helpText.contains("API stays off"))
        XCTAssertFalse(serverState.helpText.localizedCaseInsensitiveContains("starts after"))

        let modelsState = AdvancedOnboardingPreparationState(openServerAfterSetup: false)

        XCTAssertEqual(modelsState.landingName, "Models")
        XCTAssertEqual(modelsState.handoffText, "Finish opens Models")
        XCTAssertTrue(modelsState.helpText.contains("pick or scan a model"))
    }
}
