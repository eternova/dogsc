import AppKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

enum CameraLUTImport {
    static func load(_ url: URL) throws -> CameraLUT {
        guard url.isFileURL, url.pathExtension.lowercased() == "cube",
              (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32 * 1_024 * 1_024 else {
            throw CameraLUTError.invalid("请选择不超过 32 MB 的本地 .cube 文件。")
        }
        return try CameraLUT(cube: String(contentsOf: url, encoding: .utf8), name: url.deletingPathExtension().lastPathComponent)
    }
}

struct CameraLUTControls: View {
    @Binding var lut: CameraLUT?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("摄像头 LUT").font(.headline)
                Spacer()
                Button("导入 .cube…") { chooseLUT() }
                    .accessibilityIdentifier("camera.lut.import")
            }
            if let current = lut {
                Toggle(current.name, isOn: Binding(get: { lut?.isEnabled ?? false }, set: { lut?.isEnabled = $0 }))
                    .accessibilityIdentifier("camera.lut.enabled")
                HStack {
                    Text("强度")
                    Slider(value: Binding(get: { lut?.intensity ?? 1 }, set: { lut?.intensity = $0 }), in: 0...1)
                        .accessibilityLabel("LUT 强度")
                    Text("\(Int(current.intensity * 100))%")
                        .monospacedDigit().frame(width: 40)
                }
                Button("移除 LUT") { lut = nil }
            } else {
                Text("未应用 LUT").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text("预览与成片生效，原始摄像头素材保留。支持 2–65 阶标准 3D .cube（0–1 输入范围）。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { lut = try CameraLUTImport.load(url); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
