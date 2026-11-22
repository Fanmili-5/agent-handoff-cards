#!/usr/bin/env python3
import argparse
import hashlib
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCES = ("macos/App.swift", "macos/Handoff.swift", "macos/WorkbenchLanguage.swift")
LOCALIZATIONS = ("en.lproj/Localizable.strings", "zh-Hans.lproj/Localizable.strings")
RESOURCES = ("handoff.py", "tools/local_config.py", ".agents/skills/agent-handoff/SKILL.md")


def build():
    if sys.platform != "darwin":
        raise ValueError("图形工作台需要 macOS。")
    dist = ROOT / "dist"
    app = dist / "Agent Handoff.app"
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "agent-handoff",
        "CFBundleIdentifier": "io.github.fanmili5.agent-handoff",
        "CFBundleName": "Agent Handoff",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "4",
        "LSMinimumSystemVersion": "13.0",
        "HandoffPython": sys.executable,
    }
    manifest = plistlib.dumps(info)
    digest = hashlib.sha256(manifest)
    resource_paths = {name: name for name in RESOURCES}
    resource_paths.update({name: f"macos/{name}" for name in LOCALIZATIONS})
    for name in ("workbench.py", *SOURCES, *resource_paths.values()):
        digest.update(hashlib.sha256((ROOT / name).read_bytes()).digest())
    fingerprint = digest.hexdigest()
    marker = app / "Contents/Resources/source.sha256"
    built = app / "Contents/MacOS/agent-handoff"
    if built.is_file() and marker.is_file() and marker.read_text() == fingerprint:
        return app

    dist.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".build-", dir=dist) as temporary:
        stage = Path(temporary) / app.name
        contents = stage / "Contents"
        executable = contents / "MacOS/agent-handoff"
        executable.parent.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(manifest)
        resources = contents / "Resources"
        for destination, source in resource_paths.items():
            target = resources / destination
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / source, target)
        subprocess.run([
            "/usr/bin/xcrun", "swiftc", "-O", "-module-cache-path", Path(temporary) / "cache",
            *(ROOT / name for name in SOURCES), "-o", executable,
        ], env={**os.environ, "MACOSX_DEPLOYMENT_TARGET": "13.0"}, check=True)
        (resources / "source.sha256").write_text(fingerprint)
        subprocess.run(["/usr/bin/codesign", "--sign", "-", "--force", stage], check=True)
        previous = Path(temporary) / "previous.app"
        if app.exists():
            app.rename(previous)
        try:
            stage.rename(app)
        except OSError:
            if previous.exists():
                previous.rename(app)
            raise
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="构建并打开独立的交接卡工作台。")
    parser.add_argument("--build-only", action="store_true", help="构建后在终端显示应用路径")
    args = parser.parse_args()
    try:
        app = build()
        if not args.build_only:
            subprocess.run(["/usr/bin/open", "-a", app], check=True)
        print(app)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"工作台未能构建或打开：{error}")
