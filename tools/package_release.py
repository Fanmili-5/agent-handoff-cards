import argparse
import hashlib
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.1.0-alpha.4"
FILES = (
    ".agents/skills/agent-handoff/SKILL.md", ".gitignore", "LICENSE", "README.md",
    "docs/README.en.md", "docs/workbench-zh.png", "docs/workbench-en.png",
    "handoff.py", "workbench.py", "macos/App.swift", "macos/Handoff.swift", "tests/test_handoff.py",
    "macos/WorkbenchLanguage.swift", "macos/en.lproj/Localizable.strings", "macos/zh-Hans.lproj/Localizable.strings",
    "tools/local_config.py", "tools/package_release.py",
)


def package(output):
    prefix = f"agent-handoff-cards-v{VERSION}"
    output.mkdir(parents=True, exist_ok=True)
    archive_path = output / f"{prefix}-source.zip"
    with ZipFile(archive_path, "w") as archive:
        for name in sorted(FILES):
            path = ROOT / name
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"发行文件必须是普通文件：{name}")
            content = path.read_bytes()
            if path.suffix == ".png":
                if not content.startswith(b"\x89PNG\r\n\x1a\n"):
                    raise ValueError("交接卡示例必须是 PNG。")
            else:
                content.decode("utf-8")
            member = ZipInfo(f"{prefix}/{name}")
            member.create_system = 3
            member.external_attr = 0o100644 << 16
            archive.writestr(member, content, compress_type=ZIP_DEFLATED)
    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    (output / "SHA256SUMS.txt").write_text(f"{digest}  {archive_path.name}\n")
    return archive_path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="生成 Agent Handoff 源码包及 SHA-256 校验文件。")
    parser.add_argument("--output-dir", type=Path, required=True)
    print(package(parser.parse_args().output_dir))
