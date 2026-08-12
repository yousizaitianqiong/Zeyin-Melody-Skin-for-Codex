[CmdletBinding()]
param(
  [switch]$Preflight,
  [switch]$Install,
  [switch]$LaunchTray,
  [switch]$RestoreOfficial,
  [switch]$Uninstall,
  [switch]$Silent
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$payloadRoot = Join-Path $PSScriptRoot 'payload'
$payloadScripts = Join-Path $payloadRoot 'scripts'
$legacyPath = Join-Path $payloadScripts 'legacy-preflight.ps1'
$commonPath = Join-Path $payloadScripts 'common-windows.ps1'
$fixedThemePath = Join-Path $payloadScripts 'fixed-theme-windows.ps1'
$stateRoot = Join-Path $env:LOCALAPPDATA 'ZeyinMelodySkin'

function Show-ZeyinMelodyBootstrapMessage {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [ValidateSet('Info', 'Error')][string]$Kind = 'Info'
  )
  if ($Silent) { return }
  Add-Type -AssemblyName System.Windows.Forms
  $icon = if ($Kind -eq 'Error') {
    [System.Windows.Forms.MessageBoxIcon]::Error
  } else {
    [System.Windows.Forms.MessageBoxIcon]::Information
  }
  [void][System.Windows.Forms.MessageBox]::Show(
    $Message,
    'Zeyin Melody Skin for Codex',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    $icon
  )
}

function Assert-ZeyinMelodyBootstrapAction {
  $count = 0
  foreach ($selected in @($Preflight, $Install, $LaunchTray, $RestoreOfficial, $Uninstall)) {
    if ($selected) { $count++ }
  }
  if ($count -ne 1) { throw '安装器引导程序必须且只能选择一个操作。' }
}

function Assert-ZeyinMelodyBootstrapPayload {
  $required = @(
    'VERSION',
    'assets\background.jpg',
    'assets\renderer-inject.js',
    'assets\selectors.json',
    'assets\studio-theme.css',
    'assets\structure.css',
    'assets\theme.json',
    'assets\zeyin-melody.css',
    'assets\zeyin-melody-skin.ico',
    'scripts\check-update.ps1',
    'scripts\common-windows.ps1',
    'scripts\config-utf8.ps1',
    'scripts\fixed-theme-windows.ps1',
    'scripts\image-metadata.mjs',
    'scripts\injector.mjs',
    'scripts\install-zeyin-melody.ps1',
    'scripts\legacy-preflight.ps1',
    'scripts\restore-zeyin-melody.ps1',
    'scripts\start-zeyin-melody.ps1',
    'scripts\tray-zeyin-melody.ps1',
    'scripts\verify-zeyin-melody.ps1',
    'runtime\node\node.exe',
    'runtime\node\LICENSE'
  )
  foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $payloadRoot $relative) -PathType Leaf)) {
      throw "安装器负载不完整：$relative"
    }
  }
  $version = ([System.IO.File]::ReadAllText((Join-Path $payloadRoot 'VERSION'))).Trim()
  if ($version -cne '0.1.1') { throw "安装器负载版本无效：$version" }
}

function Wait-ZeyinMelodyCodexClosedForSetup {
  while ($true) {
    $registered = @(Get-ZeyinMelodySkinRegisteredCodexInstalls)
    $running = @($registered | Where-Object {
      (Get-ZeyinMelodySkinCodexProcesses -Codex $_).Count -gt 0
    })
    if ($running.Count -eq 0) { return }
    if ($Silent) { throw '安装或更新前必须关闭 Codex。' }
    Add-Type -AssemblyName System.Windows.Forms
    $choice = [System.Windows.Forms.MessageBox]::Show(
      'Codex 正在运行。请关闭 Codex，然后选择“重试”继续。',
      'Zeyin Melody Skin for Codex 安装程序',
      [System.Windows.Forms.MessageBoxButtons]::RetryCancel,
      [System.Windows.Forms.MessageBoxIcon]::Information
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Retry) {
      throw 'Codex 仍在运行，安装已取消。'
    }
  }
}

