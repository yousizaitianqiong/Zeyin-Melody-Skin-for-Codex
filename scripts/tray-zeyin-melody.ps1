[CmdletBinding()]
param([int]$Port = 9335)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'legacy-preflight.ps1')
Assert-ZeyinMelodySkinLegacyDreamSkinAbsent
. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'fixed-theme-windows.ps1')

Assert-ZeyinMelodySkinPort -Port $Port
$EngineRoot = Split-Path -Parent $PSScriptRoot
$StateRoot = Join-Path $env:LOCALAPPDATA 'ZeyinMelodySkin'
$paths = Get-ZeyinMelodySkinRuntimePaths -StateRoot $StateRoot -EngineRoot $EngineRoot
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$startScript = Join-Path $PSScriptRoot 'start-zeyin-melody.ps1'
$restoreScript = Join-Path $PSScriptRoot 'restore-zeyin-melody.ps1'
$verifyScript = Join-Path $PSScriptRoot 'verify-zeyin-melody.ps1'
$checkUpdateScript = Join-Path $PSScriptRoot 'check-update.ps1'
$uninstaller = Join-Path $env:LOCALAPPDATA 'Programs\ZeyinMelodySkin\unins000.exe'

$mutex = [System.Threading.Mutex]::new($false, 'Local\ZeyinMelodySkin.Tray')
$acquired = $false
$notify = $null
$trayIcon = $null
try {
  try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
  if (-not $acquired) { exit 0 }

  $initializationLock = Enter-ZeyinMelodySkinOperationLock
  try {
    Ensure-ZeyinMelodySkinManagedDirectory -Path $paths.Root -Root $paths.Root
    $null = Assert-ZeyinMelodySkinFixedPayload -EngineRoot $EngineRoot
  } finally {
    Exit-ZeyinMelodySkinOperationLock -Mutex $initializationLock
  }

  $notify = [System.Windows.Forms.NotifyIcon]::new()
  $iconPath = Join-Path $EngineRoot 'assets\zeyin-melody-skin.ico'
  if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
    $trayIcon = [System.Drawing.Icon]::new($iconPath)
    $notify.Icon = $trayIcon
  } else {
    $notify.Icon = [System.Drawing.SystemIcons]::Application
  }
  $notify.Text = 'Zeyin Melody Skin for Codex'
  $notify.Visible = $true
  $menu = [System.Windows.Forms.ContextMenuStrip]::new()
  $notify.ContextMenuStrip = $menu

  function Show-ZeyinMelodySkinTrayError {
    param([string]$Message)
    [void][System.Windows.Forms.MessageBox]::Show(
      $Message,
      'Zeyin Melody Skin for Codex',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    )
  }

  function Start-ZeyinMelodySkinPowerShell {
    param(
      [Parameter(Mandatory = $true)][string]$Script,
      [string[]]$Arguments = @(),
      [switch]$Wait
    )
    $tokens = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'RemoteSigned',
      '-File', (ConvertTo-ZeyinMelodySkinProcessArgument -Value $Script))
    $tokens += @($Arguments | ForEach-Object { ConvertTo-ZeyinMelodySkinProcessArgument -Value $_ })
    $process = Start-Process -FilePath $powershell -ArgumentList ($tokens -join ' ') `
      -WindowStyle Hidden -PassThru -Wait:$Wait
    return $process
  }

  function Add-ZeyinMelodySkinTrayItem {
    param(
      [Parameter(Mandatory = $true)][AllowEmptyCollection()]
      [System.Windows.Forms.ToolStripItemCollection]$Items,
      [Parameter(Mandatory = $true)][string]$Text,
      [AllowNull()][scriptblock]$Action,
      [bool]$Enabled = $true
    )
    $item = [System.Windows.Forms.ToolStripMenuItem]::new($Text)
    $item.Enabled = $Enabled
    if ($null -ne $Action) {
      $item.add_Click({
        try { & $Action } catch { Show-ZeyinMelodySkinTrayError -Message $_.Exception.Message }
      }.GetNewClosure())
    }
    [void]$Items.Add($item)
    return $item
  }

  function Start-ZeyinMelodySkinApply {
    $null = Start-ZeyinMelodySkinPowerShell -Script $startScript `
      -Arguments @('-Port', "$Port", '-PromptRestart')
    $notify.ShowBalloonTip(1800, 'Zeyin Melody', '正在启动或应用固定主题…',
      [System.Windows.Forms.ToolTipIcon]::Info)
  }

  function Rebuild-ZeyinMelodySkinTrayMenu {
    $menu.Items.Clear()
    $paused = Test-ZeyinMelodySkinPaused -StateRoot $StateRoot
    $state = $null
    try { $state = Read-ZeyinMelodySkinState -Path $paths.State } catch {}
    $status = if ($paused) { '状态：已暂停' } elseif ($state) { '状态：运行中' } else { '状态：未运行' }
    $null = Add-ZeyinMelodySkinTrayItem -Items $menu.Items -Text $status -Action $null -Enabled $false
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

    $null = Add-ZeyinMelodySkinTrayItem -Items $menu.Items -Text '启动 Codex（应用主题）' -Action {
      Start-ZeyinMelodySkinApply
    }

    if ($paused) {
      $null = Add-ZeyinMelodySkinTrayItem -Items $menu.Items -Text '恢复显示主题' -Action {
        Start-ZeyinMelodySkinApply
      }
    } else {
      $null = Add-ZeyinMelodySkinTrayItem -Items $menu.Items -Text '暂停主题' -Action {
        $operationLock = Enter-ZeyinMelodySkinOperationLock
        try {
          Set-ZeyinMelodySkinPaused -Paused $true -StateRoot $StateRoot | Out-Null
          $removal = Invoke-ZeyinMelodySkinLiveRemove -StateRoot $StateRoot
        } finally {
          Exit-ZeyinMelodySkinOperationLock -Mutex $operationLock
        }
        $icon = if ($removal.Removed) {
          [System.Windows.Forms.ToolTipIcon]::Info
        } else {
          [System.Windows.Forms.ToolTipIcon]::Warning
        }
        $notify.ShowBalloonTip(2800, 'Zeyin Melody', $removal.Message, $icon)
      }
    }

    $null = Add-ZeyinMelodySkinTrayItem -Items $menu.Items -Text '重新应用主题' -Action {
      Start-ZeyinMelodySkinApply
    }
    $null = Add-ZeyinMelodySkinTrayItem -Items $menu.Items -Text '验证当前会话' -Action {
      $process = Start-ZeyinMelodySkinPowerShell -Script $verifyScript `
        -Arguments @('-Port', "$Port") -Wait
      if ($process.ExitCode -eq 0) {
        $notify.ShowBalloonTip(2200, 'Zeyin Melody', '当前窗口验证通过。',
          [System.Windows.Forms.ToolTipIcon]::Info)
      } else {
        Show-ZeyinMelodySkinTrayError -Message "验证失败（退出码 $($process.ExitCode)）。请查看状态目录中的日志。"
      }
    }
    $null = Add-ZeyinMelodySkinTrayItem -Items $menu.Items -Text '检查更新…' -Action {
      $null = Start-ZeyinMelodySkinPowerShell -Script $checkUpdateScript -Arguments @('-Interactive')
    }

    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $null = Add-ZeyinMelodySkinTrayItem -Items $menu.Items -Text '恢复官方外观' -Action {
      $null = Start-ZeyinMelodySkinPowerShell -Script $restoreScript `
        -Arguments @('-Port', "$Port", '-RestoreBaseTheme', '-PromptRestart')
      $notify.Visible = $false
      [System.Windows.Forms.Application]::Exit()
    }
    $null = Add-ZeyinMelodySkinTrayItem -Items $menu.Items -Text '完全卸载…' -Action {
      $expectedInstallRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $env:LOCALAPPDATA 'Programs\ZeyinMelodySkin'))
      $resolvedUninstaller = [System.IO.Path]::GetFullPath($uninstaller)
      if (-not $resolvedUninstaller.StartsWith($expectedInstallRoot.TrimEnd('\') + '\',
          [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $resolvedUninstaller -PathType Leaf)) {
        throw '未找到受信的 Zeyin Melody 安装器卸载入口；源码安装请运行恢复脚本。'
      }
      Assert-ZeyinMelodySkinNoReparseComponents -Path $resolvedUninstaller
      Start-Process -FilePath $resolvedUninstaller | Out-Null
    }
    $null = Add-ZeyinMelodySkinTrayItem -Items $menu.Items -Text '退出托盘' -Action {
      $notify.Visible = $false
      [System.Windows.Forms.Application]::Exit()
    }
  }

  $menu.add_Opening({
    param($sender, $eventArgs)
    try {
      Rebuild-ZeyinMelodySkinTrayMenu
    } catch {
      $eventArgs.Cancel = $true
      Show-ZeyinMelodySkinTrayError -Message "托盘菜单加载失败：$($_.Exception.Message)"
    }
  })
  $notify.add_DoubleClick({
    try { Start-ZeyinMelodySkinApply } catch { Show-ZeyinMelodySkinTrayError -Message $_.Exception.Message }
  })
  [System.Windows.Forms.Application]::Run()
} finally {
  if ($null -ne $notify) { $notify.Dispose() }
  if ($null -ne $trayIcon) { $trayIcon.Dispose() }
  if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
  $mutex.Dispose()
}
