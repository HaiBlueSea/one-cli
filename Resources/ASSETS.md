# Bundled resources / 内置资源

All listed licenses and copyright notices are retained under `Licenses/`. Original One Cli artwork is covered by the root MIT license. Product marks remain the property of their owners and are used only to identify the corresponding CLI.

| Resource | Source / version | License |
| --- | --- | --- |
| SwiftTerm | [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), v1.99.0 / `2dad6a1`, modified build slice | MIT; modifications listed in `Vendor/SwiftTerm/README.md` |
| Hack | [source-foundry/Hack](https://github.com/source-foundry/Hack), v3.003 | MIT + Bitstream Vera; `Hack-LICENSE` |
| JetBrains Mono | [JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono), v2.304 | OFL 1.1; `JetBrainsMono-OFL.txt` |
| Fira Code | [tonsky/FiraCode](https://github.com/tonsky/FiraCode), 6.2 | OFL 1.1; `FiraCode-OFL.txt` |
| OpenAI mark | [Simple Icons 13.21.0](https://github.com/simple-icons/simple-icons/tree/13.21.0), `icons/openai.svg` | CC0 material; `SimpleIcons-LICENSE`; OpenAI trademark |
| Claude mark | Simple Icons 13.21.0; blob `1beee8612185a8fb0a23bcfd8c3ce9b6d86785a8` | CC0 material; `SimpleIcons-LICENSE`; Anthropic trademark |
| Cursor mark | Simple Icons; blob `61303fbcc34fe825b8c33685980dfd68984934c9`, revision `be23679deda9e227ded614e94a1dc262ff930cf1` | CC0 material; `SimpleIcons-LICENSE`; respective trademark |
| Kimi mark | [lobehub/lobe-icons](https://github.com/lobehub/lobe-icons); blob `1915850ee50ea636cc34b37aa11ba7f1ae0a26a2` | MIT material; `LobeIcons-LICENSE`; respective trademark |
| xterm.js | [xtermjs/xterm.js](https://github.com/xtermjs/xterm.js), `@xterm/xterm` 5.5.0 | MIT; `xtermjs-LICENSE` |
| cloudflared | [cloudflare/cloudflared 2026.8.2](https://github.com/cloudflare/cloudflared/releases/tag/2026.8.2), darwin arm64 | Apache-2.0; `cloudflared-LICENSE` and `cloudflared-THIRD-PARTY-NOTICES.txt` |

Fonts are registered within the app process, not installed system-wide. SVG marks are accompanied by PDF renderings for AppKit. The source `Tools/cloudflared` is an arm64 Mach-O executable, 38,909,248 bytes, SHA-256 `b61054d3d6326ea558cb49826eebf5676e0d0a36d51b546975096ca3e0e3c89d`. The packaging script ad-hoc re-signs the bundled copy, changing its bytes and hash; it does not modify its program code. Auto-update is disabled; replacing it requires rebuilding and retaining the matching notices. The notice file includes licenses from 95 upstream vendor files and may cover dependencies not linked into this binary.

## Theme palette attribution

The app implements its own terminal appearance settings using named color palettes. Palette sources and included upstream notices:

| Palette | Source | Notice |
| --- | --- | --- |
| Catppuccin Mocha | [catppuccin/catppuccin](https://github.com/catppuccin/catppuccin) | `Catppuccin-LICENSE` |
| Tokyo Night | [enkia/tokyo-night-vscode-theme](https://github.com/enkia/tokyo-night-vscode-theme) | `TokyoNight-LICENSE` |
| Dracula | [dracula/dracula-theme](https://github.com/dracula/dracula-theme) | `Dracula-LICENSE` |
| Nord | [nordtheme/nord](https://github.com/nordtheme/nord) | `Nord-LICENSE` |
| Gruvbox | [gruvbox-community/gruvbox](https://github.com/gruvbox-community/gruvbox) | `Gruvbox-LICENSE` |
| Rosé Pine | [rose-pine/rose-pine-theme](https://github.com/rose-pine/rose-pine-theme) | `RosePine-LICENSE` |
| Kanagawa | [rebelot/kanagawa.nvim](https://github.com/rebelot/kanagawa.nvim) | `Kanagawa-LICENSE` |

## Trademarks / 商标

Material licenses do not grant trademark rights. See [OpenAI brand guidelines](https://openai.com/brand/), [Cursor brand guidelines](https://cursor.com/brand), and [Simple Icons’ disclaimer](https://github.com/simple-icons/simple-icons/blob/13.21.0/DISCLAIMER.md). One Cli has no claimed endorsement, sponsorship or official partnership with the named providers. These marks must not be presented as One Cli’s identity, transferred under its MIT license, or repurposed as proof of partnership. A license inventory is not a legal clearance of every branding use.

以上许可仅覆盖相应素材或软件，不能替代商标授权。One Cli 是独立项目，第三方名称和标志仅识别对应工具，不代表官方合作、赞助或背书。分发时应保留本文件、原许可和声明；不要将第三方资源统一改标为 MIT。
