function Assert-ZeyinMelodySkinNoReparseComponents {
  param([Parameter(Mandatory = $true)][string]$Path)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $root = [System.IO.Path]::GetPathRoot($fullPath)
  $current = $fullPath
  while ($true) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Zeyin Melody 受管路径包含 junction 或符号链接：$current"
      }
    }
    if ($current.TrimEnd('\').Equals($root.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
      break
    }
    $parent = [System.IO.Path]::GetDirectoryName($current)
    if (-not $parent -or $parent.Equals($current, [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $current = $parent
  }
}

function Ensure-ZeyinMelodySkinManagedDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Root
  )
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
  if (-not ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
      $fullPath.StartsWith($fullRoot + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "Zeyin Melody 受管路径逃逸状态根目录：$fullPath"
  }
  Assert-ZeyinMelodySkinNoReparseComponents -Path $fullPath
  if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
    throw "Zeyin Melody 受管路径是文件而不是目录：$fullPath"
  }
  New-Item -ItemType Directory -Force -Path $fullPath | Out-Null
  Assert-ZeyinMelodySkinNoReparseComponents -Path $fullPath
}

function Remove-ZeyinMelodySkinStateRootVerified {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  $fullRoot = [System.IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
  $expected = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'ZeyinMelodySkin')).TrimEnd('\')
  if (-not $fullRoot.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "拒绝删除非标准 Zeyin Melody 状态根目录：$fullRoot"
  }
  if (-not (Test-Path -LiteralPath $fullRoot)) { return }
  Assert-ZeyinMelodySkinNoReparseComponents -Path $fullRoot
  if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) {
    throw "Zeyin Melody 状态根目录不是目录：$fullRoot"
  }
  foreach ($item in Get-ChildItem -LiteralPath $fullRoot -Recurse -Force -ErrorAction Stop) {
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Zeyin Melody 状态根目录含 reparse 项，拒绝卸载清理：$($item.FullName)"
    }
  }
  [System.IO.Directory]::Delete($fullRoot, $true)
  if (Test-Path -LiteralPath $fullRoot) { throw 'Zeyin Melody 状态根目录未能完整删除。' }
}

function Get-ZeyinMelodySkinRuntimePaths {
  param(
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'ZeyinMelodySkin'),
    [string]$EngineRoot = (Split-Path -Parent $PSScriptRoot)
  )
  $root = [System.IO.Path]::GetFullPath($StateRoot)
  $engine = [System.IO.Path]::GetFullPath($EngineRoot)
  return [pscustomobject]@{
    Root = $root
    State = Join-Path $root 'state.json'
    PauseFile = Join-Path $root 'paused'
    ThemeRoot = Join-Path $engine 'assets'
  }
}

