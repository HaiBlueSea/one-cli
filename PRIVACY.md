# Privacy & local data / 隐私与本地数据

## On your Mac

One Cli saves layout, working directories and appearance in `~/Library/Application Support/AITerminal/`; development builds use `AITerminalDev/`. Integration files, helpers, sockets and diagnostic records may also be created in the app’s support directories. Terminal content exists in memory during use. Layout restore starts new shells and never replays tasks or input.

The app uses locally installed CLIs and their own authentication. Agent integration may read configuration and session metadata, add observation hooks, and create app-managed integration directories. CLI-side sessions, credentials and network traffic remain subject to each CLI’s behavior and provider policies. Hook payload filtering does not make arbitrary terminal output safe to publish.

## When remote access is enabled

The bundled `cloudflared` opens an outbound tunnel through Cloudflare to a loopback HTTP helper. Cloudflare terminates the public HTTPS connection; no additional end-to-end encryption layer excludes the provider. Authorized browsers receive session names, directories and terminal output; control grants the ability to send input.

Pairing requires confirmation on the Mac. The browser stores an HttpOnly authorization cookie with a lifetime of up to seven days for the same endpoint. Turning remote access off or revoking authorization invalidates access. Treat QR codes, pairing URLs and browser cookies as sensitive credentials. Closing the remote panel alone does not turn remote access off.

The app has no project-operated analytics backend. This is not a claim that the CLIs or Cloudflare collect no data. Do not share real account files, layouts, terminal transcripts, QR codes or local diagnostic records in public reports.

## 本地数据

One Cli 在 `~/Library/Application Support/AITerminal/` 保存目录、布局和外观；开发版使用 `AITerminalDev/`。应用支持目录还可能包含接入文件、helper、socket 和诊断记录。终端运行时在内存中保留内容；恢复布局只创建新 Shell，不重放任务或输入。

应用使用本机 CLI 及其登录。Agent 接入可能读取配置和会话元数据、追加观察 Hook、创建应用管理的接入目录。CLI 自身的会话、凭据和联网行为仍受各工具及服务商规则影响；Hook 过滤不代表真实终端输出可以公开。

## 远程访问

主动开启远程后，内置 `cloudflared` 通过 Cloudflare 将外部请求接到本机回环 HTTP helper。公网 HTTPS 由 Cloudflare 终止，没有另加一层排除服务商的端到端加密。授权浏览器可接收会话名称、目录和终端内容；获得控制后可以发送输入。

配对需要 Mac 确认。浏览器通过 HttpOnly Cookie 保存同一入口最长 7 天的授权；关闭远程或撤销授权会使其失效。二维码、配对链接和 Cookie 都应视为敏感凭据。只关闭远程面板不会关闭远程访问。

项目没有自营的使用统计后端；这不代表 CLI 或 Cloudflare 不收集数据。公开反馈不要附真实账号文件、布局、终端内容、二维码或诊断原件。
