# NOTICE

Zeyin Melody Skin for Codex 是非官方 Codex 外观定制项目，不隶属于、不代表 OpenAI，亦不受 OpenAI 官方背书。

## 软件许可与上游归属

仓库中的软件源代码使用 [MIT License](LICENSE)。Windows 注入、恢复、配置保护与安装安全核心基于 [Codex Dream Skin](https://github.com/Fei-Away/Codex-Dream-Skin) 的 MIT 许可代码（审阅基线 commit `9c5a47d`）进行独立产品化改造。

Copyright (c) 2026 Codex Dream Skin Studio contributors
Copyright (c) 2026 Zeyin Melody Skin for Codex contributors

上游 MIT 许可声明与免责声明已保留。本项目不复制上游 Git 历史，也不是上游仓库的 fork。

## 泽音 Melody 美术

以下固定 Studio 交付物由仓库维护者提供并授权，按 [Creative Commons Attribution-NonCommercial 4.0 International](https://creativecommons.org/licenses/by-nc/4.0/)（CC BY-NC 4.0）分发：

- `assets/background.jpg`
- `assets/studio-theme.css`
- `assets/theme.json`

署名：**Zeyin Melody Studio / 泽音 Melody**。允许在署名、非商业条件下共享和演绎；不得将这些美术资源用于商业用途。`assets/zeyin-melody.css` 中的软件实现与结构适配代码仍按 MIT 许可提供，但这不会扩大对背景图或 Studio 原始视觉作品的授权。

2026-08-11，用户已确认现有素材具备本项目公开使用与派生授权。最终 `background.jpg` 是在授权素材基础上完成的 AI-assisted outpainting（横向延展）作品；它不是 OpenAI 官方美术，也不表示 OpenAI 对作品或项目的认可。

## Node.js

Windows 安装器从 Node.js 官方固定地址取得 Node.js v22.23.1 win-x64 压缩包，并在解包前验证固定 SHA-256。安装包仅携带 `node.exe` 及其官方 `LICENSE`，后者保存在 `runtime\node\LICENSE`。

## Inno Setup 简体中文消息

Windows 安装器使用 Inno Setup。`installer/languages/ChineseSimplified.isl` 与 `installer/languages/Inno-Setup-License.txt` 保留其原始许可；构建会验证二者固定 SHA-256。

## 商标与应用边界

MIT 与 CC BY-NC 4.0 均不授予 OpenAI、Codex、ChatGPT 或任何第三方商标、徽标、官方应用二进制及 trade dress 的权利。本项目不会重新分发或修改官方 Codex 应用文件。
