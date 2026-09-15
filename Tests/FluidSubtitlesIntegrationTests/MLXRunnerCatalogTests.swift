import XCTest
@testable import FluidSubtitles_Debug

final class MLXRunnerCatalogTests: XCTestCase {
    func testCatalogOffersKoreanEnglishThaiJapaneseModels() {
        let catalog = MLXRunnerCatalog.load()
        XCTAssertEqual(catalog.defaultModelID, "gemma4-e4b")
        XCTAssertFalse(catalog.models.isEmpty)
        XCTAssertEqual(MLXRunnerCatalog.resolvedModelID(""), "gemma4-e4b")
        XCTAssertEqual(MLXRunnerCatalog.resolvedModelID("missing"), "gemma4-e4b")

        for model in catalog.models {
            XCTAssertTrue(model.languages.contains("ko"), model.id)
            XCTAssertTrue(model.languages.contains("en"), model.id)
            XCTAssertTrue(model.languages.contains("ja"), model.id)
            XCTAssertTrue(model.languages.contains("th"), model.id)
            XCTAssertFalse(model.repo.isEmpty, model.id)
        }

        let recommended = catalog.models.filter(\.recommended)
        XCTAssertEqual(recommended.map(\.id), ["gemma4-e4b"])
        XCTAssertNotNil(catalog.models.first { $0.id == "gemma4-e4b" })
        XCTAssertNotNil(catalog.models.first { $0.id == "gemma4-26b-a4b" })
    }

    func testJSONCatalogMatchesBundledFallback() {
        let fromDisk = MLXRunnerCatalog.load(from: MLXRunnerCatalog.sourceCatalogURL)
        XCTAssertEqual(fromDisk.models.map(\.id), MLXRunnerCatalog.bundled.models.map(\.id))
        XCTAssertEqual(fromDisk.defaultModelID, MLXRunnerCatalog.bundled.defaultModelID)
        XCTAssertEqual(
            fromDisk.models.first { $0.id == "gemma3-12b" }?.repo,
            "mlx-community/gemma-3-12b-it-4bit-DWQ"
        )
    }

    func testSettingsResolveUnknownModelToDefault() {
        XCTAssertEqual(MLXRunnerCatalog.resolvedModelID("gemma3-4b"), "gemma3-4b")
        XCTAssertEqual(MLXRunnerCatalog.resolvedModelID("qwen3-8b"), "qwen3-8b")
        XCTAssertEqual(MLXRunnerCatalog.resolvedModelID("gemma4-e4b"), "gemma4-e4b")
    }

    func testPastedHuggingFaceRepoStaysCustom() {
        XCTAssertEqual(
            MLXRunnerCatalog.resolvedModelID("mlx-community/some-new-mlx-model"),
            "hf:mlx-community/some-new-mlx-model"
        )
        XCTAssertEqual(
            MLXRunnerCatalog.resolvedModelID("https://huggingface.co/mlx-community/some-new-mlx-model/tree/main"),
            "hf:mlx-community/some-new-mlx-model"
        )
        XCTAssertEqual(
            MLXRunnerCatalog.resolvedModelID("mlx-community/gemma-4-e4b-it-4bit"),
            "gemma4-e4b"
        )
    }

    func testLocalAndLMStudioFoldersStaySelectable() {
        let folder = "/tmp/built-mlx-model"
        XCTAssertEqual(MLXRunnerCatalog.resolvedModelID(folder), "local:/tmp/built-mlx-model")
        XCTAssertEqual(
            MLXRunnerCatalog.resolvedModelID("~/.lmstudio/models/lmstudio-community/gemma-4-31B-it-MLX-4bit"),
            "gemma4-31b"
        )
        XCTAssertEqual(
            MLXRunnerCatalog.parseSpec("/Users/me/.lmstudio/models/custom/my-mlx").kind,
            .lmstudio
        )
        XCTAssertTrue(MLXRunnerCatalog.model(id: "local:/tmp/built-mlx-model")?.isLocalFolder == true)
        XCTAssertFalse(MLXRunnerCatalog.model(id: "gemma4-e4b")?.isLocalFolder == true)
    }
}
