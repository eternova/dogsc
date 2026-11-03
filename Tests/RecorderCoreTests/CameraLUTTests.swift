import Foundation
import XCTest
@testable import RecorderCore

final class CameraLUTTests: XCTestCase {
    static let identity = """
    TITLE "Identity"
    LUT_3D_SIZE 2
    DOMAIN_MIN 0 0 0
    DOMAIN_MAX 1 1 1
    0 0 0
    1 0 0
    0 1 0
    1 1 0
    0 0 1
    1 0 1
    0 1 1
    1 1 1
    """
    func testCubeOrderAndPortableProjectRoundTrip() throws {
        let lut = try CameraLUT(cube: "\u{FEFF}" + Self.identity, name: "My LUT")
        try lut.validate()
        XCTAssertEqual(lut.dimension, 2)
        XCTAssertEqual(lut.rgbaData.count, 128)
        let values = lut.rgbaData.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
        XCTAssertEqual(Array(values[4..<8]), [1, 0, 0, 1])
        var project = RecorderProject()
        project.camera.lut = lut
        let decoded = try JSONDecoder().decode(RecorderProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.camera.lut, lut)
        XCTAssertEqual(decoded.version, 28)
    }
    func testMalformedCubesAreRejected() throws {
        for text in ["LUT_1D_SIZE 2", "LUT_3D_SIZE 1000", "LUT_3D_SIZE 2\n0 0 0", Self.identity + "\n1 1 1", Self.identity.replacingOccurrences(of: "1 0 0\n", with: "nan 0 0\n"), Self.identity.replacingOccurrences(of: "DOMAIN_MAX 1 1 1", with: "DOMAIN_MAX 2 2 2")] {
            XCTAssertThrowsError(try CameraLUT(cube: text, name: "bad"))
        }
    }
    func testOldCameraStyleAndIntensityValidation() throws {
        let style = try JSONDecoder().decode(CameraStyle.self, from: Data("{}".utf8))
        XCTAssertNil(style.lut)
        var invalid = try CameraLUT(cube: Self.identity, name: "test")
        invalid.intensity = 1.1
        XCTAssertThrowsError(try invalid.validate())
        var project = RecorderProject()
        project.camera.lut = invalid
        XCTAssertThrowsError(try ProjectValidator.validate(project))
    }
}
