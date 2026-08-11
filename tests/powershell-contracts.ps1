[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repositoryRoot = Split-Path -Parent $PSScriptRoot

function Assert-ZeyinTest {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { throw $Message }
}

function Assert-ZeyinThrows {
  param([Parameter(Mandatory = $true)][scriptblock]$Action, [Parameter(Mandatory = $true)][string]$Pattern)
  $caught = $null
  try { & $Action } catch { $caught = $_ }
  if ($null -eq $caught -or $caught.Exception.Message -notmatch $Pattern) {
    throw "预期异常未出现或消息不匹配：$Pattern"
  }
}

# Windows PowerShell 5.1 会把无 BOM UTF-8 当作系统 ANSI；此合同同时锁定字节和 ParseFile。
$distributedPowerShell = @(
  Get-ChildItem -LiteralPath @(
    (Join-Path $repositoryRoot 'scripts'),
    (Join-Path $repositoryRoot 'installer'),
    (Join-Path $repositoryRoot 'tests')
  ) -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') }
)
foreach ($file in $distributedPowerShell) {
  $content = [System.IO.File]::ReadAllBytes($file.FullName)
  Assert-ZeyinTest -Condition ($content.Length -ge 3 -and $content[0] -eq 0xEF -and
    $content[1] -eq 0xBB -and $content[2] -eq 0xBF) -Message "PowerShell 文件缺少 UTF-8 BOM：$($file.FullName)"
  $tokens = $null
  $parseErrors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile(
    $file.FullName, [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors.Count -gt 0) {
    throw "Windows PowerShell 5.1 解析失败：$($file.FullName)：$($parseErrors[0].Message)"
  }
}

. (Join-Path $repositoryRoot 'scripts\legacy-preflight.ps1')
. (Join-Path $repositoryRoot 'scripts\config-utf8.ps1')
. (Join-Path $repositoryRoot 'scripts\fixed-theme-windows.ps1')
. (Join-Path $repositoryRoot 'scripts\common-windows.ps1')

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'zeyin-melody-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
$fixtureProcess = $null
$originalLocalAppData = $env:LOCALAPPDATA
try {
  # 旧版状态根仅含普通 themes/images 目录时必须允许；其他运行状态必须拒绝。
  $legacyRoot = Join-Path $temporaryRoot 'legacy-state'
  $missingInstallRoot = Join-Path $temporaryRoot 'missing-old-install'
  New-Item -ItemType Directory -Path (Join-Path $legacyRoot 'themes') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $legacyRoot 'images') -Force | Out-Null
  $conflicts = @(Get-ZeyinMelodySkinLegacyConflicts -OldStateRoot $legacyRoot `
    -OldInstallRoot $missingInstallRoot -SkipRegistry)
  Assert-ZeyinTest -Condition ($conflicts.Count -eq 0) `
    -Message '仅 themes/images 的旧版残留被错误拒绝。'
  $legacyEngine = Join-Path $legacyRoot 'engine'
  New-Item -ItemType Directory -Path $legacyEngine | Out-Null
  $conflicts = @(Get-ZeyinMelodySkinLegacyConflicts -OldStateRoot $legacyRoot `
    -OldInstallRoot $missingInstallRoot -SkipRegistry)
  Assert-ZeyinTest -Condition ($conflicts -contains '旧版受管 engine') `
    -Message '旧版 engine 未触发互斥。'
  [System.IO.Directory]::Delete($legacyEngine)
  [System.IO.File]::WriteAllText((Join-Path $legacyRoot 'state.json'), '{}', [System.Text.UTF8Encoding]::new($false))
  $conflicts = @(Get-ZeyinMelodySkinLegacyConflicts -OldStateRoot $legacyRoot `
    -OldInstallRoot $missingInstallRoot -SkipRegistry)
  Assert-ZeyinTest -Condition (($conflicts -join '|') -match '旧版运行状态残留') `
    -Message '旧版运行状态残留未触发互斥。'
  [System.IO.File]::Delete((Join-Path $legacyRoot 'state.json'))

  # 用真实 Node 进程验证旧 live injector 命中与新产品记录进程的 fail-closed 身份检查。
  $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $nodeCommand) { $nodeCommand = Get-Command node -ErrorAction Stop }
  $nodePath = [System.IO.Path]::GetFullPath($nodeCommand.Source)
  $fixtureScript = Join-Path $temporaryRoot 'recorded-injector-fixture.mjs'
  [System.IO.File]::WriteAllText(
    $fixtureScript,
    "setInterval(() => {}, 600000);`n",
    [System.Text.UTF8Encoding]::new($false)
  )
  $fixtureArguments = (ConvertTo-ZeyinMelodySkinProcessArgument -Value $fixtureScript) +
    ' --watch --port 49333 --browser-id fixture-browser'
  $fixtureProcess = Start-Process -FilePath $nodePath -ArgumentList $fixtureArguments `
    -WindowStyle Hidden -PassThru
  $deadline = (Get-Date).AddSeconds(5)
  do {
    Start-Sleep -Milliseconds 100
    $fixtureProcess.Refresh()
    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($fixtureProcess.Id)" `
      -ErrorAction SilentlyContinue
  } while (-not $fixtureProcess.HasExited -and (-not $processInfo -or -not $processInfo.CommandLine) -and
    (Get-Date) -lt $deadline)
  Assert-ZeyinTest -Condition (-not $fixtureProcess.HasExited -and $null -ne $processInfo) `
    -Message '记录进程夹具未能启动。'
  $startedAt = $fixtureProcess.StartTime.ToUniversalTime().ToString('o')
  $legacyState = [ordered]@{
    injectorPid = $fixtureProcess.Id
    injectorStartedAt = $startedAt
    injectorPath = $fixtureScript
    nodePath = $nodePath
  } | ConvertTo-Json
  [System.IO.File]::WriteAllText(
    (Join-Path $legacyRoot 'state.json'), $legacyState, [System.Text.UTF8Encoding]::new($false))
  Assert-ZeyinTest -Condition (Test-ZeyinMelodySkinLegacyLiveInjector -OldStateRoot $legacyRoot) `
    -Message '有效旧版 live injector 未被识别。'

  $recordedState = [pscustomobject]@{
    injectorPid = $fixtureProcess.Id
    injectorStartedAt = '2000-01-01T00:00:00.0000000Z'
    injectorPath = $fixtureScript
    nodePath = $nodePath
    port = 49333
    browserId = 'fixture-browser'
  }
  Assert-ZeyinThrows -Pattern 'State was preserved' -Action {
    $null = Stop-ZeyinMelodySkinRecordedInjector -State $recordedState
  }
  $fixtureProcess.Refresh()
  Assert-ZeyinTest -Condition (-not $fixtureProcess.HasExited) `
    -Message '身份不匹配时错误停止了进程。'
  $recordedState.injectorStartedAt = $startedAt
  Assert-ZeyinTest -Condition (Stop-ZeyinMelodySkinRecordedInjector -State $recordedState) `
    -Message '身份验证通过的记录注入器未停止。'
  $fixtureProcess.Refresh()
  Assert-ZeyinTest -Condition $fixtureProcess.HasExited -Message '记录注入器停止后仍在运行。'

  # 配置备份必须保留原始字节；完整恢复入口能原子恢复全部配置。
  $configRoot = Join-Path $temporaryRoot 'config'
  New-Item -ItemType Directory -Path $configRoot | Out-Null
  $configPath = Join-Path $configRoot 'config.toml'
  $backupPath = Join-Path $configRoot 'config.before-zeyin-melody-skin.toml'
  $recoveryPath = Join-Path $configRoot 'config.before-recovery.toml'
  $originalConfig = "model = `"gpt-5`"`r`n`r`n[desktop]`r`nappearanceTheme = `"system`"`r`ncustom = `"保留`"`r`n"
  [System.IO.File]::WriteAllText($configPath, $originalConfig, [System.Text.UTF8Encoding]::new($false))
  Install-ZeyinMelodySkinBaseTheme -ConfigPath $configPath -BackupPath $backupPath -AppearanceTheme dark
  Assert-ZeyinTest -Condition (([System.IO.File]::ReadAllText($configPath)) -match 'appearanceTheme = "dark"') `
    -Message '固定主题未写入 dark appearanceTheme。'
  Assert-ZeyinTest -Condition ([System.Linq.Enumerable]::SequenceEqual(
      [byte[]][System.IO.File]::ReadAllBytes($backupPath),
      [byte[]]([System.Text.UTF8Encoding]::new($false).GetBytes($originalConfig)))) `
    -Message '安装前配置备份未保持原始字节。'
  Restore-ZeyinMelodySkinBaseTheme -ConfigPath $configPath -BackupPath $backupPath
  $restoredOwnedKeys = [System.IO.File]::ReadAllText($configPath)
  Assert-ZeyinTest -Condition ($restoredOwnedKeys -match 'appearanceTheme = "system"' -and
    $restoredOwnedKeys -match 'custom = "保留"' -and
    $restoredOwnedKeys -notmatch 'appearanceLightCodeThemeId') `
    -Message '恢复官方外观未恢复受管键。'
  [System.IO.File]::WriteAllText($configPath, "corrupted = true`n", [System.Text.UTF8Encoding]::new($false))
  Restore-ZeyinMelodySkinConfigBackup -ConfigPath $configPath -BackupPath $backupPath `
    -RecoveryBackupPath $recoveryPath
  Assert-ZeyinTest -Condition ([System.IO.File]::ReadAllText($configPath) -ceq $originalConfig) `
    -Message '完整配置恢复未还原原始字节。'

  # 原子引擎事务跑两次，验证 staging/backup 清理与固定资源合同。
  $engineStateRoot = Join-Path $temporaryRoot 'new-state'
  $engine = Install-ZeyinMelodySkinRuntimeEngine -SkillRoot $repositoryRoot -StateRoot $engineStateRoot
  $null = Assert-ZeyinMelodySkinFixedPayload -EngineRoot $engine.Root
  $firstHash = (Get-FileHash -LiteralPath (Join-Path $engine.Root 'scripts\injector.mjs') -Algorithm SHA256).Hash
  $engine = Install-ZeyinMelodySkinRuntimeEngine -SkillRoot $repositoryRoot -StateRoot $engineStateRoot
  $secondHash = (Get-FileHash -LiteralPath (Join-Path $engine.Root 'scripts\injector.mjs') -Algorithm SHA256).Hash
  Assert-ZeyinTest -Condition ($firstHash -ceq $secondHash) -Message '重复原子更新改变了固定引擎。'
  Assert-ZeyinTest -Condition (@(Get-ChildItem -LiteralPath $engineStateRoot -Force |
      Where-Object { $_.Name -like '.engine-staging-*' -or $_.Name -like '.engine-backup-*' }).Count -eq 0) `
    -Message '原子更新留下 staging 或 backup 目录。'

  # 路径越界和非标准完全删除目标必须 fail closed；标准新状态根可完整删除。
  $managedRoot = Join-Path $temporaryRoot 'managed'
  New-Item -ItemType Directory -Path $managedRoot | Out-Null
  Assert-ZeyinThrows -Pattern '逃逸状态根目录' -Action {
    Ensure-ZeyinMelodySkinManagedDirectory -Path (Join-Path $temporaryRoot 'outside') -Root $managedRoot
  }
  $testLocalAppData = Join-Path $temporaryRoot 'local-app-data'
  New-Item -ItemType Directory -Path $testLocalAppData | Out-Null
  $env:LOCALAPPDATA = $testLocalAppData
  $standardStateRoot = Join-Path $testLocalAppData 'ZeyinMelodySkin'
  New-Item -ItemType Directory -Path (Join-Path $standardStateRoot 'engine') -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $standardStateRoot 'recovery.txt'), 'fixture')
  Assert-ZeyinThrows -Pattern '拒绝删除非标准' -Action {
    Remove-ZeyinMelodySkinStateRootVerified -StateRoot (Join-Path $testLocalAppData 'wrong-root')
  }
  Remove-ZeyinMelodySkinStateRootVerified -StateRoot $standardStateRoot
  Assert-ZeyinTest -Condition (-not (Test-Path -LiteralPath $standardStateRoot)) `
    -Message '标准新状态根未完整删除。'

  # 端到端注入恢复失败：卸载引导必须返回非零，且不得删除状态或恢复材料。
  $bootstrapFixtureRoot = Join-Path $temporaryRoot 'uninstall-failure-fixture'
  $bootstrapPayloadScripts = Join-Path $bootstrapFixtureRoot 'payload\scripts'
  New-Item -ItemType Directory -Path $bootstrapPayloadScripts -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $repositoryRoot 'installer\setup-bootstrap.ps1') `
    -Destination (Join-Path $bootstrapFixtureRoot 'setup-bootstrap.ps1') -Force
  $uninstallLocalAppData = Join-Path $temporaryRoot 'uninstall-local-app-data'
  $uninstallStateRoot = Join-Path $uninstallLocalAppData 'ZeyinMelodySkin'
  $uninstallEngineRoot = Join-Path $uninstallStateRoot 'engine'
  New-Item -ItemType Directory -Path $uninstallEngineRoot -Force | Out-Null
  [System.IO.File]::WriteAllText(
    (Join-Path $uninstallStateRoot 'state.json'), '{"fixture":true}',
    [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText(
    (Join-Path $uninstallStateRoot 'recovery-material.txt'), 'must remain',
    [System.Text.UTF8Encoding]::new($false))
  $failingRestore = @'
param(
  [switch]$Uninstall,
  [switch]$ForceRestart,
  [switch]$NoRelaunch,
  [switch]$RestoreBaseTheme
)
throw 'fixture restore failure'
'@
  [System.IO.File]::WriteAllText(
    (Join-Path $uninstallEngineRoot 'restore-failure.ps1'), $failingRestore,
    [System.Text.UTF8Encoding]::new($true))
  $bootstrapCommon = @'
function Get-ZeyinMelodySkinRuntimeEnginePaths {
  param([string]$StateRoot)
  $root = Join-Path $StateRoot 'engine'
  return [pscustomobject]@{
    Root = $root
    Restore = Join-Path $root 'restore-failure.ps1'
    Tray = Join-Path $root 'tray-fixture.ps1'
  }
}
function Stop-ZeyinMelodySkinTrayProcess {
  param([string[]]$ScriptPaths, [switch]$RequireStopped)
}
function Test-ZeyinMelodySkinTrayActive { return $false }
'@
  [System.IO.File]::WriteAllText(
    (Join-Path $bootstrapPayloadScripts 'common-windows.ps1'), $bootstrapCommon,
    [System.Text.UTF8Encoding]::new($true))
  $bootstrapFixed = @'
function Remove-ZeyinMelodySkinStateRootVerified {
  param([string]$StateRoot)
  throw 'fixture state deletion must not run'
}
'@
  [System.IO.File]::WriteAllText(
    (Join-Path $bootstrapPayloadScripts 'fixed-theme-windows.ps1'), $bootstrapFixed,
    [System.Text.UTF8Encoding]::new($true))
  $previousTestLocalAppData = $env:LOCALAPPDATA
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $env:LOCALAPPDATA = $uninstallLocalAppData
    # 失败夹具会按预期写 stderr；先捕获输出与退出码，再由断言判断。
    $ErrorActionPreference = 'Continue'
    $powershellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
    $bootstrapOutput = & $powershellPath -NoProfile -ExecutionPolicy RemoteSigned `
      -File (Join-Path $bootstrapFixtureRoot 'setup-bootstrap.ps1') -Uninstall -Silent 2>&1
    $bootstrapExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    $env:LOCALAPPDATA = $previousTestLocalAppData
  }
  Assert-ZeyinTest -Condition ($bootstrapExitCode -ne 0) `
    -Message '恢复失败时卸载引导错误返回成功。'
  Assert-ZeyinTest -Condition (($bootstrapOutput -join "`n") -match 'fixture restore failure') `
    -Message '卸载引导未传播恢复失败原因。'
  Assert-ZeyinTest -Condition ((Test-Path -LiteralPath (Join-Path $uninstallStateRoot 'state.json')) -and
    (Test-Path -LiteralPath (Join-Path $uninstallStateRoot 'recovery-material.txt'))) `
    -Message '恢复失败后状态或恢复材料被错误删除。'

  Write-Host 'PASS: PowerShell 5.1、旧版互斥、配置事务、进程身份、原子引擎、恢复故障与拒绝路径。'
} finally {
  $env:LOCALAPPDATA = $originalLocalAppData
  if ($null -ne $fixtureProcess) {
    try {
      $fixtureProcess.Refresh()
      if (-not $fixtureProcess.HasExited) {
        Stop-Process -InputObject $fixtureProcess -Force -ErrorAction SilentlyContinue
        [void]$fixtureProcess.WaitForExit(15000)
      }
    } catch {}
  }
  $fullTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
  $systemTemporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  if ($fullTemporaryRoot.StartsWith($systemTemporaryRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
    [System.IO.Path]::GetFileName($fullTemporaryRoot).StartsWith('zeyin-melody-tests-')) {
    Remove-Item -LiteralPath $fullTemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
