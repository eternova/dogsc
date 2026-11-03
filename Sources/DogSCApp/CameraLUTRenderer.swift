import AVFoundation
import CoreImage
import RecorderCore

enum CameraLUTRenderer {
    /// .cube tables are RGB code values, not linear-light samples. Explicit
    /// sRGB keeps the LUT lookup consistent in the app's linear working space.
    static func apply(_ lut: CameraLUT?, to source: CIImage) -> CIImage {
        guard let lut, lut.isEnabled, lut.intensity > 0 else { return source }
        let graded = source.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": lut.dimension,
            "inputCubeData": lut.rgbaData,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
        guard lut.intensity < 1 else { return graded }
        return source.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: graded,
            kCIInputTimeKey: lut.intensity,
        ]).cropped(to: source.extent)
    }
}

/// Used only on a preview sink's serial rendering queue. Raw recording samples
/// are never modified; Core Image writes into a separate pooled pixel buffer.
final class CameraLUTPreviewRenderer {
    private let profile = try! CoreImageFrameColorProfile(contract: .sdrDesktop)
    private lazy var context = profile.makeContext(cacheIntermediates: false)
    private var pool: CVPixelBufferPool?
    private var size = CGSize.zero

    func render(_ sample: CMSampleBuffer, lut: CameraLUT?) -> CMSampleBuffer? {
        guard let lut, lut.isEnabled, lut.intensity > 0 else { return sample }
        guard let input = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
        if size != CGSize(width: width, height: height) || pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
            size = CGSize(width: width, height: height)
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &output) == kCVReturnSuccess,
              let output else { return nil }
        profile.applyAttachments(to: output)
        context.render(CameraLUTRenderer.apply(lut, to: CIImage(cvPixelBuffer: input)),
                       to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: profile.outputColorSpace)
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: output, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
                                       presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                                       decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: output, formatDescription: format,
                                                      sampleTiming: &timing, sampleBufferOut: &result) == noErr else { return nil }
        return result
    }
}
