# shorin-pac

基于 fzf 的简易 TUI 程序，方便在 Arch 上进行 pacman、AUR、Flatpak 软件的卸载和安装，支持 AI 审核 AUR、AI 清理软件残留等功能。

Simple fzf-based TUI to install and remove pacman, AUR and Flatpak packages on Arch Linux, with AI-assisted AUR review and AI-assisted leftover cleanup.

## 安装 / Install

```
paru -S shorin-pac-git      # 或 yay -S shorin-pac-git
shorin-pac link             # 把 pac / pacr 链接到 ~/.local/bin
```

`shorin-pac link` 之后可以直接输入 `pac` 安装、`pacr` 卸载。不想链接的话也可以用 `shorin-pac pac` / `shorin-pac pacr`。

## 命令 / Commands

| 命令 | 作用 |
|---|---|
| `pac [关键词]` | 模糊搜索并安装 pacman / AUR 包，AUR 包安装前可做 AI 安全审查 |
| `pacr [关键词]` | 模糊搜索并卸载 pacman / AUR / Flatpak 包，可用 AI 检测家目录残留 |
| `shorin-pac config` | 配置 AI 供应商和模型 |
| `shorin-pac link` / `unlink` | 管理 `~/.local/bin` 中的 `pac` / `pacr` 链接 |

## 与 shorin-contrib 的关系 / Relationship to shorin-contrib

这三个脚本原本在 [shorin-contrib](https://github.com/SHORiN-KiWATA/shorin-contrib) 里。现在 `shorin-contrib` 依赖 `shorin-pac`，`shorin pac`、`shorin pacr`、`shorin link` 会自动转交给 `shorin-pac`，老用法不受影响。

## 配置与缓存 / Paths

- 配置：`~/.config/shorin-pac/`
- 缓存：`~/.cache/shorin-pac/`

AI 配置可以和 [Miyu](https://github.com/SHORiN-KiWATA/Miyu) 互通：装了 Miyu 的话，Miyu 里配置好的供应商和模型会直接出现在 `shorin-pac config` 的选择列表里。

## 许可 / License

GPL-3.0-or-later
