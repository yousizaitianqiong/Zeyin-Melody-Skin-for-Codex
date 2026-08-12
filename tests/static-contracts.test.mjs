import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { assertScopedOverlay, loadPayload, loadTheme } from "../scripts/injector.mjs";
import { readImageMetadata } from "../scripts/image-metadata.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (relative) => fs.readFile(path.join(root, relative), "utf8");
const bytes = (relative) => fs.readFile(path.join(root, relative));
const hash = async (relative) => createHash("sha256").update(await bytes(relative)).digest("hex").toUpperCase();

const readIcoDirectory = (buffer) => {
  assert.equal(buffer.readUInt16LE(0), 0, "ICO 保留字段必须为 0");
  assert.equal(buffer.readUInt16LE(2), 1, "ICO 类型必须为图标");
  const count = buffer.readUInt16LE(4);
  const sizes = [];
  for (let index = 0; index < count; index += 1) {
    const offset = 6 + index * 16;
    const width = buffer[offset] || 256;
    const height = buffer[offset + 1] || 256;
    sizes.push(`${width}x${height}`);
  }
  return { count, sizes };
};

async function readTree(relativeRoots) {
  const entries = [];
  const visit = async (relative) => {
    for (const entry of await fs.readdir(path.join(root, relative), { withFileTypes: true })) {
      const child = path.join(relative, entry.name);
      if (entry.isDirectory()) await visit(child);
      else if (entry.isFile()) entries.push({ path: child, text: await read(child) });
    }
  };
  for (const relative of relativeRoots) await visit(relative);
  return entries;
}

test("Studio 三件套保持已验收字节、尺寸与固定身份", async () => {
  assert.equal(await hash("assets/background.jpg"), "0B8744ED2C02D1B7322B8D9E478EA674F5726EDDE617861E8C49D49533EDD388");
  assert.equal(await hash("assets/studio-theme.css"), "F9C23D29E8ACD1BE78E156E011F83AB84E0D90879B30B003E289A170BB77D409");
  assert.equal(await hash("assets/theme.json"), "D67B6BC4DAD83F3C971D401CD0CDB7B45B8B8E8A128AB6916E07C451131196D0");
  const image = readImageMetadata(await bytes("assets/background.jpg"), ".jpg");
  assert.deepEqual({ width: image.width, height: image.height }, { width: 2560, height: 1440 });
  const theme = JSON.parse(await read("assets/theme.json"));
  assert.equal(theme.id, "zeyin-melody");
  assert.equal(theme.name, "泽音 Melody");
  assert.equal(theme.image, "background.jpg");
  assert.equal(theme.promoUrl, "https://github.com/yousizaitianqiong/Zeyin-Melody-Skin-for-Codex");
  assert.equal(theme.appearance, "dark");
});

test("Studio 投稿 CSS 保持归档身份且不会作为运行 CSS 加载", async () => {
  const injector = await read("scripts/injector.mjs");
  assert.doesNotMatch(injector, /studio-theme\.css/);
  const loaded = await loadPayload();
  assert.equal(loaded.overlayStatus, "trusted-scoped");
  assert.match(loaded.payload, /html\[data-zeyin-melody-skin=\\?"active\\?"\]/);
  assert.doesNotMatch(loaded.payload, /__ZEYIN_MELODY_SKIN_(?:CSS|ART|THEME|VERSION)_JSON__/);
  await assert.rejects(loadTheme(root), /only accepts its bundled fixed theme directory/);
});

