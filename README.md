# Zeyin Melody Skin for Codex

面向 Windows 10/11 x64 的 Codex 固定主题客户端。项目当前版本为 `0.1.0`，尚未发布 Release。

本仓库采用全新、独立的 Git 历史，不是 Codex Dream Skin 的 fork。软件代码使用 MIT 许可证；美术资源使用 CC BY-NC 4.0，详见 [NOTICE.md](NOTICE.md)。

> 当前处于开发阶段。请勿把分支构建或占位资源视为发布候选。

## 安全原则

- 只连接本机 loopback CDP，并验证 Browser、page 与进程身份。
- 不修改 Codex 的 `app.asar`、签名、ACL 或受保护安装目录。
- 配置变更先备份、原子写入，失败时回滚；恢复失败时保留恢复材料。
- Node.js 必须来自受信来源，安装后的引擎按清单哈希验证并原子更新。
- 与旧版 Codex Dream Skin 的活动注入器和安装状态互斥，不自动卸载旧版。

## 发布状态

计划中的正式安装器文件名为 `ZeyinMelodySkin-Setup-v0.1.0.exe`。正式 Release 将同时提供 SHA-256 摘要；未签名安装器可能触发 Microsoft Defender SmartScreen，用户不应关闭 SmartScreen，而应从本仓库 Release 下载并核对摘要。

开发进度见 [todo.md](todo.md)，安全报告方式见 [SECURITY.md](SECURITY.md)。
