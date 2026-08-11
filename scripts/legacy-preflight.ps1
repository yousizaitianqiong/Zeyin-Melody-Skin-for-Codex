$script:LegacyDreamSkinAppId = '{DCCDAF1A-9ACD-4AAB-B55B-DF17EB2CDA2E}'

function Test-ZeyinMelodySkinLegacyPathEqual {
  param([string]$Left, [string]$Right)
  if (-not $Left -or -not $Right) { return $false }
  try {
    return [System.IO.Path]::GetFullPath($Left).TrimEnd('\') -ieq
      [System.IO.Path]::GetFullPath($Right).TrimEnd('\')
  } catch { return $false }
}

function Test-ZeyinMelodySkinLegacyCommandToken {
  param([string]$CommandLine, [string]$Token)
  if (-not $CommandLine -or -not $Token) { return $false }
  return [regex]::IsMatch($CommandLine,
    '(?i)(?:^|[\s"])' + [regex]::Escape($Token) + '(?=$|[\s"])')
}

function Test-ZeyinMelodySkinLegacyLiveInjector {
  param([string]$OldStateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'))
  $statePath = Join-Path $OldStateRoot 'state.json'
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $false }
  try {
    $item = Get-Item -LiteralPath $statePath -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 1MB) {
      return $false
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $state = $utf8.GetString([System.IO.File]::ReadAllBytes($statePath)) |
      ConvertFrom-Json -ErrorAction Stop
    $pidValue = 0
    if (-not [int]::TryParse("$($state.injectorPid)", [ref]$pidValue) -or $pidValue -le 0 -or
      -not $state.injectorPath -or -not $state.nodePath -or -not $state.injectorStartedAt) {
      return $false
    }
    $handle = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if (-not $handle) { return $false }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $pidValue" -ErrorAction SilentlyContinue
    if (-not $process -or -not $process.CommandLine) { return $false }
    $processPath = "$($process.ExecutablePath)"
    if (-not $processPath) {
      try { $processPath = "$($handle.Path)" } catch { return $false }
    }
    $startedAt = $handle.StartTime.ToUniversalTime().ToString('o')
    return (Test-ZeyinMelodySkinLegacyPathEqual -Left $processPath -Right "$($state.nodePath)") -and
      ($startedAt -ceq "$($state.injectorStartedAt)") -and
      (Test-ZeyinMelodySkinLegacyCommandToken -CommandLine "$($process.CommandLine)" -Token "$($state.injectorPath)") -and
      (Test-ZeyinMelodySkinLegacyCommandToken -CommandLine "$($process.CommandLine)" -Token '--watch')
  } catch { return $false }
}

function Get-ZeyinMelodySkinLegacyConflicts {
  param(
    [string]$OldStateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'),
    [string]$OldInstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\CodexDreamSkin'),
    [switch]$SkipRegistry
  )
  $conflicts = New-Object System.Collections.Generic.List[string]
  if (-not $SkipRegistry) {
    $uninstallKeys = @(
      "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$($script:LegacyDreamSkinAppId)_is1",
      "HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$($script:LegacyDreamSkinAppId)_is1"
    )
    if (@($uninstallKeys | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0) {
      $conflicts.Add('旧版 AppId 卸载注册项')
    }
  }
  if (Test-Path -LiteralPath $OldInstallRoot) { $conflicts.Add('旧版安装目录') }
  if (Test-ZeyinMelodySkinLegacyLiveInjector -OldStateRoot $OldStateRoot) {
    $conflicts.Add('旧版活动注入器')
  }
  if (Test-Path -LiteralPath (Join-Path $OldStateRoot 'engine')) { $conflicts.Add('旧版受管 engine') }
  if (Test-Path -LiteralPath (Join-Path $OldStateRoot 'config.before-dream-skin.toml')) {
    $conflicts.Add('旧版配置备份')
  }
  if (Test-Path -LiteralPath $OldStateRoot) {
    $rootItem = Get-Item -LiteralPath $OldStateRoot -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
      -not $rootItem.PSIsContainer) {
      $conflicts.Add('不可信的旧版状态根路径')
    } else {
      $allowed = @('themes', 'images')
      foreach ($child in Get-ChildItem -LiteralPath $OldStateRoot -Force -ErrorAction Stop) {
        if ($child.Name -notin $allowed -and $child.Name -notin @('engine', 'config.before-dream-skin.toml')) {
          $conflicts.Add("旧版运行状态残留：$($child.Name)")
        } elseif ($child.Name -in $allowed -and
          (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or -not $child.PSIsContainer)) {
          $conflicts.Add("不可信的旧版资源残留：$($child.Name)")
        }
      }
    }
  }
  return @($conflicts | Select-Object -Unique)
}

function Assert-ZeyinMelodySkinLegacyDreamSkinAbsent {
  $conflicts = @(Get-ZeyinMelodySkinLegacyConflicts)
  if ($conflicts.Count -eq 0) { return }
  throw ('检测到旧版 Codex Dream Skin：' + ($conflicts -join '、') +
    '。本次操作未写入任何 Zeyin Melody 状态。请先在旧版执行 Restore（恢复官方外观），再卸载旧版，最后重试。不会自动卸载旧版。')
}

function Assert-ZeyinMelodySkinNoLegacyLiveInjector {
  if (Test-ZeyinMelodySkinLegacyLiveInjector) {
    throw '检测到旧版 Codex Dream Skin 活动注入器。请先在旧版执行 Restore，再卸载旧版，然后重试；当前启动未作更改。'
  }
}
