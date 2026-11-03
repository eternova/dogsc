#!/usr/bin/env python3
"""Dependency-free MCP stdio bridge to the running, opt-in DogSC app."""
import argparse
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import time

PROTOCOL = "2025-03-26"
MAX_MESSAGE = 16 * 1024 * 1024
DEFAULT_ENDPOINT = Path.home() / "Library/Application Support/DogSC-Automation/endpoint.json"


def field(kind="string", **extra):
    return {"type": kind, **extra}


def choice(*values):
    return field(enum=list(values))


def tool(name, description, properties=None, required=(), read_only=False):
    return {"name": name, "description": description,
            "inputSchema": {"type": "object", "properties": properties or {},
                            "required": list(required), "additionalProperties": False},
            "annotations": {"readOnlyHint": read_only, "openWorldHint": False}}


TOOLS = [
    tool("dogsc_status", "Read recorder/editor phase, permissions, errors, project path, playback and export progress. Poll after asynchronous actions.", read_only=True),
    tool("dogsc_sources", "List local cameras, microphones, displays, connected screen devices and complete capture configuration. Does not start recording.", read_only=True),
    tool("dogsc_capture_configure", "Merge capture configuration in setup phase. First read dogsc_sources for exact enum values and device IDs. Supports display/window/area/device, camera, microphone, system audio, resolution and codec. Permissions remain controlled by macOS.", {"patch": field("object")}, ["patch"]),
    tool("dogsc_recording", "Control recording. Start/stop/edit are asynchronous; poll status and inspect error. save persists the completed take.", {"action": choice("start", "stop", "pause", "resume", "marker", "edit", "save")}, ["action"]),
    tool("dogsc_project_get", "Read the complete project contract and revision. LUT binary data is omitted by default. Use exact field/enum names from this result when patching. Arrays replace as a whole; object patches merge recursively; null removes an optional field.", {"includeLUTData": field("boolean")}, read_only=True),
    tool("dogsc_project_open", "Open a .dogscproject package. Poll status until projectPath matches and editorReady is true; errors are reported in status. Existing unsaved work uses the app's save barrier.", {"path": field()}, ["path"]),
    tool("dogsc_project_save", "Flush the current editor project to disk and return the saved revision/path."),
    tool("dogsc_project_patch", "Undoable validated project edit with optimistic concurrency. Supports title, canvas (crop/background/frame), camera, audio, motion, openingSequence, cursorStyle, exportSettings, timeline (cuts/zoom/3D/camera/mosaic/stickers/track order) and recordingMarkers. First get the project and pass its revision. media.camera timing fields (startOffset/sourceStartTime/sourceTimeScale/sourceEndTime/syncAnchors) are also editable; media file references and capture metadata are read-only. LUT import has a dedicated tool. Read docs/MCP.md for examples.", {"expectedRevision": field(), "patch": field("object")}, ["expectedRevision", "patch"]),
    tool("dogsc_lut", "Import your local standard 3D .cube (2–65 grid, 0–1 domain), adjust strength, toggle or clear. target=recording sets the next take and live preview in setup. target=editor changes the current project preview and export; original footage stays intact.", {"action": choice("import", "configure", "clear"), "target": choice("editor", "recording"), "path": field(), "enabled": field("boolean"), "intensity": field("number", minimum=0, maximum=1)}, ["action"]),
    tool("dogsc_playback", "Play, pause or seek the active editor timeline in output seconds.", {"action": choice("play", "pause", "seek"), "time": field("number", minimum=0)}, ["action"]),
    tool("dogsc_history", "Undo or redo using the same history as the visible editor.", {"action": choice("undo", "redo")}, ["action"]),
    tool("dogsc_export", "Export the current project to a NEW absolute .mp4 or .m4a path, using project exportSettings and the camera LUT. Optional start/duration select an output-time range. Returns acceptance; poll status.export until running=false and check error/path.", {"path": field(), "kind": choice("video", "audio"), "start": field("number", minimum=0), "duration": field("number", exclusiveMinimum=0)}, ["path"]),
    tool("dogsc_export_cancel", "Cancel the current export through the app's export transaction."),
    tool("dogsc_sources_export", "Start copying original screen/camera/microphone files into a uniquely named folder. Returns accepted/jobID; poll dogsc_status.sourceExport for completion and errors. Raw camera footage does not bake in the LUT.", {"directory": field()}, ["directory"]),
    tool("dogsc_asset_import", "Copy a sticker/background image/background video into the current project. Returns relativePath; apply it through project_patch. Does not mutate source files.", {"path": field(), "kind": choice("sticker", "backgroundImage", "backgroundVideo")}, ["path", "kind"]),
    tool("dogsc_ui", "Present existing application controls: settings, memo, shortcuts, source picker, camera replacement, close-project and macOS privacy settings. These return presented, not completed; dialogs need user interaction. Capture source raw values are display/window/area/device.", {"action": choice("show", "settings", "memo", "shortcuts", "selectSource", "replaceCamera", "closeProject", "cameraPermission", "microphonePermission", "screenPermission"), "source": field()}, ["action"]),
]
TOOLS += [
    tool("dogsc_settings", "Read or update app settings. Patch supports appearance=system/light/dark, language=system/zh-Hans/en, exportCompletionSound (bool), timelineHoverPreview (bool), exportDirectory (absolute path). Other preferences remain available through dogsc_ui settings.", {"patch": field("object")}),
    tool("dogsc_presets", "List, save a new named scene preset, or apply by ID. Includes camera LUT, canvas, audio, cursor, motion and opening. Background assets are copied for portability. Does not delete or overwrite presets.", {"action": choice("list", "save", "apply"), "name": field(), "id": field()}, ["action"]),
    tool("dogsc_windows", "List available windows with IDs and app bundle identifiers. Requires screen recording permission; does not request it silently.", read_only=True),
    tool("dogsc_timeline", "List resolved recording segments or perform undoable ripple edits: split, trim, remove, move, speed. Times are output seconds. Mutations require expectedRevision from project_get or list; segment actions require segmentID. trim needs edge+time, move needs index, speed needs rate. These reuse the app's timeline editing rules.", {"action": choice("list", "split", "trim", "remove", "move", "speed"), "expectedRevision": field(), "segmentID": field(), "time": field("number", minimum=0), "edge": choice("left", "right"), "index": field("number", minimum=0), "rate": field("number", exclusiveMinimum=0)}, ["action"]),
    tool("dogsc_camera_replace", "Copy a local replacement camera video into the current project, inspect it, update the media generation and save. Requires an existing camera track. Original files are preserved. Wait for editorReady after completion.", {"path": field()}, ["path"]),
]
TOOL_MAP = {item["name"]: item for item in TOOLS}