function Assert-ZeyinMelodySkinFixedPayload {
  param([string]$EngineRoot = (Split-Path -Parent $PSScriptRoot))
  $paths = Get-ZeyinMelodySkinRuntimePaths -EngineRoot $EngineRoot
  $required = @(
    'background.jpg',
    'renderer-inject.js',
    'selectors.json',
    'studio-theme.css',
    'structure.css',
    'theme.json',
    'zeyin-melody.css'
  )
  Assert-ZeyinMelodySkinNoReparseComponents -Path $paths.ThemeRoot
  foreach ($relative in $required) {
    $candidate = Join-Path $paths.ThemeRoot $relative
    Assert-ZeyinMelodySkinNoReparseComponents -Path $candidate
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      throw "固定主题负载缺失：assets\$relative"
    }
    if ((Get-Item -LiteralPath $candidate).Length -le 0) {
      throw "固定主题负载为空：assets\$relative"
    }
  }
  $background = Get-Item -LiteralPath (Join-Path $paths.ThemeRoot 'background.jpg')
  if ($background.Length -gt 10MB) { throw '固定背景图超过 10 MiB。' }
  $overlay = Get-Item -LiteralPath (Join-Path $paths.ThemeRoot 'zeyin-melody.css')
  if ($overlay.Length -gt 256KB) { throw '固定主题覆盖层超过 256 KiB。' }
  $themePath = Join-Path $paths.ThemeRoot 'theme.json'
  if ((Get-Item -LiteralPath $themePath).Length -gt 64KB) { throw '固定 theme.json 超过 64 KiB。' }
  try {
    $theme = (Read-ZeyinMelodySkinUtf8File -Path $themePath) | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "固定 theme.json 无法解析：$($_.Exception.Message)"
  }
  if ($null -eq $theme -or "$($theme.id)" -cne 'zeyin-melody' -or
    "$($theme.name)" -cne '泽音 Melody' -or
    "$($theme.brandSubtitle)" -cne 'Zeyin Melody Skin for Codex' -or
    "$($theme.promoUrl)" -cne 'https://github.com/yousizaitianqiong/Zeyin-Melody-Skin-for-Codex' -or
    "$($theme.image)" -cne 'background.jpg' -or "$($theme.appearance)" -cne 'dark') {
    throw '固定 theme.json 的产品身份或负载合同无效。'
  }
  $expectedHashes = @{
    'background.jpg' = '0B8744ED2C02D1B7322B8D9E478EA674F5726EDDE617861E8C49D49533EDD388'
    'studio-theme.css' = 'F9C23D29E8ACD1BE78E156E011F83AB84E0D90879B30B003E289A170BB77D409'
    'theme.json' = 'D67B6BC4DAD83F3C971D401CD0CDB7B45B8B8E8A128AB6916E07C451131196D0'
  }
  foreach ($relative in $expectedHashes.Keys) {
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $paths.ThemeRoot $relative)).Hash
    if ($actual -cne $expectedHashes[$relative]) {
      throw "Studio 固定资源 SHA-256 不匹配：assets\$relative"
    }
  }
  return [pscustomobject]@{ Paths = $paths; Theme = $theme }
}

function Get-ZeyinMelodySkinFixedAppearance {
  param([string]$EngineRoot = (Split-Path -Parent $PSScriptRoot))
  $payload = Assert-ZeyinMelodySkinFixedPayload -EngineRoot $EngineRoot
  return "$($payload.Theme.appearance)"
}

function Set-ZeyinMelodySkinPaused {
  param(
    [Parameter(Mandatory = $true)][bool]$Paused,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'ZeyinMelodySkin')
  )
  $paths = Get-ZeyinMelodySkinRuntimePaths -StateRoot $StateRoot
  Ensure-ZeyinMelodySkinManagedDirectory -Path $paths.Root -Root $paths.Root
  if ($Paused) {
    Assert-ZeyinMelodySkinNoReparseComponents -Path $paths.PauseFile
    Write-ZeyinMelodySkinUtf8FileAtomically -Path $paths.PauseFile -Content "paused`r`n"
  } else {
    if (Test-Path -LiteralPath $paths.PauseFile) {
      Assert-ZeyinMelodySkinNoReparseComponents -Path $paths.PauseFile
    }
    Remove-Item -LiteralPath $paths.PauseFile -Force -ErrorAction SilentlyContinue
  }
  return $Paused
}

function Test-ZeyinMelodySkinPaused {
  param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'ZeyinMelodySkin'))
  return Test-Path -LiteralPath (Get-ZeyinMelodySkinRuntimePaths -StateRoot $StateRoot).PauseFile -PathType Leaf
}

function Get-ZeyinMelodySkinLiveSessionContext {
  param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'ZeyinMelodySkin'))
  $paths = Get-ZeyinMelodySkinRuntimePaths -StateRoot $StateRoot
  $state = $null
  try { $state = Read-ZeyinMelodySkinState -Path $paths.State } catch { return $null }
  if ($null -eq $state -or -not $state.port -or -not $state.browserId) { return $null }
  $port = 0
  if (-not [int]::TryParse("$($state.port)", [ref]$port)) { return $null }
  Assert-ZeyinMelodySkinPort -Port $port
  $browserId = "$($state.browserId)".Trim()
  if (-not (Test-ZeyinMelodySkinBrowserId -Value $browserId)) { return $null }
  $node = Get-ZeyinMelodySkinNodeRuntime
  $injector = Join-Path $PSScriptRoot 'injector.mjs'
  if (-not (Test-Path -LiteralPath $injector -PathType Leaf)) { return $null }
  return [pscustomobject]@{
    Paths = $paths
    State = $state
    Port = $port
    BrowserId = $browserId
    NodePath = $node.Path
    Injector = $injector
  }
}

