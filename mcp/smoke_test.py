#!/usr/bin/env python3
"""Opt-in, real stdio -> app -> generated fixture -> encoded MP4 acceptance test.
Run only with an idle DogSC Dev instance: python3 mcp/smoke_test.py
No physical camera, microphone, screen capture or existing project is used.
"""
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg is required for synthetic test media")
    process = subprocess.Popen([sys.executable, str(ROOT / "mcp/server.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    next_id = 0

    def rpc(method, params=None):
        nonlocal next_id
        next_id += 1
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params or {}}) + "\n")
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        assert response["id"] == next_id
        if "error" in response:
            raise RuntimeError(response["error"])
        return response["result"]

    def call(name, arguments=None, expect_error=False):
        result = rpc("tools/call", {"name": name, "arguments": arguments or {}})
        if expect_error:
            assert result.get("isError"), result
            return result
        if result.get("isError"):
            raise RuntimeError(result["content"])
        return json.loads(result["content"][0]["text"])

    def wait_until(predicate, seconds=30):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            state = call("dogsc_status")
            if predicate(state):
                return state
            if state["error"] or state["export"]["error"]:
                raise RuntimeError(state["error"] or state["export"]["error"])
            time.sleep(.25)
        raise RuntimeError("Timed out waiting for app state")

    try:
        assert rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "dogsc-smoke", "version": "1"}})["protocolVersion"] == "2025-03-26"
        process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n'); process.stdin.flush()
        catalog = rpc("tools/list")["tools"]
        state = call("dogsc_status")
        if state["activePhase"] != "setup" or state["projectPath"]:
            raise RuntimeError("Close the current project before running this opt-in synthetic test")
        artifact = ROOT / ".build" / ("mcp-smoke-" + uuid.uuid4().hex[:8])
        package = artifact / "LUT Acceptance.dogscproject"
        (package / "media").mkdir(parents=True)
        (package / "events").mkdir()
        project = call("dogsc_project_get")["project"]
        project.update(title="LUT Acceptance (synthetic)", createdAt=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        project["camera"].update(position={"x": .5, "y": .5}, size=.7, isHidden=False, shadowStrength=0, borderWidth=0, roundness=0, isMirrored=False)
        project["canvas"].update(padding=0, cornerRadius=0, shadowStrength=0, borderWidth=0)
        project["openingSequence"]["isEnabled"] = False
        project["exportSettings"].update(frameRate=30, resolution="原始素材")
        project["media"] = {"screen": {"relativePath": "media/screen.mp4", "startOffset": 0}, "camera": {"relativePath": "media/camera.mp4", "startOffset": 0}}
        project["capture"]["recordsCamera"] = True
        for name, color in [("screen", "gray"), ("camera", "blue")]:
            subprocess.run([ffmpeg, "-v", "error", "-f", "lavfi", "-i", f"color=c={color}:s=320x180:r=30:d=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(package / "media" / (name + ".mp4"))], check=True)
        (package / "project.json").write_text(json.dumps(project, ensure_ascii=False))
        camera = package / "media/camera.mp4"
        before_hash = hashlib.sha256(camera.read_bytes()).hexdigest()
        cube = artifact / "red.cube"
        cube.write_text("LUT_3D_SIZE 2\n" + "1 0 0\n" * 8)
        call("dogsc_project_open", {"path": str(package)})
        wait_until(lambda s: s["editorReady"] and s["projectPath"] == str(package))
        call("dogsc_lut", {"action": "import", "path": str(cube)})
        snapshot = call("dogsc_project_get")
        assert snapshot["project"]["camera"]["lut"]["name"] == "red"
        call("dogsc_project_patch", {"expectedRevision": "stale", "patch": {"camera": {"size": .5}}}, expect_error=True)
        call("dogsc_project_patch", {"expectedRevision": snapshot["revision"], "patch": {"camera": {"size": 99}}}, expect_error=True)
        call("dogsc_project_patch", {"expectedRevision": snapshot["revision"], "patch": {"camera": {"typo": 1}}}, expect_error=True)
        updated = call("dogsc_project_patch", {"expectedRevision": snapshot["revision"], "patch": {"title": "MCP changed title"}})
        assert updated["project"]["title"] == "MCP changed title"
        undone = call("dogsc_history", {"action": "undo"})
        assert undone["project"]["title"] == project["title"]
        call("dogsc_history", {"action": "redo"})
        timeline = call("dogsc_timeline", {"action": "list"})
        split = call("dogsc_timeline", {"action": "split", "time": 1, "expectedRevision": timeline["revision"]})
        assert len(split["segments"]) == 2
        call("dogsc_history", {"action": "undo"})
        wait_until(lambda s: s["editorReady"])
        call("dogsc_project_save")
        saved = json.loads((package / "project.json").read_text())
        assert saved["camera"]["lut"]["rgbaData"]
        cube.rename(artifact / "red-original-moved.cube")  # Export must use embedded data.
        output = artifact / "graded.mp4"
        call("dogsc_export", {"path": str(output)})
        wait_until(lambda s: not s["export"]["running"] and s["export"]["path"] == str(output), seconds=60)
        call("dogsc_export", {"path": str(output)}, expect_error=True)
        assert hashlib.sha256(camera.read_bytes()).hexdigest() == before_hash
        pixel = subprocess.run([ffmpeg, "-v", "error", "-ss", "1", "-i", str(output), "-vf", "crop=2:2:iw/2:ih/2,format=rgb24", "-frames:v", "1", "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
        assert pixel[0] > 200 and pixel[1] < 40 and pixel[2] < 40, list(pixel[:3])
        # Disable the LUT and verify the very same camera footage returns to blue.
        call("dogsc_lut", {"action": "configure", "enabled": False})
        original = artifact / "bypass.mp4"
        call("dogsc_export", {"path": str(original)})
        wait_until(lambda s: not s["export"]["running"] and s["export"]["path"] == str(original), seconds=60)
        blue = subprocess.run([ffmpeg, "-v", "error", "-ss", "1", "-i", str(original), "-vf", "crop=2:2:iw/2:ih/2,format=rgb24", "-frames:v", "1", "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
        assert blue[2] > 200 and blue[0] < 40 and blue[1] < 40, list(blue[:3])
        call("dogsc_lut", {"action": "configure", "enabled": True})
        call("dogsc_project_save")
        source_job = call("dogsc_sources_export", {"directory": str(artifact / "source-copies")})
        source_state = wait_until(lambda s: s.get("sourceExport", {}).get("jobID") == source_job["jobID"] and not s["sourceExport"]["running"])
        assert not source_state["sourceExport"]["error"]
        copied_hashes = {hashlib.sha256(path.read_bytes()).hexdigest() for path in Path(source_state["sourceExport"]["path"]).iterdir() if path.is_file()}
        assert before_hash in copied_hashes
        report = {"passed": True, "tools": len(catalog), "project": str(package), "gradedExport": str(output), "bypassExport": str(original), "gradedCenterRGB": list(pixel[:3]), "bypassCenterRGB": list(blue[:3]), "sourceUnchanged": True, "checks": ["MCP stdio handshake/discovery", "project open", "LUT import", "stale revision rejection", "invalid style and unknown field rejection", "undo/redo", "timeline split/undo", "save embedded LUT", "export after moving original LUT", "existing output rejection", "graded vs bypass decoded pixels"]}
        (artifact / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
        print(json.dumps(report, ensure_ascii=False, indent=2))
    finally:
        process.stdin.close()
        process.wait(timeout=5)


if __name__ == "__main__":
    main()
