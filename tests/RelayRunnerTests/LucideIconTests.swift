import XCTest
@testable import relay_runner

final class LucideIconTests: XCTestCase {
    func testEveryIconDrawsInsideLucidesViewBox() {
        let viewBox = CGRect(x: 0, y: 0, width: 24, height: 24)
        for icon in LucideIcon.allCases {
            let stroke = icon.geometry.stroke
            XCTAssertFalse(stroke.isEmpty, "\(icon.rawValue)")
            XCTAssertTrue(viewBox.contains(stroke.boundingRect), "\(icon.rawValue) leaves the 24-unit box")
        }
    }

    /// The Graphical handoff specs Lucide icons, so SF Symbols must not creep back in.
    func testTheAppDrawsLucideIconsInsteadOfSFSymbols() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/relay-runner")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for marker in ["Image(systemName:", "systemSymbolName:", "systemImage:"] where contents.contains(marker) {
                offenders.append("\(file.lastPathComponent): \(marker)")
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
