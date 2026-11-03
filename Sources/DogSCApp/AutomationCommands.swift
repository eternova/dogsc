import AppKit
import AVFoundation
import CryptoKit
import Foundation
import RecorderCore

struct AutomationError: LocalizedError {
    let errorDescription: String?
    static func message(_ text: String) -> Self { Self(errorDescription: text) }
}

/// References the same store, media generation and undo manager as the UI.
@MainActor
final class AutomationEditor {
    static let shared = AutomationEditor()
    weak var store: EditorStore?
    weak var media: EditorMediaSession?
    weak var playback: EditorPlaybackController?
    weak var undo: UndoManager?
    var context: EditorSessionContext?
    func attach(store: EditorStore, media: EditorMediaSession, playback: EditorPlaybackController,
                context: EditorSessionContext, undo: UndoManager?) {
        self.store = store; self.media = media; self.playback = playback
        self.context = context; self.undo = undo
    }
    func detach(id: EditorSessionID) {
        guard context?.id == id else { return }
        store = nil; media = nil; playback = nil; context = nil; undo = nil
    }
}

@MainActor
final class AutomationCommands {
    private weak var recorder: AppModel?
    private var isBusy = false
    private var sourceExportState: [String: Any] = ["running": false, "path": "", "error": ""]
    init(model: AppModel) { recorder = model }
    private var editor: AutomationEditor { .shared }
    private var model: AppModel? { WindowCoordinator.activeEditorModel ?? recorder }

