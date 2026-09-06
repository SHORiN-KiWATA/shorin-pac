# shorin-pac

基于 fzf 的简易 TUI 程序，方便在 Arch 上进行 pacman、AUR、Flatpak 软件的卸载和安装，支持 AI 审核 AUR、AI 清理软件残留等功能。

Simple fzf-based TUI to install and remove pacman, AUR and Flatpak packages on Arch Linux, with AI-assisted AUR review and AI-assisted leftover cleanup.

## 安装 / Install

```
paru -S shorin-pac-git      # 或 yay -S shorin-pac-git
shorin-pac link             # 把 pac / pacr 链接到 ~/.local/bin
shorin-pac config           # 选择 AI 供应商和模型（可选）
```

`shorin-pac link` 之后可以直接输入 `pac` 安装、`pacr` 卸载。不想链接的话也可以用 `shorin-pac pac` / `shorin-pac pacr`。

## 命令 / Commands

| 命令 | 作用 |
|---|---|
| `pac [关键词]` | 模糊搜索并安装 pacman / AUR 包，AUR 包安装前可做 AI 安全审查 |
| `pac --check [关键词]` | 只审查 AUR 包，不安装 |
| `pacr [关键词]` | 模糊搜索并卸载 pacman / AUR / Flatpak 包，可用 AI 检测家目录残留 |
| `shorin-pac config` | 配置 AI 供应商和模型（菜单）；也有 `select` / `show` / `set` / `add` / `remove` / `test` 子命令 |
| `shorin-pac link` / `unlink` | 管理 `~/.local/bin` 中的 `pac` / `pacr` 链接 |

## AI 供应商 / AI providers

AI 只负责“看证据、给结论”：pac 自己收集 PKGBUILD、`.install`、补丁、AUR 元数据和 git 历史，交给模型做一次性审查，模型返回结构化结果，由 pac 渲染报告并把关风险等级。所有后端行为一致。

可用后端：

| 供应商 | 说明 |
|---|---|
| 自定义 HTTP | 任何 OpenAI Chat Completions 兼容端点（DeepSeek、智谱、OpenRouter、Ollama…）或 Anthropic Messages 端点，在 `shorin-pac config` 里添加 |
| `claude-code` | 本机 `claude` CLI，走 Claude 订阅额度 |
| `codex` | 本机 `codex` CLI |
| `antigravity` | 本机 `agy` CLI |
| `opencode` | 本机 `opencode` CLI |
| `miyu` | 本机 [Miyu](https://github.com/SHORiN-KiWATA/Miyu)，交给 Miyu 当前的模型路由 |
| `public` | opencode zen 公共 key（免配置，但额度很小，常被限流，只作兜底） |

本机 CLI 后端默认允许模型使用只读工具（读构建目录、查 AUR RPC、搜索）补充查证，可以在 `shorin-pac config` 里关闭。

选择顺序：`--ai <供应商[:模型]>` 参数 > 环境变量 `SHORIN_PAC_AI` > `shorin-pac config` 里的选择 > 自动探测（opencode → claude → codex → agy → miyu → public）。

### 与 Miyu 互通

装了 Miyu 的话，`~/.miyu/config/config.jsonc` 里的供应商和模型会以 `miyu/<id>` 的名字出现在选择列表里（含 API key、Claude Code / Antigravity / Codex 中转线），shorin-pac 只读不写。不想导入可以在 `shorin-pac config` 里关掉。

## 与 shorin-contrib 的关系 / Relationship to shorin-contrib

这三个脚本原本在 [shorin-contrib](https://github.com/SHORiN-KiWATA/shorin-contrib) 里。现在 `shorin-contrib` 依赖 `shorin-pac`，`shorin pac`、`shorin pacr`、`shorin link` 会自动转交给 `shorin-pac`，老用法不受影响。

## 配置与缓存 / Paths

- 配置：`~/.config/shorin-pac/config.json`（含 API key，权限 600）
- 缓存：`~/.cache/shorin-pac/`

## 许可 / License

GPL-3.0-or-later
