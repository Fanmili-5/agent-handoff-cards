#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import json
import os
import re
import shlex
import sys
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from uuid import uuid4

from tools.local_config import read_object, revision, write_object

DIRECTORY = ".agent-handoff"
LIMIT = 24_000
TRANSITIONS = {
    "draft": ("planning", "review"),
    "approve": ("review", "execution"),
    "report": ("execution", "copyedit"),
    "polish": ("copyedit", "complete"),
}
TEXT_FIELDS = ("draft", "report", "polish")


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def clean_text(value, label, limit=LIMIT):
    if not isinstance(value, str):
        raise ValueError(f"{label}需要是文本。")
    value = value.strip()
    if not value or len(value) > limit or "\0" in value:
        raise ValueError(f"{label}需要 1 至 {limit} 字。")
    return value


def scope_path(value):
    path = PurePosixPath(value)
    if (not value or len(value) > 500 or path.is_absolute() or path.as_posix() != value
            or not path.parts or ".." in path.parts or path.parts[0] in {".git", DIRECTORY}
            or any(ord(char) < 32 for char in value)):
        raise ValueError("执行范围需要工作区内的具体相对文件路径。")
    return value


def approval_digest(card):
    snapshot = [card[key] for key in ("id", "title", "goal", "scope", "draft")]
    encoded = json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


class Workspace:
    def __init__(self, workspace):
        self.root = workspace.resolve(strict=True)
        self.directory = self.root / DIRECTORY
        if not self.root.is_dir() or self.directory.is_symlink():
            raise ValueError("请选择有效的工作区目录。")

    def location(self, card_id):
        if not re.fullmatch(r"[0-9a-f]{12}", card_id):
            raise ValueError("交接卡编号无效。")
        return self.directory / (card_id + ".json")

    @contextmanager
    def writing(self):
        self.directory.mkdir(mode=0o700, exist_ok=True)
        flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
        fd = os.open(self.directory / ".lock", flags, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)

    def read(self, card_id):
        location = self.location(card_id)
        if location.is_symlink() or not location.is_file() or location.stat().st_size > 512 * 1024:
            raise ValueError("找不到交接卡，或卡片文件无效。")
        card = read_object(location)
        if card.get("version") != 1 or card.get("id") != card_id:
            raise ValueError("交接卡版本或编号不匹配。")
        if card["stage"] in {"execution", "copyedit", "complete"}:
            if card.get("approval") != approval_digest(card):
                raise ValueError("确认后的任务或初稿已经变更。请为新范围创建交接卡。")
        return card

    def list(self):
        cards = []
        for path in self.directory.glob("*.json"):
            if re.fullmatch(r"[0-9a-f]{12}", path.stem):
                cards.append(self.read(path.stem))
        return sorted(cards, key=lambda card: (card["updated"], card["id"]), reverse=True)

    def create(self, title, goal, scope):
        paths = list(dict.fromkeys(scope_path(name) for name in scope))
        if len(paths) > 30:
            raise ValueError("每张卡最多允许 30 个文件。")
        for name in paths:
            if not (self.root / name).resolve().is_relative_to(self.root):
                raise ValueError("执行范围不能指向工作区以外。")
        card = {
            "version": 1,
            "id": uuid4().hex[:12],
            "title": clean_text(title, "标题", 80),
            "goal": clean_text(goal, "任务目标", 4000),
            "scope": paths,
            "stage": "planning",
            "updated": now(),
        }
        with self.writing():
            write_object(self.location(card["id"]), card, None)
        return card

    def advance(self, card_id, action, value):
        with self.writing():
            location = self.location(card_id)
            previous = revision(location)
            card = self.read(card_id)
            source, destination = TRANSITIONS[action]
            if card["stage"] != source and (action != "draft" or card["stage"] != "review"):
                raise ValueError("当前阶段不能进行这一步，请刷新卡片。")
            if action == "approve":
                if value != approval_digest(card):
                    raise ValueError("初稿已更新，请重新阅读后确认。")
                card["approval"] = value
            else:
                card[action] = clean_text(value, {"draft": "初稿", "report": "执行结果", "polish": "润色稿"}[action])
            card.update(stage=destination, updated=now())
            write_object(location, card, previous)
            return card


def agent_prompt(card, workspace):
    key = card["id"]
    stage = card["stage"]
    root = Path(__file__).resolve().parent
    skill = root / ".agents/skills/agent-handoff/SKILL.md"
    command = ["python3", "-B", str(root / "handoff.py"), "--workspace", str(workspace)]
    phases = {
        "planning": (
            "Antigravity / Gemini", "draft",
            "拟一份方案或初稿，写回交接卡，等待用户确认。",
        ),
        "execution": (
            "Codex", "report",
            "核对卡片处于 execution。按确认的范围执行，记录改动和检查结果。",
        ),
        "copyedit": (
            "Antigravity / Gemini", "polish",
            "根据执行报告润色文字。保留事实、测试结果和限制，把定稿写回交接卡。",
        ),
    }
    if stage not in phases:
        raise ValueError("当前阶段没有需要转交给 Agent 的操作。")
    client, action, instruction = phases[stage]
    show = shlex.join([*command, "show", key])
    write = shlex.join([*command, action, key])
    text = (
        f"先阅读交接卡 Skill（{skill}）。\n\n"
        f"读取卡片。\n\n{show}\n\n"
        f"{instruction}\n"
        f"用标准输入写回，或追加 --file 并指定 UTF-8 文件。\n\n{write}"
    )
    return {"client": client, "prompt": text}


def public_card(card, workspace):
    output = dict(card)
    if card["stage"] == "review":
        output["digest"] = approval_digest(card)
    if card["stage"] in {"planning", "execution", "copyedit"}:
        output.update(agent_prompt(card, workspace))
    return output


def read_text(file, value):
    if file is None:
        return value if value is not None else sys.stdin.read(LIMIT + 1)
    with file.open(encoding="utf-8") as handle:
        return handle.read(LIMIT + 1)


def main():
    parser = argparse.ArgumentParser(description="在本地工作区传递任务交接卡。")
    parser.add_argument("--workspace", type=Path, default=Path.cwd())
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("list")
    create = commands.add_parser("new")
    create.add_argument("--title", required=True)
    create.add_argument("--goal", required=True)
    create.add_argument("--scope", action="append", default=[])
    for name in ("show", "prompt", *TRANSITIONS):
        operation = commands.add_parser(name)
        operation.add_argument("id")
        if name == "approve":
            operation.add_argument("--digest", required=True)
        if name in TEXT_FIELDS:
            body = operation.add_mutually_exclusive_group()
            body.add_argument("--file", type=Path)
            body.add_argument("--text")
    args = parser.parse_args()
    workspace = Workspace(args.workspace)
    if args.action == "list":
        cards = [public_card(card, workspace.root) for card in workspace.list()]
        print(json.dumps(cards, ensure_ascii=False, indent=2))
        return
    elif args.action == "new":
        card = workspace.create(args.title, args.goal, args.scope)
    elif args.action == "show":
        card = workspace.read(args.id)
    elif args.action == "prompt":
        print(agent_prompt(workspace.read(args.id), workspace.root)["prompt"])
        return
    else:
        value = args.digest if args.action == "approve" else read_text(args.file, args.text)
        card = workspace.advance(args.id, args.action, value)
    print(json.dumps(public_card(card, workspace.root), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError) as error:
        raise SystemExit(f"交接卡操作未完成：{error}")
