# Changelog / 更新日志

## 0.1.1 — 2026-10-21

- Added Chinese (default) and English in **Settings → Interface Language**, with saved preferences and support for existing settings files.
- Localized desktop menus, controls, status labels, messages and the terminal find bar. Open controls update without restarting terminal sessions; shortcut actions remain the same.
- Remote pairing, controls, input receipts and error messages follow the desktop language. Commands, paths, terminal output and unsent drafts retain their original contents.
- Added native and headless-browser language regression checks; verified existing input, remote drafts, reading and polling behavior.

- 新增「设置 → 界面语言」，默认中文，可选英文；自动保存并兼容已有设置文件。
- 桌面菜单、按钮、状态、提示和终端查找栏统一切换语言，不重启终端会话，快捷键动作保持一致。
- 远程配对、控制、输入回执和错误提示跟随桌面语言；保留命令、目录、终端原始输出与未发送草稿。
- 新增原生及无头浏览器双语回归，验证既有终端输入、远程草稿、阅读和轮询行为。

Distribution remains Apple silicon / macOS 14+, ad-hoc signed, without Developer ID signing or notarization. Physical-phone, cellular and long-duration coverage remains limited.

安装包仍适用于 Apple silicon／macOS 14+，采用 ad-hoc 签名，未做 Developer ID 签名或公证；真机手机、蜂窝网络和长时验证边界不变。

## 0.1.0 — 2026-10-21

Initial public release: grouped terminal sessions, supported Agent status, layout persistence, appearance settings and phone remote access.

首次开源发布：目录分组、多终端、受支持的 Agent 状态、布局保存、外观设置和手机远程访问。
