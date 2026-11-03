import Foundation

/// Portable, immutable cube data. Embedded in the project so edits do not
/// depend on a path outside the project or on the original .cube file.
public struct CameraLUT: Codable, Equatable, Sendable {
    public let name: String
    public let dimension: Int
    public let rgbaData: Data
    public var intensity: Double = 1
    public var isEnabled: Bool = true

    public init(cube text: String, name: String) throws {
        guard text.utf8.count <= 32 * 1_024 * 1_024 else {
            throw CameraLUTError.invalid("LUT 文件不能超过 32 MB。")
        }
        var size: Int?
        var values: [Float] = []
        var minimum: [Float] = [0, 0, 0]
        var maximum: [Float] = [1, 1, 1]
        for rawLine in text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first else { continue }
            switch first {
            case "TITLE": continue
            case "LUT_3D_SIZE":
                guard values.isEmpty, size == nil, fields.count == 2,
                      let n = Int(fields[1]), (2...65).contains(n) else {
                    throw CameraLUTError.invalid("LUT_3D_SIZE 必须为 2 到 65，且只能声明一次。")
                }
                size = n
                values.reserveCapacity(n * n * n * 4)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let numbers = fields.dropFirst().compactMap { Float($0) }
                guard values.isEmpty, numbers.count == 3, numbers.allSatisfy(\.isFinite) else {
                    throw CameraLUTError.invalid("无效的 LUT 输入范围。")
                }
                if first == "DOMAIN_MIN" { minimum = numbers } else { maximum = numbers }
            case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                throw CameraLUTError.invalid("当前支持标准 3D .cube；不支持 1D、混合 LUT 或 INPUT_RANGE 扩展。")
            default:
                guard let size, fields.count == 3 else {
                    throw CameraLUTError.invalid("LUT 数据前必须声明 LUT_3D_SIZE；每行需要三个数值。")
                }
                let numbers = fields.compactMap { Float($0) }
                guard numbers.count == 3, numbers.allSatisfy({ $0.isFinite && abs($0) <= 65_504 }),
                      values.count < size * size * size * 4 else {
                    throw CameraLUTError.invalid("LUT 包含无效数值或多余数据。")
                }
                values.append(contentsOf: numbers)
                values.append(1)
            }
        }
        guard let size, values.count == size * size * size * 4 else {
            throw CameraLUTError.invalid("LUT 数据行数与 LUT_3D_SIZE 不匹配。")
        }
        guard minimum == [0, 0, 0], maximum == [1, 1, 1] else {
            throw CameraLUTError.invalid("当前支持 DOMAIN_MIN 0 0 0 / DOMAIN_MAX 1 1 1；请先将 LUT 转成标准范围。")
        }
        self.name = String(name.prefix(200))
        dimension = size
        rgbaData = values.withUnsafeBytes { Data($0) }
    }

    public func validate() throws {
        guard (2...65).contains(dimension),
              rgbaData.count == dimension * dimension * dimension * 4 * MemoryLayout<Float>.size,
              intensity.isFinite, (0...1).contains(intensity), name.count <= 200 else {
            throw CameraLUTError.invalid("LUT 数据或强度无效。")
        }
        // Data's base address need not be Float-aligned after JSON decoding.
        try rgbaData.withUnsafeBytes { bytes in
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let value = bytes.loadUnaligned(fromByteOffset: i, as: Float.self)
                guard value.isFinite, abs(value) <= 65_504,
                      (i / 4) % 4 != 3 || value == 1 else {
                    throw CameraLUTError.invalid("LUT 包含无效的 RGBA 数据。")
                }
            }
        }
    }
}

public enum CameraLUTError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case let .invalid(message): message }
    }
}
