# Security / 安全说明

One Cli runs real shells. A paired device with control can execute commands with the user’s permissions. HTTPS remote access uses Cloudflare; terminal content may contain credentials or other private data. See [Privacy](PRIVACY.md) for the data boundary.

Use the repository’s **Security → Advisories → Report a vulnerability** entry if the maintainer has enabled private vulnerability reporting. If that entry is unavailable, open a minimal issue requesting a private reporting channel, without exploit details, secrets, terminal output or pairing information. Do not publish sensitive details before a private channel is arranged. No response-time or support SLA is promised.

This project has not undergone an independent security audit. The current release is ad-hoc signed and not notarized. Compatibility and security fixes depend on maintainer availability and upstream CLI behavior.

One Cli 运行真实 Shell，取得控制权限的配对设备能够以用户权限执行命令。HTTPS 远程访问经过 Cloudflare；终端内容可能包含凭据或隐私信息。数据边界见[隐私说明](PRIVACY.md)。

如果维护者已启用 GitHub 私密漏洞报告，请使用 **Security → Advisories → Report a vulnerability**。入口不可用时，仅提交请求私密联系渠道的简短 Issue，不公开利用细节、密钥、终端内容或配对信息。建立私密渠道后再提供敏感详情；项目不承诺固定响应时间。

项目尚未经过独立安全审计；当前发行包使用 ad-hoc 签名且未公证。修复与兼容维护受维护者时间和上游 CLI 行为影响。
