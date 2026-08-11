[CmdletBinding()]
param(
  [int]$Port = 9335,
  [switch]$NoShortcuts
)

$ErrorActionPreference = 'Stop'
$PortExplicit = $PSBoundParameters.ContainsKey('Port')
$ProductRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'legacy-preflight.ps1')

# 旧版命中必须在新状态目录、配置、快捷方式或进程发生任何变化前退出。
Assert-ZeyinMelodySkinLegacyDreamSkinAbsent

. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'fixed-theme-windows.ps1')

$trayLaunch = $null
$operationLock = Enter-ZeyinMelodySkinOperationLock
try {
  $os = [Environment]::OSVersion.Version
  if (-not [Environment]::Is64BitOperatingSystem -or $os.Major -lt 10) {
    throw 'Zeyin Melody Skin for Codex 仅支持 Windows 10/11 x64。'
  }
  Assert-ZeyinMelodySkinPort -Port $Port
  $null = Get-ZeyinMelodySkinNodeRuntime
  $registeredInstalls = @(Get-ZeyinMelodySkinRegisteredCodexInstalls)
  if ($registeredInstalls.Count -eq 0) {
    throw '未找到或无法验证官方 OpenAI.Codex Microsoft Store 包。'
  }
  foreach ($registeredCodex in $registeredInstalls) {
    if ((Get-ZeyinMelodySkinCodexProcesses -Codex $registeredCodex).Count -gt 0) {
      throw '安装前请关闭 Codex，避免事务过程中 config.toml 被并发修改。'
    }
  }

  $StateRoot = Join-Path $env:LOCALAPPDATA 'ZeyinMelodySkin'
  Ensure-ZeyinMelodySkinManagedDirectory -Path $StateRoot -Root $StateRoot
  $StatePath = Join-Path $StateRoot 'state.json'
  $existingState = Read-ZeyinMelodySkinState -Path $StatePath
  $savedPathCandidate = Get-ZeyinMelodySkinCodexStatePathCandidate -State $existingState
  $savedCodex = Resolve-ZeyinMelodySkinCodexInstallFromState `
    -State $existingState -RegisteredInstalls $registeredInstalls
  if ($null -ne $savedPathCandidate -and $null -eq $savedCodex -and
    (Get-ZeyinMelodySkinCodexProcesses -Codex $savedPathCandidate).Count -gt 0) {
    throw '保存的 Codex 路径仍在运行，但已不再匹配已注册的 Store 包；请先手动关闭。'
  }
  if (Test-ZeyinMelodySkinTrayActive) {
    throw '重新安装前请退出 Zeyin Melody 托盘，以便原子更新全部运行时。'
  }

  $engine = Install-ZeyinMelodySkinRuntimeEngine -SkillRoot $ProductRoot -StateRoot $StateRoot
  $payload = Assert-ZeyinMelodySkinFixedPayload -EngineRoot $engine.Root
  $profileRoot = [Environment]::GetFolderPath('UserProfile')
  $ConfigPath = Join-Path $profileRoot '.codex\config.toml'
  $BackupPath = Join-Path $StateRoot 'config.before-zeyin-melody-skin.toml'
  Install-ZeyinMelodySkinBaseTheme -ConfigPath $ConfigPath -BackupPath $BackupPath `
    -AppearanceTheme "$($payload.Theme.appearance)"

  if (-not $NoShortcuts) {
    $shell = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $portArgument = if ($PortExplicit) { " -Port $Port" } else { '' }
    $iconPath = Join-Path $engine.Root 'assets\zeyin-melody-skin.ico'

    foreach ($folder in @($desktop, $startMenu)) {
      $shortcut = $shell.CreateShortcut((Join-Path $folder 'Zeyin Melody Skin for Codex.lnk'))
      $shortcut.TargetPath = $powershell
      $shortcut.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$($engine.Tray)`"$portArgument"
      $shortcut.WorkingDirectory = $engine.Root
      $shortcut.Description = '打开 Zeyin Melody Skin for Codex'
      if (Test-Path -LiteralPath $iconPath) { $shortcut.IconLocation = $iconPath }
      $shortcut.Save()

      $restore = $shell.CreateShortcut((Join-Path $folder '恢复 Codex 官方外观.lnk'))
      $restore.TargetPath = $powershell
      $restore.Arguments = "-NoProfile -ExecutionPolicy RemoteSigned -File `"$($engine.Restore)`"$portArgument -RestoreBaseTheme -PromptRestart"
      $restore.WorkingDirectory = $engine.Root
      $restore.Description = '恢复 Codex 官方外观并关闭受管 CDP 会话'
      if (Test-Path -LiteralPath $iconPath) { $restore.IconLocation = $iconPath }
      $restore.Save()
    }
    $trayLaunch = [pscustomobject]@{
      FilePath = $powershell
      ArgumentList = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$($engine.Tray)`"$portArgument"
    }
  }

  if ($NoShortcuts) {
    Write-Host "Zeyin Melody 运行时已安装到 $($engine.Root)。"
  } else {
    Write-Host 'Zeyin Melody Skin for Codex 已安装。启动快捷方式会在需要重启 Codex 时先征得确认。'
  }
} finally {
  Exit-ZeyinMelodySkinOperationLock -Mutex $operationLock
}

# 托盘会在相同的操作互斥下验证负载；必须等安装释放互斥后再启动，
# 否则较快的机器可能让托盘首次初始化失败并直接退出。
if ($null -ne $trayLaunch) {
  Start-Process -FilePath $trayLaunch.FilePath -ArgumentList $trayLaunch.ArgumentList `
    -WindowStyle Hidden | Out-Null
}