def validate(arguments, schema):
    if not isinstance(arguments, dict):
        raise ValueError("arguments must be an object")
    properties = schema["properties"]
    if set(arguments) - set(properties):
        raise ValueError("Unknown arguments: " + ", ".join(sorted(set(arguments) - set(properties))))
    for key in schema["required"]:
        if key not in arguments:
            raise ValueError("Missing argument: " + key)
    types = {"string": str, "object": dict, "boolean": bool, "number": (int, float)}
    for key, value in arguments.items():
        spec = properties[key]
        if not isinstance(value, types[spec["type"]]) or (spec["type"] == "number" and isinstance(value, bool)):
            raise ValueError("Invalid type: " + key)
        if "enum" in spec and value not in spec["enum"]:
            raise ValueError("Invalid value: " + key)
        if "minimum" in spec and value < spec["minimum"]:
            raise ValueError("Below minimum: " + key)
        if "maximum" in spec and value > spec["maximum"]:
            raise ValueError("Above maximum: " + key)
        if "exclusiveMinimum" in spec and value <= spec["exclusiveMinimum"]:
            raise ValueError("Below exclusive minimum: " + key)


def read_endpoint(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError("Automation endpoint must be an owner-only regular file")
    endpoint = json.loads(path.read_text())
    if not isinstance(endpoint.get("port"), int) or not 1 <= endpoint["port"] <= 65535:
        raise RuntimeError("Invalid automation endpoint port")
    os.kill(endpoint["pid"], 0)  # Detect stale launch metadata without exposing the token.
    return endpoint


def call_app(name, arguments, endpoint_path=DEFAULT_ENDPOINT):
    endpoint = read_endpoint(endpoint_path)
    request = json.dumps({"token": endpoint["token"], "name": name, "arguments": arguments}, allow_nan=False).encode() + b"\n"
    if len(request) > MAX_MESSAGE:
        raise ValueError("Request too large")
    with socket.create_connection(("127.0.0.1", endpoint["port"]), timeout=5) as connection:
        connection.settimeout(25)
        connection.sendall(request)
        with connection.makefile("rb") as stream:
            line = stream.readline(MAX_MESSAGE + 1)
        if not line.endswith(b"\n") or len(line) > MAX_MESSAGE:
            raise RuntimeError("Incomplete or oversized response")
        response = json.loads(line)
    if "error" in response:
        raise RuntimeError(response["error"])
    return response["result"]


def ensure_app(app, endpoint):
    try:
        call_app("dogsc_status", {}, endpoint)
        return
    except (OSError, ValueError, RuntimeError):
        pass
    subprocess.run(["open", str(app), "--args", "--automation"], check=True, stdout=sys.stderr)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            call_app("dogsc_status", {}, endpoint)
            return
        except (OSError, ValueError, RuntimeError):
            time.sleep(0.2)
    raise RuntimeError("DogSC automation is unavailable. Quit DogSC Dev and reopen with --automation; complete any macOS launch prompts.")


def handle(request, endpoint):
    if not isinstance(request, dict) or request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str):
        return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request"}}
    if "id" not in request:
        return None
    response = {"jsonrpc": "2.0", "id": request["id"]}
    method = request["method"]
    params = request.get("params", {})
    if not isinstance(params, dict):
        return {**response, "error": {"code": -32602, "message": "params must be an object"}}
    if method == "initialize":
        response["result"] = {"protocolVersion": PROTOCOL, "capabilities": {"tools": {"listChanged": False}},
                              "serverInfo": {"name": "dogsc", "version": "0.1.0"},
                              "instructions": "Start with dogsc_status. Camera LUT is non-destructive. Never equate accepted or presented with completion. Read project revision before patching."}
    elif method == "ping":
        response["result"] = {}
    elif method == "tools/list":
        response["result"] = {"tools": TOOLS}
    elif method == "tools/call":
        try:
            name = params.get("name")
            if name not in TOOL_MAP:
                raise ValueError("Unknown tool")
            arguments = params.get("arguments", {})
            validate(arguments, TOOL_MAP[name]["inputSchema"])
        except (TypeError, ValueError) as error:
            response["error"] = {"code": -32602, "message": str(error)}
        else:
            try:
                result = call_app(name, arguments, endpoint)
                response["result"] = {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False, allow_nan=False)}], "isError": False}
            except (OSError, ValueError, RuntimeError) as error:
                response["result"] = {"content": [{"type": "text", "text": str(error)}], "isError": True}
    else:
        response["error"] = {"code": -32601, "message": "Method not found"}
    return response


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", type=Path, default=DEFAULT_ENDPOINT)
    parser.add_argument("--app", type=Path, help="Launch this app bundle with --automation if needed")
    options = parser.parse_args()
    if options.app:
        try:
            ensure_app(options.app, options.endpoint)
        except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
            print(str(error), file=sys.stderr)  # Still expose tools; app can be opened later.
    while True:
        raw = sys.stdin.buffer.readline(MAX_MESSAGE + 1)
        if not raw:
            break
        if len(raw) > MAX_MESSAGE:
            print("MCP input exceeded 16 MB", file=sys.stderr)
            return 1
        try:
            request = json.loads(raw, parse_constant=lambda value: (_ for _ in ()).throw(ValueError("Non-finite JSON number")))
            response = handle(request, options.endpoint)
        except (ValueError, UnicodeDecodeError):
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
        if response is not None:
            print(json.dumps(response, ensure_ascii=False, allow_nan=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
