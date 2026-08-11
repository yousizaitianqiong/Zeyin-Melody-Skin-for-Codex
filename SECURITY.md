# 安全政策

## 支持范围

项目尚未发布。`0.1.x` 开发期间只接受针对最新 `main` 与开放 PR 的安全报告。

## 报告漏洞

请不要公开披露可被利用的细节。使用 GitHub 仓库的 **Security → Report a vulnerability** 私密报告入口，并提供：

- 受影响版本或提交；
- Windows 与 Codex 版本/安装来源；
- 最小复现步骤和预期影响；
- 已脱敏的日志或概念验证。

请勿提交令牌、`auth.json`、私人对话、用户目录快照或其他敏感数据。

## 安全边界

本项目只支持 Windows 10/11 x64；拒绝非 loopback CDP、未经身份验证的进程、非受信 Node.js、重定向的受管路径以及不完整恢复。项目不会要求关闭 Defender、SmartScreen 或企业策略。