test("可信覆盖层每条 selector 都以产品根属性开头", async () => {
  const overlay = await read("assets/zeyin-melody.css");
  assert.equal(assertScopedOverlay(overlay), overlay);
  for (const part of ["root", "sidebar", "header", "project-list", "message", "composer", "dialog"]) {
    assert.match(overlay, new RegExp(`html\\[data-zeyin-melody-skin="active"\\][^\\{]*\\[data-ds-part="${part}"\\]`));
  }
  assert.throws(
    () => assertScopedOverlay("body { color: red; }"),
    /selector is not rooted/,
  );
  assert.throws(
    () => assertScopedOverlay('html[data-zeyin-melody-skin="active"] { background: url("https://example.test/x.png"); }'),
    /cannot load external content/,
  );
  const externalStyleSvg = "<svg xmlns='http://www.w3.org/2000/svg'><style>@import '//host.invalid/x.css';</style></svg>";
  const externalStyleCss = 'html[data-zeyin-melody-skin="active"] { --icon: url("data:image/svg+xml,' +
    encodeURIComponent(externalStyleSvg) + '"); }';
  assert.throws(() => assertScopedOverlay(externalStyleCss), /inline SVG is not self-contained/);

  const menuRule = overlay.match(
    /html\[data-zeyin-melody-skin="active"\]\s*\[role="menubar"\]\s*>\s*button\[role="menuitem"\]\[id\^="application-menu-trigger-"\]\s*\{([\s\S]*?)\}/,
  )?.[1] ?? "";
  assert.match(menuRule, /color:\s*rgb\(var\(--ds-text-rgb\) \/ \.90\) !important;/,
    "Windows 顶部菜单常态文字必须保持高对比度。");
  assert.match(menuRule, /font-weight:\s*500 !important;/,
    "Windows 顶部菜单必须保持可读字重。");
  assert.match(menuRule, /text-shadow:\s*0 1px 2px rgb\(var\(--ds-bg-rgb\) \/ \.88\);/,
    "Windows 顶部菜单必须带轻微暗色文字阴影。");
  assert.match(
    overlay,
    /button\[role="menuitem"\]\[id\^="application-menu-trigger-"\]:is\(:hover, :focus-visible, \[aria-expanded="true"\]\)[\s\S]*?color:\s*var\(--ds-text\) !important;/,
    "Windows 顶部菜单交互态必须使用完整主题文字色。",
  );
  assert.doesNotMatch(overlay, /_ApplicationMenuTopBar_/,
    "可信覆盖层不得依赖易变的顶部菜单 CSS Module 类名。");
});

test("通用结构层不携带泽音文案、图标或固定粉紫视觉", async () => {
  const [structure, overlay, themeText] = await Promise.all([
    read("assets/structure.css"), read("assets/zeyin-melody.css"), read("assets/theme.json"),
  ]);
  const theme = JSON.parse(themeText);
  const forbiddenStructure = [
    theme.brandSubtitle, theme.tagline, theme.quote, theme.projectLabel, theme.statusText,
    "data:image/svg+xml", "--zeyin-melody-skin-name", "--zeyin-melody-skin-brand-subtitle",
    "--zeyin-melody-skin-status", "--zeyin-melody-skin-tagline", "--zeyin-melody-skin-quote",
    "--zeyin-melody-skin-project-prefix", "--zeyin-melody-skin-project-label",
    "--zeyin-melody-skin-project-icon", "--ds-purple",
    ...Object.values(theme.colors).filter((value) => typeof value === "string"),
  ];
  for (const value of forbiddenStructure) assert.ok(!structure.includes(value), `结构层泄漏固定视觉：${value}`);
  for (const value of [
    theme.brandSubtitle, theme.quote, theme.projectLabel, theme.statusText,
    "--zeyin-melody-skin-project-icon", "data:image/svg+xml", theme.colors.accent,
  ]) {
    assert.ok(overlay.includes(value), `可信覆盖层缺少固定视觉：${value}`);
  }
});