    func call(_ name: String, _ args: [String: Any]) async throws -> Any {
        guard let recorder, let model else { throw AutomationError.message("Application not ready") }
        guard !isBusy || name == "dogsc_status" else { throw AutomationError.message("Another operation is in progress") }
        switch name {
        case "dogsc_status": return try status()
        case "dogsc_settings":
            if let patch = args["patch"] as? [String: Any] {
                let allowed: Set<String> = ["appearance", "language", "exportCompletionSound", "timelineHoverPreview", "exportDirectory"]
                guard Set(patch.keys).isSubset(of: allowed) else { throw AutomationError.message("Unknown setting") }
                let appearance = (patch["appearance"] as? String).flatMap(AppAppearancePreference.init(rawValue:))
                let language = (patch["language"] as? String).flatMap(AppLanguagePreference.init(rawValue:))
                guard patch["appearance"] == nil || appearance != nil, patch["language"] == nil || language != nil else { throw AutomationError.message("Invalid appearance or language") }
                for key in ["exportCompletionSound", "timelineHoverPreview"] where patch[key] != nil {
                    guard let value = patch[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw AutomationError.message("Setting must be boolean: \(key)") }
                }
                if patch["exportDirectory"] != nil { try AppPreferences.setExportDirectory(fileURL(patch, "exportDirectory")) }
                if let appearance {
                    UserDefaults.standard.set(appearance.rawValue, forKey: AppPreferences.appearancePreferenceKey)
                    AppPreferences.applyAppearancePreferenceToOpenWindows()
                }
                if let language { AppPreferences.setLanguagePreference(language); _ = AppLocalization.shared.apply(language) }
                if let value = patch["exportCompletionSound"] as? Bool { UserDefaults.standard.set(value, forKey: AppPreferences.exportCompletionSoundEnabledKey) }
                if let value = patch["timelineHoverPreview"] as? Bool { UserDefaults.standard.set(value, forKey: AppPreferences.editorTimelineHoverPreviewEnabledKey) }
            }
            return ["appearance": AppPreferences.appearancePreference.rawValue,
                    "language": AppLanguagePreference(preferredLanguages: AppPreferences.applicationLanguageOverride).rawValue,
                    "exportCompletionSound": AppPreferences.isExportCompletionSoundEnabled,
                    "timelineHoverPreview": AppPreferences.isTimelineHoverPreviewEnabled,
                    "exportDirectory": AppPreferences.exportDirectoryURL.path]
        case "dogsc_presets":
            let action = try string(args, "action")
            var presets = EditorStylePresetStore.load()
            if action != "list" {
                try requireEditor()
                guard let context = editor.context else { throw AutomationError.message("Editor not ready") }
                isBusy = true; defer { isBusy = false }
                if action == "save" {
                    let name = try string(args, "name")
                    guard name.count <= 100, !presets.contains(where: { $0.name == name }) else { throw AutomationError.message("Choose a new preset name of at most 100 characters") }
                    var preset = EditorStylePreset(name: name, project: model.project)
                    if let background = context.wallpaperURL(for: model.project.canvas.backgroundSource) {
                        let isVideo: Bool
                        switch model.project.canvas.backgroundSource { case .projectVideo, .systemVideo: isVideo = true; default: isVideo = false }
                        preset.backgroundAsset = try await ScenePresetBackgroundAsset.retain(from: background, isVideo: isVideo)
                    }
                    presets.append(preset)
                    try EditorStylePresetStore.save(presets)
                } else if action == "apply" {
                    guard let preset = presets.first(where: { $0.id.uuidString.lowercased() == (args["id"] as? String)?.lowercased() }) else { throw AutomationError.message("Preset not found") }
                    var background: BackgroundSource?
                    if let asset = preset.backgroundAsset {
                        guard asset.isAvailable, let url = asset.url else { throw AutomationError.message("Preset background is missing") }
                        let imported = try await context.projectAssetTransfer.importBackgroundAsset(from: url, isVideo: asset.isVideo)
                        guard editor.context?.id == context.id else { throw AutomationError.message("Editor changed during preset import") }
                        background = asset.isVideo ? .projectVideo(relativePath: imported.relativePath) : .projectImage(relativePath: imported.relativePath)
                    }
                    try editor.store!.replaceProject(with: preset.applying(to: model.project, backgroundOverride: background), actionName: "MCP 应用场景")
                } else { throw AutomationError.message("Unknown preset action") }
            }
            return presets.map { ["id": $0.id.uuidString, "name": $0.name, "hasAvailableBackground": $0.hasAvailableBackground] as [String: Any] }
        case "dogsc_project_get": return try snapshot(model.project, includeData: args["includeLUTData"] as? Bool ?? false)
        case "dogsc_windows":
            guard recorder.captureReadiness.hasScreenRecordingPermission else { throw AutomationError.message("Screen recording permission is required to list windows") }
            let windows = try await CaptureWindowInfo.available()
            return windows.map { ["id": $0.id, "title": $0.title, "applicationName": $0.applicationName,
                                  "applicationBundleIdentifier": $0.applicationBundleIdentifier ?? ""] as [String: Any] }
        case "dogsc_timeline":
            try requireEditor()
            guard let duration = editor.media?.inventories.source.videoTimeRange?.duration, duration > 0 else { throw AutomationError.message("Source media is not ready") }
            let action = try string(args, "action")
            var timeline = model.project.timeline
            if action != "list" {
                guard try string(args, "expectedRevision") == revision(model.project) else { throw AutomationError.message("Project changed; read the current revision") }
                func segmentID() throws -> UUID {
                    guard let id = UUID(uuidString: try string(args, "segmentID")) else { throw AutomationError.message("Invalid segment ID") }; return id
                }
                switch action {
                case "split": timeline = try ProjectTimelineEditing.splitPrimarySegment(in: timeline, atOutputTime: number(args, "time"), newRightSegmentID: UUID(), fullSourceDuration: duration)
                case "trim":
                    guard let edge = RecordingSegmentTrimEdge(rawValue: try string(args, "edge")) else { throw AutomationError.message("edge must be left or right") }
                    timeline = try ProjectTimelineEditing.trimPrimarySegment(in: timeline, segmentID: segmentID(), edge: edge, toOutputTime: number(args, "time"), fullSourceDuration: duration)
                case "remove": timeline = try ProjectTimelineEditing.removePrimarySegment(from: timeline, segmentID: segmentID(), fullSourceDuration: duration)
                case "move":
                    let index = try number(args, "index")
                    guard index >= 0, index <= 100_000, index.rounded() == index else { throw AutomationError.message("index must be a nonnegative integer") }
                    timeline = try ProjectTimelineEditing.movePrimarySegment(in: timeline, segmentID: segmentID(), toIndex: Int(index), fullSourceDuration: duration)
                case "speed": timeline = try ProjectTimelineEditing.settingPlaybackRate(number(args, "rate"), for: segmentID(), in: timeline, fullSourceDuration: duration)
                default: throw AutomationError.message("Unknown timeline action")
                }
                try editor.store!.replaceTimeline(with: timeline, actionName: "MCP 剪辑")
            }
            let map = try TimelineMap(sourceSequence: timeline.sourceSequence, fullSourceDuration: duration)
            return ["revision": try revision(model.project), "duration": map.outputDuration,
                    "segments": map.segments.map { ["id": $0.id.uuidString, "sourceStart": $0.sourceStart, "sourceDuration": $0.sourceDuration,
                                                    "outputStart": $0.outputStart, "outputEnd": $0.outputEnd, "playbackRate": $0.playbackRate] as [String: Any] }]
        case "dogsc_camera_replace":
            try requireEditor()
            guard !model.exporter.isExporting, let session = model.currentSession, model.project.media?.camera != nil else { throw AutomationError.message("Requires a camera track and idle exporter") }
            let url = try fileURL(args, "path")
            let sessionID = model.editorSessionID
            isBusy = true; model.isMediaExchangeRunning = true
            defer { isBusy = false; model.isMediaExchangeRunning = false }
            try await ProjectMediaExchange.inspectCameraReplacement(url)
            let imported = try await Task.detached { try ProjectMediaExchange.importCameraReplacement(camera: url, session: session) }.value
            guard model.editorSessionID == sessionID else { throw AutomationError.message("Editor changed during import; imported file was not applied") }
            var replacement = model.project
            replacement.media?.camera = ProjectMediaReference(relativePath: imported.cameraRelativePath)
            model.project = replacement
            model.cameraRecordingURL = imported.cameraURL
            model.editorContextRevision &+= 1
            _ = try await model.workspace.flush(replacement)
            return ["path": imported.cameraURL.path, "note": "Media generation changed; wait for editorReady"]
        case "dogsc_sources":
            recorder.refreshCaptureDevices()
            return ["displays": recorder.availableDisplays.map { ["id": $0.id, "name": $0.name] as [String: Any] },
                    "cameras": recorder.availableCameras.map { ["id": $0.id, "name": $0.name] },
                    "microphones": recorder.availableMicrophones.map { ["id": $0.id, "name": $0.name] },
                    "screenDevices": recorder.availableScreenDevices.map { ["id": $0.id, "name": $0.name] },
                    "configuration": try object(recorder.configuration)]
        case "dogsc_capture_configure":
            guard recorder.phase == .setup else { throw AutomationError.message("Capture configuration requires setup phase") }
            let patch = try dictionary(args, "patch")
            let current = try object(recorder.configuration)
            let configuration = try decode(CaptureConfiguration.self, merging: current, patch: patch)
            try Self.checkPatchKeys(patch, encoded: object(configuration))
            recorder.refreshCaptureDevices()
            let camera = recorder.availableCameras.first { $0.id == configuration.cameraDeviceID }
            let microphone = recorder.availableMicrophones.first { $0.id == configuration.microphoneDeviceID }
            guard !configuration.recordsCamera || camera != nil else { throw AutomationError.message("Camera device ID not available; call dogsc_sources") }
            guard !configuration.recordsMicrophone || microphone != nil else { throw AutomationError.message("Microphone device ID not available; call dogsc_sources") }
            if let area = configuration.area {
                guard area.x.isFinite, area.y.isFinite, area.width.isFinite, area.height.isFinite,
                      area.x >= 0, area.y >= 0, area.width > 0, area.height > 0,
                      area.x + area.width <= 1, area.y + area.height <= 1 else { throw AutomationError.message("Area must fit inside normalized display coordinates") }
            }
            isBusy = true; defer { isBusy = false }
            try await recorder.captureSetup.configureForAutomation(configuration) { recorder.phase == .setup }
            recorder.selectCamera(configuration.recordsCamera ? camera : nil)
            recorder.selectMicrophone(configuration.recordsMicrophone ? microphone : nil)
            return try status()
        case "dogsc_recording":
            let action = try string(args, "action")
            switch action {
            case "start":
                guard recorder.phase == .setup else { throw AutomationError.message("Start requires setup phase") }
                recorder.errorMessage = nil; recorder.startRecording()
            case "stop":
                guard recorder.phase == .recording else { throw AutomationError.message("Not recording") }
                recorder.stopRecording()
            case "pause", "resume":
                guard recorder.phase == .recording, !recorder.isPauseTransitioning else { throw AutomationError.message("Recording is not ready") }
                if recorder.isRecordingPaused != (action == "pause") { recorder.toggleRecordingPause() }
            case "marker":
                guard recorder.phase == .recording, !recorder.isRecordingPaused else { throw AutomationError.message("Marker requires active recording") }
                recorder.addRecordingMarker()
            case "edit":
                guard recorder.phase == .recordingComplete else { throw AutomationError.message("Recording has not completed") }
                recorder.editCompletedRecording()
            case "save":
                guard recorder.phase == .recordingComplete else { throw AutomationError.message("Recording has not completed") }
                isBusy = true; defer { isBusy = false }
                guard await recorder.saveCompletedRecording() else { throw AutomationError.message(recorder.errorMessage ?? "Save failed") }
            default: throw AutomationError.message("Unsupported recording action")
            }
            return try status()
        case "dogsc_project_open":
            guard recorder.phase == .setup || recorder.phase == .editor else { throw AutomationError.message("Finish the recording before opening a project") }
            let url = try fileURL(args, "path")
            guard FileManager.default.fileExists(atPath: url.path) else { throw AutomationError.message("Project does not exist") }
            model.errorMessage = nil
            model.requestOpenProject(at: url)
            return ["accepted": true, "note": "Opening is asynchronous; poll dogsc_status for projectPath, editorReady and error."]
        case "dogsc_project_save":
            try requireEditor()
            isBusy = true; defer { isBusy = false }
            guard let receipt = try await model.workspace.flush(model.project) else { throw AutomationError.message("No active project session") }
            return ["saved": true, "revision": receipt.committedRevision, "path": model.currentSession?.packageURL.path ?? ""]
        case "dogsc_project_patch":
            try requireEditor()
            let patch = try dictionary(args, "patch")
            let allowed: Set<String> = ["title", "canvas", "camera", "audio", "motion", "openingSequence", "cursorStyle", "exportSettings", "timeline", "recordingMarkers", "media"]
            guard Set(patch.keys).isSubset(of: allowed) else { throw AutomationError.message("Read-only project field; patch only title, canvas, camera, audio, motion, openingSequence, cursorStyle, exportSettings, timeline, recordingMarkers; media.camera permits timing fields only") }
            if let mediaPatch = patch["media"] {
                guard let media = mediaPatch as? [String: Any], Set(media.keys) == ["camera"],
                      let camera = media["camera"] as? [String: Any], model.project.media?.camera != nil,
                      Set(camera.keys).isSubset(of: ["startOffset", "sourceStartTime", "sourceTimeScale", "sourceEndTime", "syncAnchors"]) else {
                    throw AutomationError.message("Only existing media.camera timing can be patched; media file references are read-only")
                }
                for key in ["startOffset", "sourceStartTime", "sourceTimeScale", "sourceEndTime"] {
                    if camera[key] != nil, !(camera[key] is NSNull) {
                        let value = try number(camera, key)
                        guard value >= 0, key != "sourceTimeScale" || value > 0 else { throw AutomationError.message("Invalid camera timing value") }
                    }
                }
            }
            let before = model.project
            guard try string(args, "expectedRevision") == revision(before) else { throw AutomationError.message("Project changed; read dogsc_project_get again before editing") }
            let after = try decode(RecorderProject.self, merging: object(before), patch: patch)
            try ProjectValidator.validate(after)
            if let duration = editor.media?.inventories.source.videoTimeRange?.duration {
                try ProjectTimelineEditing.validate(after.timeline, fullSourceDuration: duration)
            }
            try Self.checkPatchKeys(patch, encoded: object(after))
            try editor.store!.replaceProject(with: after, actionName: "MCP 调整项目")
            return try snapshot(after)
        case "dogsc_lut":
            let target = args["target"] as? String ?? "editor"
            guard target == "editor" || target == "recording" else { throw AutomationError.message("target must be editor or recording") }
            if target == "editor" { try requireEditor() }
            else if recorder.phase != .setup { throw AutomationError.message("Recording LUT changes require setup phase; change the grade in the editor after recording") }
            var lut = target == "editor" ? model.project.camera.lut : recorder.recordingCameraLUT
            switch try string(args, "action") {
            case "import": lut = try CameraLUTImport.load(fileURL(args, "path"))
            case "clear": lut = nil
            case "configure":
                guard lut != nil else { throw AutomationError.message("Import a LUT first") }
                if let enabled = args["enabled"] as? Bool { lut?.isEnabled = enabled }
                if args["intensity"] != nil { lut?.intensity = try number(args, "intensity") }
            default: throw AutomationError.message("Unknown LUT action")
            }
            try lut?.validate()
            if target == "editor" {
                var camera = model.project.camera; camera.lut = lut
                try editor.store!.replaceCamera(with: camera, actionName: "MCP 摄像头 LUT")
            } else { recorder.recordingCameraLUT = lut }
            return lut.map { ["name": $0.name, "dimension": $0.dimension, "intensity": $0.intensity, "enabled": $0.isEnabled] as [String: Any] } ?? ["enabled": false]
        case "dogsc_playback":
            try requireEditor()
            guard let playback = editor.playback else { throw AutomationError.message("Playback unavailable") }
            switch try string(args, "action") {
            case "play": playback.play()
            case "pause": playback.pause()
            case "seek":
                let time = try number(args, "time")
                guard time >= 0, time <= playback.duration else { throw AutomationError.message("Time is outside the timeline") }
                playback.seek(to: time)
            default: throw AutomationError.message("Unknown playback action")
            }
            return try status()
        case "dogsc_history":
            try requireEditor()
            guard let undo = editor.undo else { throw AutomationError.message("Undo manager unavailable") }
            switch try string(args, "action") {
            case "undo": guard undo.canUndo else { throw AutomationError.message("Nothing to undo") }; undo.undo()
            case "redo": guard undo.canRedo else { throw AutomationError.message("Nothing to redo") }; undo.redo()
            default: throw AutomationError.message("Unknown history action")
            }
            return try snapshot(model.project)
        case "dogsc_export":
            try requireEditor()
            guard !model.exporter.isExporting, let prepared = editor.media?.prepared, let context = editor.context else { throw AutomationError.message("Export is running or media is not ready") }
            let output = try fileURL(args, "path")
            guard !FileManager.default.fileExists(atPath: output.path) else { throw AutomationError.message("Output already exists; choose a new path") }
            guard let kind = ExportOutputKind(rawValue: args["kind"] as? String ?? "video") else { throw AutomationError.message("kind must be video or audio") }
            _ = editor.store?.prepareForExternalAction(.export)
            let project = model.project
            var range: MediaTimeRange?
            if args["start"] != nil || args["duration"] != nil {
                range = MediaTimeRange(start: try number(args, "start"), duration: try number(args, "duration"))
                guard range != nil else { throw AutomationError.message("Invalid export range") }
            }
            let request = try EditorExportRequestBuilder.make(editorSessionID: context.id, mediaGeneration: prepared.generation,
                project: project, preparedMedia: prepared, wallpaperURL: context.wallpaperURL(for: project.canvas.backgroundSource),
                stickerURLs: Dictionary(uniqueKeysWithValues: Set(project.timeline.stickerClips.map(\.relativePath)).compactMap { path in context.projectAssetURL(for: path).map { (path, $0) } }),
                outputURL: output, outputKind: kind, outputRange: range)
            model.exporter.export(request: request)
            return ["accepted": true, "path": output.path, "note": "Poll dogsc_status.export for completion or error"]
        case "dogsc_export_cancel": model.exporter.cancelExport(); return try status()
        case "dogsc_sources_export":
            try requireEditor()
            guard let source = model.recordingURL else { throw AutomationError.message("No source media") }
            guard sourceExportState["running"] as? Bool != true else { throw AutomationError.message("Source export is already running") }
            let sources = ProjectSourceMediaFiles(screen: source, camera: model.cameraRecordingURL, microphone: model.microphoneRecordingURL)
            let title = model.project.title
            let directory = try fileURL(args, "directory")
            let jobID = UUID().uuidString
            sourceExportState = ["running": true, "path": "", "error": "", "jobID": jobID]
            Task { @MainActor in
                do {
                    let output = try await Task.detached(priority: .userInitiated) {
                        try ProjectMediaExchange.exportSources(sources, projectTitle: title, into: directory)
                    }.value
                    self.sourceExportState = ["running": false, "path": output.path, "error": "", "jobID": jobID]
                } catch {
                    self.sourceExportState = ["running": false, "path": "", "error": error.localizedDescription, "jobID": jobID]
                }
            }
            return ["accepted": true, "jobID": jobID, "note": "Poll dogsc_status.sourceExport for completion"]
        case "dogsc_asset_import":
            try requireEditor()
            let url = try fileURL(args, "path")
            guard let session = model.currentSession else { throw AutomationError.message("No project session") }
            let transfer = EditorProjectAssetTransfer(session: session)
            isBusy = true; defer { isBusy = false }
            switch try string(args, "kind") {
            case "sticker":
                guard let path = model.importOverlayImageAsset(from: url) else { throw AutomationError.message(model.errorMessage ?? "Import failed") }
                return ["relativePath": path]
            case "backgroundImage", "backgroundVideo":
                let isVideo = args["kind"] as? String == "backgroundVideo"
                let imported = try await transfer.importBackgroundAsset(from: url, isVideo: isVideo)
                return ["relativePath": imported.relativePath, "note": "Use project_patch canvas.backgroundSource to apply the imported asset"]
            default: throw AutomationError.message("kind must be sticker, backgroundImage or backgroundVideo")
            }
        case "dogsc_ui":
            switch try string(args, "action") {
            case "show": WindowCoordinator.bringCurrentWindowFront()
            case "settings": AppSettingsWindowController.shared.show()
            case "memo": WindowCoordinator.toggleRecorderMemo()
            case "shortcuts": EditorMenuBridge.shared.shortcutCheatsheetRequest.send()
            case "selectSource":
                let sourceName = try string(args, "source")
                guard recorder.phase == .setup, let source = (["display": CaptureSource.display, "window": .window, "area": .area, "device": .device][sourceName] ?? CaptureSource(rawValue: sourceName)) else { throw AutomationError.message("Invalid capture source or phase") }
                DispatchQueue.main.async { recorder.selectCaptureSource(source) }
            case "replaceCamera": try requireEditor(); DispatchQueue.main.async { model.importCameraReplacement() }
            case "closeProject": try requireEditor(); DispatchQueue.main.async { model.requestCloseProject() }
            case "cameraPermission": recorder.openCameraPrivacySettings()
            case "microphonePermission": recorder.openMicrophonePrivacySettings()
            case "screenPermission": recorder.openScreenRecordingSettings()
            default: throw AutomationError.message("Unknown UI action")
            }
            return ["presented": true, "note": "This action may require interaction in the app"]
        default: throw AutomationError.message("Unknown tool: \(name)")
        }
    }

