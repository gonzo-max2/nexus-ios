import XCTest

/// Guards the test-build "invisible app" contract: on the Home Screen the app and
/// its screen-broadcast extension must show neither a label nor a visible icon
/// tile. `scripts/verify_hidden_app.py` checks the same contract at the source and
/// artifact level (also on Linux); these tests assert it at runtime inside the
/// built bundle that CI produces.
final class InvisibleAppTests: XCTestCase {
    private static let appBundleIdentifier = "com.nexus.selfmonitor.app"

    /// Visually blank symbols that Unicode does not classify as separators
    /// (braille pattern blank and the two Hangul fillers).
    private static let blankScalarValues: Set<UInt32> = [0x2800, 0x3164, 0xFFA0]

    /// General categories that never render as visible text: format characters
    /// (zero-width space, byte-order mark), control characters and separators.
    private static let invisibleGeneralCategories: Set<Unicode.GeneralCategory> = [
        .format, .control, .spaceSeparator, .lineSeparator, .paragraphSeparator,
    ]

    private enum BundleLookupError: Error {
        case hostApplicationNotFound
    }

    // MARK: - Helpers

    /// The app bundle hosting this test bundle (XcodeGen wires a test host), with a
    /// path walk as a fallback so the lookup does not depend on TEST_HOST alone.
    private func hostApplicationBundle(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Bundle {
        if Bundle.main.bundleIdentifier == Self.appBundleIdentifier {
            return Bundle.main
        }
        var candidateURL = Bundle(for: InvisibleAppTests.self).bundleURL
        for _ in 0..<6 {
            candidateURL.deleteLastPathComponent()
            if let candidate = Bundle(url: candidateURL),
               candidate.bundleIdentifier == Self.appBundleIdentifier {
                return candidate
            }
        }
        XCTFail("could not locate the \(Self.appBundleIdentifier) host app bundle", file: file, line: line)
        throw BundleLookupError.hostApplicationNotFound
    }

    private func visibleScalars(in name: String) -> [Unicode.Scalar] {
        name.unicodeScalars.filter { scalar in
            if scalar.properties.isWhitespace { return false }
            if Self.blankScalarValues.contains(scalar.value) { return false }
            return !Self.invisibleGeneralCategories.contains(scalar.properties.generalCategory)
        }
    }

    private func assertDisplayNameInvisible(
        of bundle: Bundle,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        guard let displayName, !displayName.isEmpty else {
            XCTFail("\(label): CFBundleDisplayName is missing or empty", file: file, line: line)
            return
        }
        let visible = visibleScalars(in: displayName)
        let described = visible.map { "U+\(String($0.value, radix: 16, uppercase: true))" }
        XCTAssertTrue(
            visible.isEmpty,
            "\(label): display name \(displayName.debugDescription) renders visible glyphs \(described)",
            file: file,
            line: line
        )
    }

    // MARK: - Tests

    func testApplicationDisplayNameIsInvisible() throws {
        assertDisplayNameInvisible(of: try hostApplicationBundle(), label: "app")
    }

    func testScreenBroadcastExtensionDisplayNameIsInvisible() throws {
        let app = try hostApplicationBundle()
        let pluginsURL = try XCTUnwrap(app.builtInPlugInsURL, "app bundle has no PlugIns directory")
        let pluginContents = try FileManager.default.contentsOfDirectory(
            at: pluginsURL,
            includingPropertiesForKeys: nil
        )
        let appexURL = try XCTUnwrap(
            pluginContents.first { $0.pathExtension == "appex" },
            "no .appex bundle found in \(pluginsURL.path)"
        )
        let extensionBundle = try XCTUnwrap(Bundle(url: appexURL), "cannot open \(appexURL.path)")
        assertDisplayNameInvisible(of: extensionBundle, label: "extension \(appexURL.lastPathComponent)")
    }

    /// Without compiled icon artwork iOS draws a white placeholder tile, so the
    /// transparent `AppIcon` catalog must be part of the shipped bundle.
    func testApplicationShipsCompiledIconArtwork() throws {
        let app = try hostApplicationBundle()
        let compiledCatalog = app.bundleURL.appendingPathComponent("Assets.car")
        let bundleContents = (try? FileManager.default.contentsOfDirectory(atPath: app.bundleURL.path)) ?? []
        let looseIcons = bundleContents.filter { $0.hasPrefix("AppIcon") && $0.hasSuffix(".png") }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: compiledCatalog.path) || !looseIcons.isEmpty,
            "no compiled icon artwork in \(app.bundleURL.path) "
                + "(Assets.car missing, loose icons: \(looseIcons))"
        )
    }
}
