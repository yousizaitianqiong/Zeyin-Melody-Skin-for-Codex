# Zeyin Melody Skin for Codex

面向 Windows 10/11 x64 的 Codex 固定主题客户端。当前版本为 `0.1.0`，尚未发布 GitHub Release。

本仓库具有全新、独立的 Git 历史，是 Windows-only、非 fork 项目。它不会修改 Codex 的 `app.asar`、签名、ACL 或受保护安装目录，而是连接经严格验证的本机 loopback CDP 会话。

> `codex/v0.1.0` 分支和 CI artifact 都是开发构建，不是正式 Release。请等待合并后的仓库 Release，不要从第三方下载站获取安装器。

## 产品边界

- 只提供固定的“泽音 Melody”主题，不提供 Gallery、多主题、背景更换、主题保存、ZIP 导入、社区 API 或自定义 URL protocol。
- 托盘仅提供启动、暂停/恢复、重新应用、验证、检查本仓库更新、恢复官方外观、完全卸载和退出。
- 状态根目录：`%LOCALAPPDATA%\ZeyinMelodySkin`。
- 程序安装目录：`%LOCALAPPDATA%\Programs\ZeyinMelodySkin`。
- 仅支持官方 `OpenAI.Codex` Microsoft Store 包和 Windows 10/11 x64。

## 安装与校验

正式发布后的安装器文件名为 `ZeyinMelodySkin-Setup-v0.1.0.exe`。项目暂未对安装器进行代码签名，因此 Microsoft Defender SmartScreen 可能显示“未知发布者”。不要关闭 SmartScreen；应确认下载地址属于本仓库 Release，并先核对 Release 同时公布的 SHA-256：

```powershell
Get-FileHash .\ZeyinMelodySkin-Setup-v0.1.0.exe -Algorithm SHA256
```

若检测到旧版 Codex Dream Skin 的 AppId、安装目录、受管 engine、配置备份或有效 live injector，安装会在写入新产品状态之前退出。请先在旧版执行 **Restore（恢复官方外观）**，再卸载旧版，最后重试。只有旧版 `themes`/`images` 普通目录残留时允许继续；安装器不会自动卸载旧版。

安装完成后，程序组和可选桌面快捷方式只包含：

- `Zeyin Melody Skin for Codex`
- `恢复 Codex 官方外观`

## 恢复与完全卸载

“恢复 Codex 官方外观”会关闭受管 CDP 会话、停止身份验证通过的注入器，并只恢复本产品管理的 Codex 配置键。完全卸载采用 fail-closed 顺序：先验证并停止新托盘/注入器，再恢复官方外观；任何一步失败都会中止卸载并保留恢复材料，全部成功后才删除整个 `%LOCALAPPDATA%\ZeyinMelodySkin`。

## 安全模型

- CDP HTTP/WebSocket 仅允许 `127.0.0.1`/`::1`，同时复核 Browser、page、监听进程与官方 Codex 包身份。
- 安装器捆绑固定 Node.js 22.23.1 win-x64；执行前验证 Authenticode 签名与受信发布者。
- 运行时引擎通过 staging、逐文件哈希、原子切换和失败回滚更新。
- `config.toml` 在变更前按原始字节备份，使用原子写入；失败恢复时保留诊断与恢复材料。
- 受管目录拒绝 junction、符号链接和状态根越界。

## 开发与验证

在 Windows PowerShell 5.1 中运行：

```powershell
.\tests\run-tests.ps1
.\installer\build-release.ps1
```

第二条命令会再次运行测试、下载并校验固定 Node.js 压缩包，再调用 Inno Setup 6，在 `dist\` 生成未签名开发安装器与可重解析的 `SHA256SUMS.txt`。CI 使用 `windows-2022` 执行相同回归与 Inno 构建，但只上传短期开发 artifact，不创建 Release。

固定 Studio 资源合同：

| 文件 | SHA-256 |
|---|---|
| `assets/background.jpg` | `0B8744ED2C02D1B7322B8D9E478EA674F5726EDDE617861E8C49D49533EDD388` |
| `assets/studio-theme.css` | `F9C23D29E8ACD1BE78E156E011F83AB84E0D90879B30B003E289A170BB77D409` |
| `assets/theme.json` | `D67B6BC4DAD83F3C971D401CD0CDB7B45B8B8E8A128AB6916E07C451131196D0` |

`studio-theme.css` 仅保存投稿原件身份，renderer 不会加载它；实际运行时使用通用 `structure.css` 与根属性完全限定的可信 `zeyin-melody.css`。

软件代码采用 MIT 许可证；固定美术资源采用 CC BY-NC 4.0。上游归属、第三方运行时与美术许可见 [NOTICE.md](NOTICE.md)，安全报告方式见 [SECURITY.md](SECURITY.md)，剩余发布工作见 [todo.md](todo.md)。
