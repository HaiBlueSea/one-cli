# Contributing / 贡献说明

Focused issues and pull requests are welcome. Describe the problem, expected behavior and a minimal reproduction using fictional paths and accounts. For UI changes, include a sanitized screenshot and explain the interaction.

Build with `sh scripts/build.sh`; package with `sh scripts/package.sh`. Verify the affected behavior using an isolated development app. Keep changes focused, document compatibility limits and retain all applicable third-party notices. Contributions to original project files are offered under the project’s MIT license; third-party files retain their existing licenses. Only contribute material you have the right to share.

欢迎使用中文或英文提交问题和改进。请说明现象、预期结果和最小复现；路径、账号和输入使用虚构数据。界面修改可附脱敏截图并说明交互。

使用 `sh scripts/build.sh` 构建，使用 `sh scripts/package.sh` 打包。在独立开发版中验证受影响行为，保持改动聚焦并记录兼容边界。原创项目文件的贡献遵循 MIT；第三方文件保留原许可。请仅提交您有权公开的内容。

Language regression checks / 双语回归（browser check requires Python Playwright and Microsoft Edge）：

```sh
swift build
python3 scripts/check-native-language.py --bin-dir .build/debug --output-dir .tmp/language-checks/native
python3 scripts/check-remote-language.py --output .tmp/language-checks/remote.json
```

Never include credentials, pairing links or QR codes, cookies, real terminal transcripts, CLI session histories, local configuration, signing keys or private development records. / 不要提交密钥、配对链接和二维码、Cookie、真实终端内容、CLI 历史、本地配置、签名私钥或私有开发记录。
