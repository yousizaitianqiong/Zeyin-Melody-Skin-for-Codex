[CmdletBinding()]
param(
  [int]$Port = 9335,
  [string]$ScreenshotPath
)

$ErrorActionPreference = 'Stop'
$PortExplicit = $PSBoundParameters.ContainsKey('Port')
$injector = Join-Path $PSScriptRoot 'injector.mjs'
. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'fixed-theme-windows.ps1')

$operationLock = Enter-ZeyinMelodySkinOperationLock
$verifyExitCode = 1
try {
  $StatePath = Join-Path $env:LOCALAPPDATA 'ZeyinMelodySkin\state.json'
  $state = Read-ZeyinMelodySkinState -Path $StatePath
  if (-not $PortExplicit -and $null -ne $state -and $state.port) { $Port = [int]$state.port }
  Assert-ZeyinMelodySkinPort -Port $Port
  $node = Get-ZeyinMelodySkinNodeRuntime
  $currentCodex = Get-ZeyinMelodySkinCodexInstall
  $codex = $currentCodex
  $cdpIdentity = Get-ZeyinMelodySkinVerifiedCdpIdentity -Port $Port -Codex $codex
  if ($null -eq $cdpIdentity -and $null -ne $state) {
    $savedCodex = Get-ZeyinMelodySkinCodexInstallFromState -State $state
    if ($null -ne $savedCodex -and
      -not (Test-ZeyinMelodySkinPathEqual -Left $savedCodex.Executable -Right $currentCodex.Executable)) {
      $savedIdentity = Get-ZeyinMelodySkinVerifiedCdpIdentity -Port $Port -Codex $savedCodex
      if ($null -ne $savedIdentity) {
        $codex = $savedCodex
        $cdpIdentity = $savedIdentity
      }
    }
  }
  if ($null -eq $cdpIdentity) {
    # A Store auto-update replaces the "current" package while an older
    # registered version still owns the verified endpoint.
    $runningRegistered = Get-ZeyinMelodySkinVerifiedCdpIdentityForAnyRegistered -Port $Port
    if ($null -ne $runningRegistered) {
      $codex = $runningRegistered.Codex
      $cdpIdentity = $runningRegistered.Identity
    }
  }
  if ($null -eq $cdpIdentity) {
    throw "No verified Codex CDP endpoint is active on loopback port $Port."
  }
  if ($null -ne $state -and $state.browserId -and "$($state.browserId)" -cne $cdpIdentity.BrowserId) {
    throw '活动 CDP Browser 与保存的 Zeyin Melody 会话不一致；状态已保留。'
  }

  $engineRoot = Split-Path -Parent $PSScriptRoot
  $null = Assert-ZeyinMelodySkinFixedPayload -EngineRoot $engineRoot
  $skinPaths = Get-ZeyinMelodySkinRuntimePaths `
    -StateRoot (Join-Path $env:LOCALAPPDATA 'ZeyinMelodySkin') -EngineRoot $engineRoot
  $arguments = @($injector, '--verify', '--port', "$Port", '--browser-id', $cdpIdentity.BrowserId,
    '--theme-dir', $skinPaths.ThemeRoot, '--timeout-ms', '30000')
  if ($ScreenshotPath) { $arguments += @('--screenshot', $ScreenshotPath) }
  & $node.Path @arguments
  $verifyExitCode = $LASTEXITCODE
} finally {
  Exit-ZeyinMelodySkinOperationLock -Mutex $operationLock
}
exit $verifyExitCode