    private func requireEditor() throws {
        guard let model, model.phase == .editor, editor.context?.id.rawValue == model.editorSessionID,
              editor.store != nil else { throw AutomationError.message("Open a project and wait for editorReady") }
        guard !model.isMediaExchangeRunning else { throw AutomationError.message("Media replacement in progress") }
    }
    private func status() throws -> [String: Any] {
        guard let recorder, let model else { return ["ready": false] }
        return ["phase": String(describing: recorder.phase), "activePhase": String(describing: model.phase),
                "editorReady": model.phase == .editor && editor.store != nil && editor.media?.prepared != nil,
                "projectPath": model.currentSession?.packageURL.path ?? "", "projectRevision": try revision(model.project),
                "error": model.errorMessage ?? recorder.errorMessage ?? editor.media?.errorMessage ?? "", "paused": recorder.isRecordingPaused, "canStartRecording": recorder.canStartRecording,
                "playbackTime": editor.playback?.outputTime ?? 0, "duration": editor.playback?.duration ?? 0,
                "permissions": ["screen": recorder.captureReadiness.hasScreenRecordingPermission,
                                "accessibility": AXIsProcessTrusted(),
                                "camera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                                "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized],
                "export": ["running": model.exporter.isExporting, "progress": model.exporter.exportProgress,
                           "path": model.exporter.lastExportURL?.path ?? "", "error": model.exporter.errorMessage ?? ""],
                "sourceExport": sourceExportState, "recentProjects": recorder.recentProjects.map(\.path)]
    }
    private func snapshot(_ project: RecorderProject, includeData: Bool = false) throws -> [String: Any] {
        var value = try object(project)
        if !includeData, var camera = value["camera"] as? [String: Any], var lut = camera["lut"] as? [String: Any] {
            lut.removeValue(forKey: "rgbaData"); camera["lut"] = lut; value["camera"] = camera
        }
        return ["revision": try revision(project), "project": value]
    }
    private func revision(_ project: RecorderProject) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(project)).map { String(format: "%02x", $0) }.joined()
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    private func decode<T: Decodable>(_ type: T.Type, merging base: [String: Any], patch: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: Self.merge(base, patch)))
    }
    static func checkPatchKeys(_ patch: [String: Any], encoded: [String: Any], prefix: String = "") throws {
        for (key, value) in patch {
            if value is NSNull { continue }
            guard let stored = encoded[key] else { throw AutomationError.message("Unknown or unsupported field: \(prefix)\(key)") }
            if let child = value as? [String: Any], let encodedChild = stored as? [String: Any] {
                try checkPatchKeys(child, encoded: encodedChild, prefix: prefix + key + ".")
            }
        }
    }
    static func merge(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in patch {
            if value is NSNull { result.removeValue(forKey: key) }
            else if let child = value as? [String: Any] { result[key] = merge(base[key] as? [String: Any] ?? [:], child) }
            else { result[key] = value }
        }
        return result
    }
    private func dictionary(_ args: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = args[key] as? [String: Any] else { throw AutomationError.message("Missing object: \(key)") }; return value
    }
    private func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else { throw AutomationError.message("Missing string: \(key)") }; return value
    }
    private func number(_ args: [String: Any], _ key: String) throws -> Double {
        guard let value = args[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { throw AutomationError.message("Invalid number: \(key)") }; return value.doubleValue
    }
    private func fileURL(_ args: [String: Any], _ key: String) throws -> URL {
        let path = try string(args, key)
        guard path.hasPrefix("/"), !path.contains("\0") else { throw AutomationError.message("Use an absolute local path for \(key)") }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
