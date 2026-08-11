# Zeyin Melody Skin for Codex 0.1.0

## 已完成

- [x] 建立 Windows-only、非 fork、独立 Git 历史与全新产品身份。
- [x] 集成 Studio 最终 `background.jpg`、`theme.json` 与原始 `studio-theme.css`，锁定 SHA-256。
- [x] 保留 Browser/page/进程身份、loopback-only、受信 Node、原子引擎更新、配置备份、失败回滚与完整恢复。
- [x] 分离通用 `structure.css` 与根属性完全限定的 `zeyin-melody.css` 可信视觉层。
- [x] 删除 Gallery、社区 API、URL protocol、ZIP 导入、多主题与背景更换入口。
- [x] 实现旧版互斥预检；仅普通 `themes`/`images` 残留允许继续。
- [x] 实现 fail-closed 完全卸载，成功后删除整个新状态根。
- [x] 添加身份/禁用扫描、CSS scope、26.803 renderer/cleanup、PS 5.1 BOM/解析、旧版预检、配置/引擎事务与拒绝路径回归。
- [x] 添加 Windows CI 与 Inno Setup 开发安装器构建。

## 发布前仍需

- [ ] 主任务完成代码与安装器安全审计。
- [ ] 在隔离的 Windows 10 x64 与 Windows 11 x64 环境执行首次安装、暂停/恢复、升级、旧版冲突和完整卸载实机验收。
- [ ] 确认恢复失败注入测试会保留全部恢复材料并阻止 Inno 删除程序文件。
- [ ] 审核最终安装器 SHA-256、SmartScreen 文案和 CC BY-NC 4.0 署名。
- [ ] 主任务审计、实机验收与 CI 通过后，按本次用户授权合并并发布 `v0.1.0`。

## 明确不做

- Gallery、社区 API、自定义 URL protocol 或通用 ZIP/主题导入。
- 多主题保存/切换、主题目录、图片库或背景更换。
- 在审计完成前合并开发 PR 或创建 Release。