function New-ZeyinMelodySkinOperationToken {
  $milliseconds = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  return "${PID}:${milliseconds}:$(Get-Random -Minimum 1 -Maximum 99999999)"
}

function Show-ZeyinMelodySkinOperationUi {
  param(
    [Parameter(Mandatory = $true)][object]$Session,
    [Parameter(Mandatory = $true)][ValidateSet('begin', 'finish')][string]$Phase,
    [ValidateSet('apply', 'pause')][string]$Kind = 'apply',
    [string]$Token,
    [ValidateSet('success', 'error', 'cancelled')][string]$UiState = 'success',
    [string]$Message = '',
    [int]$TimeoutMs = 3000
  )
  $arguments = @($Session.Injector, '--port', "$($Session.Port)", '--browser-id',
    $Session.BrowserId, '--timeout-ms', "$TimeoutMs")
  if ($Phase -eq 'begin') {
    $operationToken = if ($Token) { $Token } else { New-ZeyinMelodySkinOperationToken }
    $arguments += @('--begin-operation', '--operation-kind', $Kind, '--operation-token', $operationToken)
    $probe = Invoke-ZeyinMelodySkinNative -FilePath $Session.NodePath -ArgumentList $arguments -DiscardStderr
    $printed = (($probe.Output -join "`n").Trim() -split "`n" | Select-Object -Last 1).Trim()
    return [pscustomobject]@{
      Ok = ($probe.ExitCode -eq 0 -and [bool]$printed)
      Token = if ($printed) { $printed } else { $operationToken }
    }
  }
  if (-not $Token) { throw '结束窗口内操作需要 token。' }
  if ($Message.Length -gt 240 -or $Message -match "[\r\n]") { throw '窗口内操作消息无效。' }
  $arguments += @('--finish-operation', '--operation-ui-state', $UiState,
    '--operation-message', $Message, '--operation-token', $Token)
  $probe = Invoke-ZeyinMelodySkinNative -FilePath $Session.NodePath -ArgumentList $arguments -DiscardStderr
  return [pscustomobject]@{ Ok = ($probe.ExitCode -eq 0); Token = $Token }
}

function Invoke-ZeyinMelodySkinLiveRemove {
  param(
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'ZeyinMelodySkin'),
    [ValidateRange(250, 120000)][int]$TimeoutMs = 8000
  )
  $session = Get-ZeyinMelodySkinLiveSessionContext -StateRoot $StateRoot
  if ($null -eq $session) {
    return [pscustomobject]@{ Attempted = $false; Removed = $false; Message = '没有可验证的活动会话；已记录暂停。' }
  }
  $begin = Show-ZeyinMelodySkinOperationUi -Session $session -Phase begin -Kind pause
  $arguments = @($session.Injector, '--remove', '--port', "$($session.Port)",
    '--browser-id', $session.BrowserId, '--timeout-ms', "$TimeoutMs",
    '--theme-dir', $session.Paths.ThemeRoot)
  if ($begin.Ok) { $arguments += @('--operation-token', $begin.Token) }
  $removal = Invoke-ZeyinMelodySkinNative -FilePath $session.NodePath -ArgumentList $arguments -DiscardStderr
  if ($removal.ExitCode -eq 0) {
    if ($begin.Ok) {
      $null = Show-ZeyinMelodySkinOperationUi -Session $session -Phase finish -Token $begin.Token `
        -UiState success -Message '泽音 Melody 主题已暂停' -TimeoutMs 1500
    }
    return [pscustomobject]@{ Attempted = $true; Removed = $true; Message = '泽音 Melody 主题已暂停。' }
  }
  if ($begin.Ok) {
    $null = Show-ZeyinMelodySkinOperationUi -Session $session -Phase finish -Token $begin.Token `
      -UiState error -Message '暂停失败，请重试' -TimeoutMs 1500
  }
  return [pscustomobject]@{
    Attempted = $true
    Removed = $false
    Message = '已记录暂停，但当前窗口主题未能安全卸下；请重试或恢复官方外观。'
  }
}
