# Agent Handoff Cards

macOS 上的本地交接卡。让 Antigravity Gemini 起草方案，交给 Codex 执行，最后由 Gemini 根据实际结果润色。

[快速上手](#快速上手) · [交接流程](#交接流程) · [命令行与 Skill](#命令行与-skill)

## 快速上手

准备 macOS 13 或更新版本、Python 3.9+ 和 Xcode Command Line Tools。在解压后的源码目录运行：

```bash
python3 -B workbench.py
```

首次启动会在本机构建 `dist/Agent Handoff.app`。选择两个客户端都能访问的项目，创建一张卡，填入目标和允许修改的相对路径。只交付文字时，文件清单留空。

工作台无需安装 Hub 补丁或配置 API key。Codex 和 Antigravity 使用各自的登录。

## 交接流程

| 顺序 | 在哪里操作 | 写回交接卡的内容 |
| --- | --- | --- |
| **Gemini 构思** | 从工作台复制构思指令，发到 Antigravity | 方案、取舍与推荐初稿 |
| **你确认** | 在工作台核对初稿和文件清单，点一次「确认执行范围」 | 审阅通过的任务及范围 |
| **Codex 执行** | 从工作台复制执行指令，发到同一项目的 Codex 会话 | 改动文件、实跑的检查和待润色文字 |
| **Gemini 润色** | 复制润色指令，发回 Antigravity | 保留原始事实和测试结果的定稿 |

每段指令由用户发送。初稿、报告和定稿都写回同一张卡，切回工作台即可查看。

## 命令行与 Skill

在工具源码目录运行。把 `/path/to/project` 换成实际项目目录。`new` 返回的卡号用于之后的 `show` 和 `prompt`。

```bash
python3 -B handoff.py --workspace /path/to/project new \
  --title '完善启动说明' --goal '写清启动步骤并核对预期输出' --scope README.md
python3 -B handoff.py --workspace /path/to/project show CARD
python3 -B handoff.py --workspace /path/to/project prompt CARD
```

工作台生成的指令带有 Skill 和 CLI 的绝对路径，工具源码可以和任务项目分开放。如果客户端询问读取权限，只需允许访问工具目录中用到的 Skill 和脚本。

用 CLI 确认时，先审阅 `show CARD` 显示的初稿、范围和 `digest`，再由用户运行 `approve CARD --digest DIGEST`。`draft`、`report` 和 `polish` 可通过标准输入或 `--file` 写回。 [交接卡 Skill](.agents/skills/agent-handoff/SKILL.md)

## 数据与权限

卡片保存在项目的 `.agent-handoff/`。请把该目录加入项目的 Git 排除清单。确认记录绑定你审阅的初稿和范围。发送指令后，客户端可按各自的权限读取材料，并将所需内容提交给对应服务。

## 兼容性

已在 Apple Silicon、macOS 26.5.1 上验证。其他 macOS 或 Intel Mac 仍待验证。

## 开发

```bash
python3 -B -m unittest discover -s tests
python3 -B workbench.py --build-only
```

[MIT 许可](LICENSE)
