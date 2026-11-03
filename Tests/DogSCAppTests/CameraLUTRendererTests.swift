import AVFoundation
import CoreImage
import XCTest
import RecorderCore
@testable import DogSCApp

final class CameraLUTRendererTests: XCTestCase {
    func testLivePreviewCreatesGradedBufferWithoutChangingCaptureSample() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let raw = try XCTUnwrap(buffer)
        let profile = try CoreImageFrameColorProfile(contract: .sdrDesktop)
        profile.applyAttachments(to: raw)
        let context = profile.makeContext(cacheIntermediates: false)
        let bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        context.render(CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds),
                       to: raw, bounds: bounds, colorSpace: profile.outputColorSpace)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: raw, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: 5, timescale: 1), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: raw,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let original = try XCTUnwrap(sample)
        let lut = try CameraLUT(cube: "LUT_3D_SIZE 2\n" + String(repeating: "1 0 0\n", count: 8), name: "red")
        let graded = try XCTUnwrap(CameraLUTPreviewRenderer().render(original, lut: lut))
        let output = try XCTUnwrap(CMSampleBufferGetImageBuffer(graded))
        XCTAssertFalse(raw === output)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(graded), timing.presentationTimeStamp)
        CVPixelBufferLockBaseAddress(raw, .readOnly); CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(raw, .readOnly); CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let rawBytes = CVPixelBufferGetBaseAddress(raw)!.assumingMemoryBound(to: UInt8.self)
        let gradedBytes = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(rawBytes[0], 240); XCTAssertLessThan(rawBytes[2], 10)
        XCTAssertGreaterThan(gradedBytes[2], 240); XCTAssertLessThan(gradedBytes[0], 10)
    }

    func testIdentityInversionIntensityAndBypassPixels() throws {
        let input = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let context = try CoreImageFrameColorProfile(contract: .sdrDesktop).makeContext(cacheIntermediates: false)
        func pixels(_ image: CIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 16)
            context.render(image, toBitmap: &bytes, rowBytes: 8, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return Array(bytes.prefix(4))
        }
        var cube = "LUT_3D_SIZE 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { cube += "\(r) \(g) \(b)\n" } } }
        var lut = try CameraLUT(cube: cube, name: "identity")
        let original = pixels(input)
        let identity = pixels(CameraLUTRenderer.apply(lut, to: input))
        for i in 0..<3 { XCTAssertEqual(Double(identity[i]), Double(original[i]), accuracy: 2) }
        cube = "LUT_3D_SIZE 2\n" + String(repeating: "1 0 0\n", count: 8)
        lut = try CameraLUT(cube: cube, name: "red")
        XCTAssertEqual(pixels(CameraLUTRenderer.apply(lut, to: input)), [255, 0, 0, 255])
        lut.intensity = 0.5
        let mixed = pixels(CameraLUTRenderer.apply(lut, to: input))
        XCTAssertGreaterThan(mixed[0], original[0]); XCTAssertLessThan(mixed[1], original[1])
        lut.isEnabled = false
        XCTAssertEqual(pixels(CameraLUTRenderer.apply(lut, to: input)), original)
        lut.isEnabled = true; lut.intensity = 0
        XCTAssertEqual(pixels(CameraLUTRenderer.apply(lut, to: input)), original)
    }
}
