# shorin-pac

基于 fzf 的简易 TUI 程序，方便在 Arch 上进行 pacman、AUR、Flatpak 软件的卸载和安装，支持 AI 审核 AUR、AI 清理软件残留等功能。

Simple fzf-based TUI to install and remove pacman, AUR and Flatpak packages on Arch Linux, with AI-assisted AUR review and AI-assisted leftover cleanup.

## 安装 / Install

```
paru -S shorin-pac-git      # 或 yay -S shorin-pac-git
pac config                  # 选择 AI 供应商和模型（可选，不配也能用本机 CLI 或公共 key）
```

装好就是两个命令：`pac` 安装、`pacr` 卸载。

## 命令 / Commands

| 命令 | 作用 |
|---|---|
| `pac [关键词]` | 模糊搜索并安装 pacman / AUR 包，AUR 包安装前可做 AI 安全审查 |
| `pac --check [关键词]` | 只审查 AUR 包，不安装 |
| `pacr [关键词]` | 模糊搜索并卸载 pacman / AUR / Flatpak 包；回车后询问是否用 AI 检测家目录残留，fzf 里按 Alt+C 直接“卸载并清残留” |
| `pacr --scan [关键词]` | 只检测并列出残留，不卸载不删除 |
| `pacr --clean` / `--no-clean` / `--rm` | 不询问直接检测 / 跳过检测 / 残留直接删除而不是进回收站 |
| `pac --no-ai` / `pacr --no-ai` | 本次不用 AI，见下面「关掉 AI」 |
| `pac config` | 配置 AI 供应商和模型（菜单）；也有 `select` / `show` / `set` / `add` / `remove` / `test` / `ai` / `tools` / `miyu` 子命令 |

## 残留清理是怎么做的 / How leftover cleanup works

1. 选好要卸载的包后，pacr 先（在卸载之前）收集包的描述、上游 URL、二进制名、desktop 文件，派生出匹配关键词。
2. 在家目录按“每个应用一个条目”的粒度枚举候选：`~/.config`、`~/.cache`、`~/.local/share`、`~/.local/state`、`~/.var/app`、根级点目录，外加对 `Documents` 等可见目录的限深关键词搜索（能找到 `~/Documents/Tencent Files` 这类偏门位置）。
3. 候选连同包信息交给 AI 判断置信度；本机 CLI 后端还允许 AI 用只读命令自己再找找。AI 没提到但与包名完全同名的候选也会以低置信度列出，由你决定。
4. fzf 里勾选（高置信度预选）→ 确认卸载 → 卸载 → 卸载成功后才把勾选项移入回收站（`gio trash` → `trash-put` → 手写 FreeDesktop 规范，都没有就直接删）。
5. 硬边界：只动家目录；`.ssh`、`.gnupg`、密钥环、shell rc、`Documents` 这类顶层目录本身、共享的 mime/icons/fonts 等永远不会出现在清单里，AI 给出的路径也要过同一道校验。

## AI 供应商 / AI providers

AI 只负责“看证据、给结论”：pac 自己收集 PKGBUILD、`.install`、补丁、AUR 元数据和 git 历史，交给模型做一次性审查，模型返回结构化结果，由 pac 渲染报告并把关风险等级。所有后端行为一致。

可用后端：

| 供应商 | 说明 |
|---|---|
| 自定义 HTTP | OpenAI Chat Completions 兼容端点（DeepSeek、智谱、OpenRouter、Ollama…）、OpenAI Responses 端点或 Anthropic Messages 端点，在 `pac config` 里添加 |
| `claude-code` | 本机 `claude` CLI，走 Claude 订阅额度 |
| `codex` | 本机 `codex` CLI |
| `antigravity` | 本机 `agy` CLI |
| `opencode` | 本机 `opencode` CLI |
| `miyu` | 本机 [Miyu](https://github.com/SHORiN-KiWATA/Miyu)，交给 Miyu 当前的模型路由 |
| `public` | opencode zen 公共 key（免配置，但额度很小，常被限流，只作兜底） |

本机 CLI 后端允许模型使用只读工具（读构建目录、查 AUR RPC、搜索）补充查证；`pac config tools off` 可以关闭。

opencode zen 从 09-19 起给免费模型加了一道「只能从 OpenCode 里用」的闸，第三方客户端一律 `403 · OpenCode's free tier can only be used from within OpenCode`。实测判据是请求得长得像 opencode 发的：流式、工具清单里有 `shell` 和 `read`、带 `x-opencode-*` 头。所以发往 `opencode.ai/zen` 的请求（`public` 兜底和自己配的 zen 节点）会自动改成这个形状——流式，外加两条永不调用的占位工具声明，HTTP 后端本身仍然不开工具。其他端点一个字节都不动。这是对面服务端的策略，他们随时可能改判据。

选择顺序：`--ai <供应商[:模型]>` 参数 > 环境变量 `SHORIN_PAC_AI` > `pac config` 里的选择 > 自动探测（opencode → claude → codex → agy → miyu → public）。

### 关掉 AI / Turning AI off

不想用 AI 的话，两条命令都退回纯粹的包管理器包装器：

- 只关这一次：`pac --no-ai <包名>`、`pacr --no-ai <包名>`。
- 永久关掉：`pac config` 菜单第一项「AI 功能总开关」，或直接 `pac config ai off`（`pac config ai on` 打开）。开关存在 `~/.config/shorin-pac/config.json` 的 `ai_enabled` 里，老配置没有这一项时按开着算。

关掉之后：

- `pac` 不再审查 AUR 包，也不会每个包追问一遍「不审查直接安装?」，直接交给 paru / yay 安装。这时**不再传 `--skipreview`**，paru 自己那道 PKGBUILD 复核照常出现——你关的是 AI，不是所有复核。
- `pacr` 不再检测残留，也不再追问。仍然想要没有 AI 的那版（纯按名称匹配的启发式）就明确写 `pacr --clean` 或 `pacr --scan`。
- `pac --check` 是「只做 AI 审查」，和关掉 AI 自相矛盾：和 `--no-ai` 一起给会直接报错，总开关关着时会提示后退出。
- `pac config` 本身不受开关影响，否则关掉就没法再打开了。

### 与 Miyu 互通

装了 Miyu 的话，`~/.miyu/config/config.jsonc` 里的供应商和模型会以 `miyu/<id>` 的名字出现在选择列表里（含 API key、Claude Code / Antigravity / Codex 中转线），shorin-pac 只读不写。不想导入可以用 `pac config miyu off` 关掉。

## 与 shorin-contrib 的关系 / Relationship to shorin-contrib

这几个脚本原本在 [shorin-contrib](https://github.com/SHORiN-KiWATA/shorin-contrib) 里。现在 `shorin-contrib` 依赖 `shorin-pac`，`shorin pac`、`shorin pacr` 会转交给全局的 `pac` / `pacr`，`shorin pacrrr` 转到 `pacr --clean`，老用法不受影响。之前用 `shorin link` 在 `~/.local/bin` 里建的 `pac` / `pacr` 链接会失效并遮住新命令，重跑一次 `shorin link` 会自动清理。

## 配置与缓存 / Paths

- 配置：`~/.config/shorin-pac/config.json`（含 API key，权限 600）
- 缓存：`~/.cache/shorin-pac/`

## 许可 / License

GPL-3.0-or-later