test("独立 Windows 安装器身份与快捷方式精确锁定", async () => {
  const [iss, common, fixed, install, restore, icon] = await Promise.all([
    read("installer/zeyin-melody-skin.iss"),
    read("scripts/common-windows.ps1"),
    read("scripts/fixed-theme-windows.ps1"),
    read("scripts/install-zeyin-melody.ps1"),
    read("scripts/restore-zeyin-melody.ps1"),
    bytes("assets/zeyin-melody-skin.ico"),
  ]);
  for (const contract of [
    "AppId={{9FA2CB1B-2212-4661-8F9F-F94FA81F2A14}",
    "DefaultDirName={localappdata}\\Programs\\ZeyinMelodySkin",
    "SetupMutex=Local\\ZeyinMelodySkin.Setup",
    "AppMutex=Local\\ZeyinMelodySkin.Tray",
    "ChangesAssociations=no",
    "ArchitecturesAllowed=x64compatible",
    "MinVersion=10.0",
    "OutputBaseFilename=ZeyinMelodySkin-Setup-v{#AppVersion}",
    "SetupIconFile={#StageRoot}\\payload\\assets\\zeyin-melody-skin.ico",
  ]) assert.ok(iss.includes(contract), `安装器身份缺少：${contract}`);
  assert.match(common, /Local\\ZeyinMelodySkin\.Operation/);
  assert.match(common, /Local\\ZeyinMelodySkin\.Tray/);
  assert.match(fixed, /Join-Path \$env:LOCALAPPDATA 'ZeyinMelodySkin'/);
  const urls = iss.split(/\r?\n/).filter((line) => /^App(?:Publisher|Support|Updates)URL=/.test(line));
  assert.deepEqual(urls, [
    "AppPublisherURL={#RepositoryUrl}",
    "AppSupportURL={#RepositoryUrl}",
    "AppUpdatesURL={#ReleasesUrl}",
  ]);
  assert.match(iss, /#define RepositoryUrl "https:\/\/github\.com\/yousizaitianqiong\/Zeyin-Melody-Skin-for-Codex"/);
  assert.match(iss, /#define ReleasesUrl "https:\/\/github\.com\/yousizaitianqiong\/Zeyin-Melody-Skin-for-Codex\/releases"/);
  assert.doesNotMatch(iss, /\[Registry\]|Dream Skin|keep saved themes|保留.*主题|ChangesAssociations=yes/iu);
  assert.equal((iss.match(/Name: "\{group\}\\Zeyin Melody Skin for Codex"/g) || []).length, 1);
  assert.equal((iss.match(/Name: "\{userdesktop\}\\Zeyin Melody Skin for Codex"/g) || []).length, 1);
  assert.equal((iss.match(/Name: "\{(?:group|userdesktop)\}\\恢复 Codex 官方外观"/g) || []).length, 2);
  assert.doesNotMatch(iss, /启动 Zeyin Melody|Zeyin Melody 托盘/);
  assert.equal((install.match(/Join-Path \$folder 'Zeyin Melody Skin for Codex\.lnk'/g) || []).length, 1);
  assert.equal((install.match(/Join-Path \$folder '恢复 Codex 官方外观\.lnk'/g) || []).length, 1);
  assert.doesNotMatch(install + restore, /Zeyin Melody Skin for Codex - (?:托盘|恢复官方外观)\.lnk/);
  const operationRelease = install.lastIndexOf("Exit-ZeyinMelodySkinOperationLock -Mutex $operationLock");
  const trayLaunch = install.lastIndexOf("Start-Process -FilePath $trayLaunch.FilePath");
  assert.ok(operationRelease >= 0 && trayLaunch > operationRelease,
    "源码安装必须先释放操作互斥，再启动会自行验证负载的托盘。");
  assert.deepEqual([...icon.subarray(0, 4)], [0, 0, 1, 0]);
  assert.equal(await hash("assets/zeyin-melody-skin.ico"), "9B567178831161A6B2C6E80F68568FE5BE8AB493EEA1D90CF3647D573699FFC4");
  assert.deepEqual(readIcoDirectory(icon), {
    count: 7,
    sizes: ["16x16", "20x20", "24x24", "32x32", "48x48", "64x64", "128x128"],
  });
});

test("固定主题产品不存在协议、社区导入或多主题入口", async () => {
  const tree = await readTree(["installer", "scripts"]);
  const combined = tree.map((entry) => `${entry.path}\n${entry.text}`).join("\n");
  for (const forbidden of [
    /apply-community-theme/iu,
    /URL Protocol/iu,
    /Software\\Classes\\zeyinmelody/iu,
    /(?:dreamskin|zeyinmelody):\/\//iu,
    /zeyinmelody\.cc/iu,
    /Fei-Away\/Codex-Dream-Skin\/releases/iu,
    /theme-package-validator/iu,
    /active-theme/iu,
    /Gallery/iu,
    /Import-[A-Za-z0-9]*Theme/iu,
    /(?:theme[^\r\n]{0,40}zip|zip[^\r\n]{0,40}theme)[^\r\n]{0,80}(?:import|导入)/iu,
  ]) assert.doesNotMatch(combined, forbidden);
  for (const entry of tree.filter((item) => !item.path.endsWith("legacy-preflight.ps1"))) {
    assert.doesNotMatch(entry.text, /['"](?:themes|images)[\\/]|['"]active-theme['"]/iu, entry.path);
  }
  const tray = await read("scripts/tray-zeyin-melody.ps1");
  const labels = [...tray.matchAll(/-Text '([^']+)'/g)].map((match) => match[1]);
  assert.deepEqual(labels, [
    "启动 Codex（应用主题）", "恢复显示主题", "暂停主题", "重新应用主题",
    "验证当前会话", "检查更新…", "恢复官方外观", "完全卸载…", "退出托盘",
  ]);
  assert.doesNotMatch(tray, /更换背景|保存主题|已保存主题|导入|Gallery/iu);
  assert.match(
    tray,
    /\[Parameter\(Mandatory = \$true\)\]\[AllowEmptyCollection\(\)\]\s*\[System\.Windows\.Forms\.ToolStripItemCollection\]\$Items/,
    "首次打开托盘菜单时必须允许传入空菜单项集合。",
  );
  assert.match(
    tray,
    /\$menu\.add_Opening\(\{[\s\S]*?param\(\$sender, \$eventArgs\)[\s\S]*?try\s*\{[\s\S]*?Rebuild-ZeyinMelodySkinTrayMenu[\s\S]*?\}\s*catch\s*\{[\s\S]*?\$eventArgs\.Cancel = \$true[\s\S]*?Show-ZeyinMelodySkinTrayError/,
    "托盘 Opening 事件必须拦截重建异常，避免 JIT 对话框。",
  );
  const updater = await read("scripts/check-update.ps1");
  assert.match(updater, /yousizaitianqiong\/Zeyin-Melody-Skin-for-Codex/);
  assert.doesNotMatch(updater, /Fei-Away|zeyinmelody\.cc/iu);
});

test("renderer 命名空间、26.803 semantic bridge 与 cleanup 保持完整", async () => {
  const renderer = await read("assets/renderer-inject.js");
  for (const required of [
    'const CONFIG_KEY = "__ZEYIN_MELODY_SKIN_CONFIG__"',
    "window[CONFIG_KEY] = Object.freeze", "window.__ZEYIN_MELODY_SKIN_CONFIG__.theme",
    '"data-zeyin-melody-skin"', 'setAttribute(root, "data-zeyin-melody-skin", "active")',
    "[data-codex-composer-root] [data-composer-surface-variant]",
    "[data-codex-composer-root] [data-composer-footer-responsive]",
    'addPart(desired, "composer", resolvedComposerNodes())',
    'addPart(desired, "composer-toolbar", resolvedComposerToolbarNodes())',
    "for (const name of ROOT_ATTRS) root?.removeAttribute(name)",
    "delete window[STATE_KEY]", "delete window[CONFIG_KEY]",
  ]) assert.ok(renderer.includes(required), `renderer 合同缺少：${required}`);
  assert.doesNotMatch(renderer, /__CODEX_DREAM_SKIN|data-dream-skin|dreamskin/iu);
});

test("Windows 安全核心保持 loopback、身份验证、签名 Node 与原子事务", async () => {
  const [common, config, install, start, restore, bootstrap, definition, builder, workflow] = await Promise.all([
    read("scripts/common-windows.ps1"), read("scripts/config-utf8.ps1"),
    read("scripts/install-zeyin-melody.ps1"), read("scripts/start-zeyin-melody.ps1"),
    read("scripts/restore-zeyin-melody.ps1"), read("installer/setup-bootstrap.ps1"),
    read("installer/zeyin-melody-skin.iss"), read("installer/build-release.ps1"),
    read(".github/workflows/windows.yml"),
  ]);
  for (const required of [
    "http://127.0.0.1:$Port/json/list", "http://127.0.0.1:$Port/json/version",
    "LocalAddress -notin @('127.0.0.1', '::1')", "Get-AuthenticodeSignature",
    "OpenJS Foundation|Node\\.js Foundation|Microsoft Corporation|GitHub, Inc\\.",
    ".engine-staging-$token", ".engine-backup-$token", "Get-FileHash",
    "Test-ZeyinMelodySkinCodexPortOwner", "Get-ZeyinMelodySkinCdpBrowserIdentity",
  ]) assert.ok(common.includes(required), `安全核心缺少：${required}`);
  for (const required of [
    "Write-ZeyinMelodySkinUtf8FileAtomically", "Write-ZeyinMelodySkinBytesAtomically",
    "Assert-ZeyinMelodySkinFileUnchanged", "config.before-zeyin-melody-skin.toml",
  ]) assert.ok((config + install + restore).includes(required), `配置事务缺少：${required}`);
  assert.ok(start.indexOf("Assert-ZeyinMelodySkinNoLegacyLiveInjector") < start.indexOf("Enter-ZeyinMelodySkinOperationLock"));
  assert.ok(install.indexOf("Assert-ZeyinMelodySkinLegacyDreamSkinAbsent") < install.indexOf("Enter-ZeyinMelodySkinOperationLock"));
  assert.match(definition, /function PrepareToInstall\([\s\S]*'-Preflight'/);
  const restoreCall = bootstrap.indexOf("& $engine.Restore @restoreParameters");
  const stateDelete = bootstrap.indexOf("Remove-ZeyinMelodySkinStateRootVerified -StateRoot $stateRoot");
  assert.ok(restoreCall >= 0 && stateDelete > restoreCall, "完整卸载必须先恢复、后删除状态根。" );
  assert.match(bootstrap.slice(restoreCall, stateDelete), /状态未能安全清除|托盘身份仍在运行/);
  assert.match(bootstrap, /恢复引擎缺失；已保留全部恢复材料并中止卸载/);
  for (const required of [
    "function Write-ZeyinMelodyChecksumAtomically", "SHA256SUMS.txt",
    "[System.IO.File]::Replace", "[System.IO.File]::Move",
    "[System.IO.File]::ReadAllBytes($checksumPath)",
    "[regex]::Escape($version)",
    "Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256",
  ]) assert.ok(builder.includes(required), `发布校验清单缺少：${required}`);
  for (const required of [
    "function Receive-ZeyinMelodyPinnedArchive", "--connect-timeout", "--max-time",
    "--proto-redir", "--tls-max", "-TimeoutSec 300", ".download-",
    "拒绝缓存或复用零字节文件", "[System.IO.File]::Delete($temporary)",
    "System32\\curl.exe", "Get-AuthenticodeSignature -LiteralPath $systemCurl",
    "Microsoft Corporation",
  ]) assert.ok(builder.includes(required), `固定运行时下载保护缺少：${required}`);
  assert.match(workflow, /dist\/SHA256SUMS\.txt/);
  assert.match(workflow, /Get-Item -LiteralPath \$compiler/);
  assert.doesNotMatch(workflow, /& \$compiler '\/\?'/);
});
