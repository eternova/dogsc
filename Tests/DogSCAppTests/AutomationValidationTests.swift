import Foundation
import XCTest
@testable import DogSCApp

final class AutomationValidationTests: XCTestCase {
    @MainActor
    func testMergePreservesUnmentionedFieldsAndRejectsTypos() throws {
        let original: [String: Any] = ["camera": ["size": 0.3, "lut": ["intensity": 1, "rgbaData": "embedded"]], "title": "original"]
        let patch: [String: Any] = ["camera": ["lut": ["intensity": 0.4]]]
        let merged = AutomationCommands.merge(original, patch)
        let lut = (merged["camera"] as! [String: Any])["lut"] as! [String: Any]
        XCTAssertEqual(lut["rgbaData"] as? String, "embedded")
        XCTAssertEqual(lut["intensity"] as? Double, 0.4)
        XCTAssertEqual(merged["title"] as? String, "original")
        try AutomationCommands.checkPatchKeys(patch, encoded: merged)
        XCTAssertThrowsError(try AutomationCommands.checkPatchKeys(["camera": ["typo": 1]], encoded: original))
        let cleared = AutomationCommands.merge(original, ["camera": ["lut": NSNull()]])
        XCTAssertNil((cleared["camera"] as! [String: Any])["lut"])
    }
}