function Start-ZeyinMelodyTray {
  $engine = Get-ZeyinMelodySkinRuntimeEnginePaths -StateRoot $stateRoot
  if (-not (Test-Path -LiteralPath $engine.Tray -PathType Leaf)) {
    throw 'Zeyin Melody 托盘运行时缺失，请重新安装。'
  }
  if (Test-ZeyinMelodySkinTrayActive) { return }
  $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
  $arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File ' +
    (ConvertTo-ZeyinMelodySkinProcessArgument -Value $engine.Tray)
  Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

try {
  Assert-ZeyinMelodyBootstrapAction
  if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA 未定义，无法确定受管安装位置。' }

  if ($Preflight -or $Install) {
    if (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) {
      throw '安装器缺少旧版互斥预检。'
    }
    . $legacyPath
    # 此调用必须先于任何状态、配置、快捷方式或进程变化。
    Assert-ZeyinMelodySkinLegacyDreamSkinAbsent
    if ($Preflight) {
      $os = [Environment]::OSVersion.Version
      if (-not [Environment]::Is64BitOperatingSystem -or $os.Major -lt 10) {
        throw 'Zeyin Melody Skin for Codex 仅支持 Windows 10/11 x64。'
      }
      exit 0
    }
  }

  if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $fixedThemePath -PathType Leaf)) {
    throw '安装器缺少 Windows 安全核心。'
  }
  . $commonPath
  . $fixedThemePath

  if ($Install) {
    Assert-ZeyinMelodyBootstrapPayload
    Wait-ZeyinMelodyCodexClosedForSetup
    $engine = Get-ZeyinMelodySkinRuntimeEnginePaths -StateRoot $stateRoot
    Stop-ZeyinMelodySkinTrayProcess -ScriptPaths @($engine.Tray) -RequireStopped
    & (Join-Path $payloadScripts 'install-zeyin-melody.ps1') -NoShortcuts
    $engine = Get-ZeyinMelodySkinRuntimeEnginePaths -StateRoot $stateRoot
    $installedVersion = if (Test-Path -LiteralPath $engine.Version -PathType Leaf) {
      ([System.IO.File]::ReadAllText($engine.Version)).Trim()
    } else { '' }
    if ($installedVersion -cne '0.1.1') { throw '受管运行时未原子提交 0.1.1。' }
    $null = Assert-ZeyinMelodySkinFixedPayload -EngineRoot $engine.Root
    exit 0
  }

  if ($LaunchTray) {
    Start-ZeyinMelodyTray
    exit 0
  }

  $engine = Get-ZeyinMelodySkinRuntimeEnginePaths -StateRoot $stateRoot
  if ($RestoreOfficial) {
    if (-not (Test-Path -LiteralPath $engine.Restore -PathType Leaf)) {
      throw '恢复引擎缺失，请重新安装后再恢复官方外观。'
    }
    & $engine.Restore -RestoreBaseTheme -PromptRestart
    exit 0
  }

  if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $stateRoot)) { exit 0 }
    Stop-ZeyinMelodySkinTrayProcess -ScriptPaths @($engine.Tray) -RequireStopped
    if (-not (Test-Path -LiteralPath $engine.Restore -PathType Leaf)) {
      throw '恢复引擎缺失；已保留全部恢复材料并中止卸载。请重新安装同版本后重试。'
    }
    $restoreParameters = @{
      Uninstall = $true
      ForceRestart = $true
      NoRelaunch = $true
    }
    $configBackup = Join-Path $stateRoot 'config.before-zeyin-melody-skin.toml'
    if (Test-Path -LiteralPath $configBackup -PathType Leaf) {
      $restoreParameters.RestoreBaseTheme = $true
    }
    & $engine.Restore @restoreParameters
    if (Test-ZeyinMelodySkinTrayActive) {
      throw '托盘身份仍在运行；已保留恢复材料并中止卸载。'
    }
    if (Test-Path -LiteralPath (Join-Path $stateRoot 'state.json') -PathType Leaf) {
      throw '注入器状态未能安全清除；已保留恢复材料并中止卸载。'
    }
    # 只有恢复完整成功后，才允许删除整个新产品状态根目录。
    Remove-ZeyinMelodySkinStateRootVerified -StateRoot $stateRoot
    exit 0
  }
} catch {
  Show-ZeyinMelodyBootstrapMessage -Message $_.Exception.Message -Kind Error
  Write-Error $_
  exit 1
}
