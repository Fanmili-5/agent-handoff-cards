import shlex
import tempfile
import unittest
from pathlib import Path

from handoff import DIRECTORY, Workspace, agent_prompt, approval_digest
from tools.local_config import read_object, revision, write_object


class HandoffTests(unittest.TestCase):
    def test_current_draft_requires_review_and_supports_both_return_steps(self):
        with tempfile.TemporaryDirectory(prefix="agent handoff workspace ") as directory:
            root = Path(directory).resolve()
            store = Workspace(root)
            card = store.create("工作台指南", "写一个快速上手段落", ["docs/WORKBENCH.md"])
            key = card["id"]
            prompt = agent_prompt(card, root)
            self.assertEqual(prompt["client"], "Antigravity / Gemini")
            commands = [line for line in prompt["prompt"].splitlines() if line.startswith("python3 ")]
            self.assertEqual(len(commands), 2)
            for command in commands:
                args = shlex.split(command)
                self.assertEqual(args[args.index("--workspace") + 1], str(root))
            with self.assertRaises(ValueError):
                store.advance(key, "report", "跳过确认")
            old_draft = store.advance(key, "draft", "草稿一")
            current = store.advance(key, "draft", "草稿二")
            with self.assertRaises(ValueError):
                store.advance(key, "approve", approval_digest(old_draft))
            approved = store.advance(key, "approve", approval_digest(current))
            self.assertEqual(agent_prompt(approved, root)["client"], "Codex")
            with self.assertRaises(ValueError):
                store.advance(key, "draft", "试图更改已确认草稿")
            with self.assertRaises(ValueError):
                store.advance(key, "polish", "还没有结果")
            result = store.advance(key, "report", "修改 docs/WORKBENCH.md，检查通过")
            self.assertEqual(agent_prompt(result, root)["client"], "Antigravity / Gemini")
            final = store.advance(key, "polish", "定稿")
            self.assertEqual(final["stage"], "complete")
            self.assertEqual(final["polish"], "定稿")
            self.assertEqual(store.list(), [final])
            self.assertFalse((root / "docs/WORKBENCH.md").exists())

    def test_outside_paths_and_edited_approval_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            store = Workspace(root)
            (root / "outside").symlink_to(root.parent, target_is_directory=True)
            for path in ("../a", "/absolute", "outside/task", f"{DIRECTORY}/own.json"):
                with self.assertRaises(ValueError):
                    store.create("新任务", "目标", [path])
            card = store.create("新任务", "目标", ["one.txt"])
            key = card["id"]
            draft = store.advance(key, "draft", "初稿")
            store.advance(key, "approve", approval_digest(draft))
            location = store.location(key)
            modified = read_object(location)
            modified["scope"] = ["another.txt"]
            write_object(location, modified, revision(location))
            with self.assertRaises(ValueError):
                store.advance(key, "report", "执行结果")


if __name__ == "__main__":
    unittest.main()
