import XCTest
@testable import vMLXApp

final class ImageReuseResolverTests: XCTestCase {
    func testKnownReuseAliasRestoresCatalogModel() {
        let resolution = ImageReuseResolver.resolve(modelAlias: "FLUX.1 Schnell")

        XCTAssertEqual(resolution.selected?.displayName, "FLUX.1 Schnell")
        XCTAssertEqual(resolution.tab, .generate)
        XCTAssertNil(resolution.warning)
    }

    func testUnknownReuseAliasRequiresFreshModelChoice() {
        let resolution = ImageReuseResolver.resolve(modelAlias: "Smoke Image Model")

        XCTAssertNil(resolution.selected)
        XCTAssertEqual(resolution.tab, .generate)
        XCTAssertEqual(resolution.warning?.title, "Choose an image model")
        XCTAssertTrue(
            resolution.warning?.message.contains("Smoke Image Model") == true
        )
        XCTAssertTrue(
            resolution.warning?.message.contains("Pick a proven image model before generating.") == true
        )
    }
}
