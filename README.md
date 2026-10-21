<div align="center">
  <img src="assets/logo.svg" width="76" alt="One Cli logo">
  <h1>One Cli</h1>
  <p><strong>All agents in one.</strong></p>
  <p>A native macOS terminal for working across AI CLI sessions.</p>
  <p>macOS 14+ · Apple silicon · Swift · MIT</p>
  <p><a href="README.zh-CN.md">简体中文</a> · <a href="#get-started">Get started</a> · <a href="#build-from-source">Build</a> · <a href="PRIVACY.md">Privacy</a></p>
</div>

https://github.com/user-attachments/assets/0223f907-79fa-4a1f-a807-c2ec81143094

30-second demo: Claude Code, Codex and mobile remote control. [Download 1080p](https://github.com/HaiBlueSea/one-cli/releases/download/v0.1.0/One-Cli-Launch-Live-1080p.mp4).

![One Cli running with an isolated demo workspace](assets/hero.png)

<sub>Real application capture with demonstration data. Mobile captures use the actual remote backend in a browser’s phone viewport.</sub>

Keep your tools. Bring their terminals together.

One Cli groups sessions by working directory, shows the command you actually launched, and tracks supported agents through native protocols or observation hooks. Pair your phone to read a session and request control when you need it.

## Made for multiple sessions

| Your workflow | What One Cli provides |
| --- | --- |
| Move between projects | Directory groups, Git branch labels and a collapsible sidebar. |
| Run several agents | Independent Zsh terminals, actual command names and supported agent status. |
| Return to your workspace | Saved directories, layout and appearance; a fresh shell for each restored terminal. |
| Make the terminal yours | Seven themes, bundled monospace fonts, font size, line height and color controls. |
| Step away from your Mac | Phone pairing, read-only viewing, explicit control requests and revocation. |

One Cli uses the CLIs you install and authenticate yourself. It does not bundle their accounts, subscriptions or AI models.

## Get started

**Requirements:** Apple silicon Mac, macOS 14 or later. Install and sign in to the CLI tools you want to use. The current interface includes Chinese labels.

1. Download `One-Cli-macos-arm64.zip` and its `.sha256` file from this repository’s **Releases** section.
2. Verify the download in Terminal, from the directory containing both files:

   ```sh
   shasum -a 256 -c One-Cli-macos-arm64.sha256
   ```

3. Unzip the archive, drag **One Cli.app** into Applications, then open it.
4. Start a CLI in a terminal, just as you would in your regular shell.

The current build is **ad-hoc signed, without Developer ID signing or notarization**. macOS may block the first launch. After verifying the source and checksum, use the per-app **Open Anyway** option in System Settings → Privacy & Security if offered. Do not disable Gatekeeper globally. See [Apple’s guidance](https://support.apple.com/en-us/102445).

No Node.js runtime is needed to use the packaged app. If no release is published yet, [build from source](#build-from-source).

## Work at your own pace

| Shortcut | Action |
| --- | --- |
| `⌘N` | New terminal in the current working directory. |
| `⌘W` | Close the selected terminal and remove its layout slot. |
| `⌘,` | Appearance settings. |
| `⌘+` / `⌘−` / `⌘0` | Increase, decrease or reset font size. |
| `⌘` + click | Open a link with the default application. |

Closing a window or quitting preserves the layout. Reopening starts new shells; it does **not** replay commands, resume agent tasks or resend remote input. File links with line numbers currently open the file without jumping to that line.

### Agent status

| CLI | Status integration |
| --- | --- |
| Codex | Native daemon; independent `CODEX_HOME` directories are supported. |
| Claude Code | Observation hooks. |
| Kimi Code | Observation hooks. |
| Cursor | Terminal use is supported; status stays unknown when observation hooks are unavailable. |

Starting with [v0.1.1](https://github.com/HaiBlueSea/one-cli/releases/tag/v0.1.1), **Settings → Interface Language** offers Chinese (default) and English. Menus, buttons, status labels and messages update immediately and save automatically; remote pages follow on their next session-list refresh. Commands, paths, terminal output, shortcut actions and existing sessions are preserved. See the [changelog](CHANGELOG.md) for version changes.

In English, `Running` means working and `Ready` means idle; Chinese displays the corresponding localized labels. Unsupported, disconnected or unverified states stay unknown. Status integration depends on the installed CLI version and is not a promise of compatibility with every release.

For **each Codex configuration**, merge the following into the existing `[tui]` section of its `config.toml`, then restart Codex:

```toml
[tui]
terminal_title = ["session-id"]
```

Do not create a second `[tui]` section. Start Codex through `PATH`; shell functions using `command codex "$@"` are supported. Launching a CLI by its absolute path bypasses the wrapper that reports its effective configuration directory. Observation hooks preserve existing approval settings; review any trust prompt from your CLI.

## Your terminal, on your phone

1. Open the app’s **Remote** panel from the application menu and enable remote access.
2. Scan the pairing QR code with your phone and confirm the pairing on your Mac.
3. Start in read-only mode; request control before sending input.
4. Revoke authorization or turn remote access off when you are done.

<div align="center">
  <img src="assets/remote-readonly.png" width="300" alt="Actual mobile remote page in read-only mode">
  <img src="assets/remote-control.png" width="300" alt="Actual mobile remote page after requesting control">
</div>

**Read first. Control when you choose.** The left capture shows read-only viewing; the right shows the input controls after a control request. Captured against the running app with isolated demo data, without a real account or production session. These are browser phone viewports, not physical-device certification.

| Remote workflow | Behavior |
| --- | --- |
| Start a connection | An on-demand temporary HTTPS address; no router port forwarding is required. |
| Authorize a browser | Scan, then confirm on the Mac; the browser starts read-only. |
| Send input | Request control, use text or terminal keys, then release control. |
| Read longer output | Wrapped reading, local table scrolling, original layout and copying. |
| Reconnect | No automatic input replay; drafts survive failed or delayed sends. |
| End access | Revoke authorization or turn remote off; closing the panel alone does not stop it. |

The app bundles `cloudflared` for a temporary HTTPS endpoint. Traffic passes through Cloudflare; this is not an end-to-end encrypted channel that excludes the tunnel provider. Anyone you authorize may see sensitive terminal output and, with control, execute commands with your shell’s permissions.

The mobile page supports wrapped reading, table scrolling, original terminal view and copying. Refresh returns to read-only; backgrounding releases control. Reconnection does not automatically resend input. Browser authorization can last up to seven days for the same endpoint and browser, but changing the temporary hostname requires pairing again.

## Build from source

**Build requirements:** Apple silicon, macOS 14+, Apple Command Line Tools or Xcode, and **Swift 6.2+**. Check `swift --version`; use a toolchain that supports your target macOS version. SwiftTerm and runtime resources are included locally.

```sh
# From the repository root: build an isolated development app.
sh scripts/build.sh
open "dist/One Cli Dev.app"

# Build the release app, installer ZIP and SHA-256 file.
sh scripts/package.sh
```

| Output | Location |
| --- | --- |
| Development app | `dist/One Cli Dev.app` |
| Release app | `dist/One Cli.app` |
| Installer ZIP | `dist/One-Cli-macos-arm64.zip` |
| Checksum | `dist/One-Cli-macos-arm64.sha256` |

Build scripts do not install or launch the app. The development app uses `com.aiterminal.dev` and a separate support directory. Packaged builds currently target **arm64 only** because the bundled `cloudflared` binary is arm64.

## Data and boundaries

- Release layout and appearance: `~/Library/Application Support/AITerminal/`.
- Development data: `~/Library/Application Support/AITerminalDev/`.
- CLI credentials, history and sessions remain in each CLI’s own configuration directories. Runtime integration may add observation hooks and create local integration files; see [Privacy & local data](PRIVACY.md).
- Remote access is off until enabled. When enabled, terminal contents can leave the Mac through Cloudflare.
- Real-device mobile input, cellular networks, sleep/wake and long-duration stress coverage are limited. This repository does not claim a full security audit or compatibility across all Macs and CLI versions.

To uninstall, quit and remove the app. Removing its support directory is a separate, optional action that deletes its saved layout and preferences; CLI data is managed separately.

## Contributing and licensing

Bug reports and focused contributions are welcome. Read [Contributing](CONTRIBUTING.md) and [Security](SECURITY.md) before sharing logs or screenshots.

Original project code and artwork: **[MIT](LICENSE), © 2026 Oliver**. Bundled third-party code, fonts, icons and tools retain their own licenses; see [Third-party notices](THIRD_PARTY_NOTICES.md) and [resource provenance](Resources/ASSETS.md). MIT permits commercial use.

One Cli is an independent project. Product names and logos identify compatible tools; they do not imply affiliation, sponsorship or endorsement by OpenAI, Anthropic, Moonshot AI, Cursor or Cloudflare.
