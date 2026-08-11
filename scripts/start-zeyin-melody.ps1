[CmdletBinding()]
param(
  [int]$Port = 9335,
  [switch]$RestartExisting,
  [switch]$PromptRestart,
  [string]$ProfilePath,
  [switch]$ForegroundInjector,
  [ValidateRange(0, 300000)][int]$OperationLockTimeoutMilliseconds = 0,
  [switch]$RequireUnpaused
)

$ErrorActionPreference = 'Stop'
$PortExplicit = $PSBoundParameters.ContainsKey('Port')
$Injector = Join-Path $PSScriptRoot 'injector.mjs'
. (Join-Path $PSScriptRoot 'legacy-preflight.ps1')
Assert-ZeyinMelodySkinNoLegacyLiveInjector
. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'fixed-theme-windows.ps1')

$operationLock = Enter-ZeyinMelodySkinOperationLock `
  -TimeoutMilliseconds $OperationLockTimeoutMilliseconds
try {
  Assert-ZeyinMelodySkinPort -Port $Port
  if ($ProfilePath) { $ProfilePath = [System.IO.Path]::GetFullPath($ProfilePath) }
  $node = Get-ZeyinMelodySkinNodeRuntime
  $currentCodex = Get-ZeyinMelodySkinCodexInstall
  $codex = $currentCodex
  $StateRoot = Join-Path $env:LOCALAPPDATA 'ZeyinMelodySkin'
  $engineRoot = Split-Path -Parent $PSScriptRoot
  $skinPaths = Get-ZeyinMelodySkinRuntimePaths -StateRoot $StateRoot -EngineRoot $engineRoot
  Ensure-ZeyinMelodySkinManagedDirectory -Path $skinPaths.Root -Root $skinPaths.Root
  $StatePath = Join-Path $StateRoot 'state.json'
  $StdoutPath = Join-Path $StateRoot 'injector.log'
  $StderrPath = Join-Path $StateRoot 'injector-error.log'
  $VerifyPath = Join-Path $StateRoot 'verify.log'
  $payload = Assert-ZeyinMelodySkinFixedPayload -EngineRoot $engineRoot
  $pauseWasSet = Test-ZeyinMelodySkinPaused -StateRoot $StateRoot
  if ($RequireUnpaused -and $pauseWasSet) {
    throw 'A newer pause request superseded this theme apply before renderer verification.'
  }

  $previousState = Read-ZeyinMelodySkinState -Path $StatePath
  if (-not $PortExplicit -and $null -ne $previousState -and $previousState.port) {
    $savedPort = [int]$previousState.port
    Assert-ZeyinMelodySkinPort -Port $savedPort
    $Port = $savedPort
  }
  $savedPathCandidate = Get-ZeyinMelodySkinCodexStatePathCandidate -State $previousState
  $savedCodex = Get-ZeyinMelodySkinCodexInstallFromState -State $previousState
  $candidateMatchesCurrent = [bool]($null -ne $savedPathCandidate -and
    (Test-ZeyinMelodySkinPathEqual -Left $savedPathCandidate.PackageRoot -Right $currentCodex.PackageRoot) -and
    (Test-ZeyinMelodySkinPathEqual -Left $savedPathCandidate.Executable -Right $currentCodex.Executable))
  if ($null -ne $savedPathCandidate -and $null -eq $savedCodex -and -not $candidateMatchesCurrent) {
    $unverifiedSavedRunning = (Get-ZeyinMelodySkinCodexProcesses -Codex $savedPathCandidate).Count -gt 0
    $unverifiedSavedOwnsPort = Test-ZeyinMelodySkinCodexPortOwner -Port $Port -Codex $savedPathCandidate
    if ($unverifiedSavedRunning -or $unverifiedSavedOwnsPort) {
      throw 'The saved Codex path is still active but no longer matches a registered OpenAI.Codex package. Close it manually; state was preserved.'
    }
  }

  $currentProcesses = Get-ZeyinMelodySkinCodexProcesses -Codex $currentCodex
  $codexToStop = $currentCodex
  $cdpIdentity = Get-ZeyinMelodySkinVerifiedCdpIdentity -Port $Port -Codex $currentCodex
  if ($null -eq $cdpIdentity) {
    # After a Store auto-update the running (older) package still owns the
    # verified endpoint while Get-ZeyinMelodySkinCodexInstall already resolves to
    # the new one.  Adopt the running install instead of restarting it.
    $runningRegistered = Get-ZeyinMelodySkinVerifiedCdpIdentityForAnyRegistered -Port $Port
    if ($null -ne $runningRegistered) {
      $cdpIdentity = $runningRegistered.Identity
      $codex = $runningRegistered.Codex
      $codexToStop = $runningRegistered.Codex
    }
  }
  $savedIsDifferent = [bool]($null -ne $savedCodex -and
    -not (Test-ZeyinMelodySkinPathEqual -Left $savedCodex.Executable -Right $currentCodex.Executable))
  if ($savedIsDifferent) {
    $savedProcesses = Get-ZeyinMelodySkinCodexProcesses -Codex $savedCodex
    $savedOwnsPort = Test-ZeyinMelodySkinCodexPortOwner -Port $Port -Codex $savedCodex
    if ($currentProcesses.Count -gt 0 -and ($savedProcesses.Count -gt 0 -or $savedOwnsPort)) {
      throw 'Multiple registered Codex package versions are active. Close them manually before starting Zeyin Melody Skin.'
    }
    if ($savedProcesses.Count -gt 0 -or $savedOwnsPort) {
      if ($savedOwnsPort -and $savedProcesses.Count -eq 0) {
        throw 'The saved Codex listener is active but its process cannot be managed safely; state was preserved.'
      }
      $savedIdentity = Get-ZeyinMelodySkinVerifiedCdpIdentity -Port $Port -Codex $savedCodex
      if ($null -ne $savedIdentity) {
        $codex = $savedCodex
        $codexToStop = $savedCodex
        $cdpIdentity = $savedIdentity
        Write-Warning 'Reapplying Zeyin Melody Skin to the still-running registered Codex version; the current Store version will be used after that app exits.'
      } else {
        $codexToStop = $savedCodex
        $currentProcesses = $savedProcesses
      }
    }
  }
  $debugReady = $null -ne $cdpIdentity
  $codexProcesses = if (Test-ZeyinMelodySkinPathEqual -Left $codexToStop.Executable -Right $currentCodex.Executable) {
    $currentProcesses
  } else {
    Get-ZeyinMelodySkinCodexProcesses -Codex $codexToStop
  }
  $closedExistingCodex = $false
  if (-not $debugReady -and $codexProcesses.Count -gt 0) {
    $restartAuthorized = [bool]$RestartExisting
    if (-not $restartAuthorized -and $PromptRestart) {
      $restartAuthorized = Confirm-ZeyinMelodySkinRestart -Message 'Codex must restart once to enable Zeyin Melody Skin. Unsaved input may be lost. Restart now?'
      if (-not $restartAuthorized) {
        Write-Host 'Zeyin Melody Skin launch was cancelled; Codex was not changed.'
        exit 0
      }
    }
    if (-not $restartAuthorized) {
      throw 'Codex is open without a verified Zeyin Melody Skin CDP endpoint. Close it first or explicitly use -RestartExisting.'
    }
    Stop-ZeyinMelodySkinCodex -Codex $codexToStop -AllowForce
    $closedExistingCodex = $true
    $codex = $currentCodex
  }

  $launchedWithCdp = $false
  $debugLaunchAttempted = $false
  $debugLaunch = $null
  $debugLaunchBaselineProcessIds = @()
  # Set by the verify loop when the renderer reports a visible, structurally
  # complete skin even though verification did not pass overall.
  $skinLooksRendered = $false
  try {
    if ($null -eq (Get-ZeyinMelodySkinVerifiedCdpIdentity -Port $Port -Codex $codex)) {
      # Codex is closed on this path; sync the appearanceTheme pin to the
      # active theme before launching (config writes race the app while it runs).
      try {
        $profileRoot = [Environment]::GetFolderPath('UserProfile')
        Install-ZeyinMelodySkinBaseTheme -ConfigPath (Join-Path $profileRoot '.codex\config.toml') `
          -BackupPath (Join-Path $StateRoot 'config.before-zeyin-melody-skin.toml') `
          -AppearanceTheme "$($payload.Theme.appearance)"
      } catch {
        Write-Warning "Could not sync Codex appearanceTheme to the active theme: $($_.Exception.Message)"
      }
      if (-not (Test-ZeyinMelodySkinPortAvailable -Port $Port)) {
        if ($PortExplicit) { throw "Port $Port is already occupied by an unverified listener. Choose another port." }
        $Port = Select-ZeyinMelodySkinPort -PreferredPort $Port
      }
      $arguments = @('--remote-debugging-address=127.0.0.1', "--remote-debugging-port=$Port")
      if ($ProfilePath) {
        New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
        $arguments += "--user-data-dir=$ProfilePath"
      }
      $debugLaunchAttempted = $true
      $debugLaunchBaselineProcessIds = @(
        Get-ZeyinMelodySkinCodexProcesses -Codex $codex | ForEach-Object { [int]$_.ProcessId }
      )
      $debugLaunch = Start-ZeyinMelodySkinCodexForDebugging -Codex $codex -Arguments $arguments `
        -Port $Port -PreserveProcessIds $debugLaunchBaselineProcessIds
      $launchedWithCdp = $true
      if ($debugLaunch.Strategy -eq 'direct-store-executable') {
        Write-Warning 'Codex package activation did not preserve the CDP arguments; using the validated Store executable fallback for this session.'
      }
    }

    $deadline = (Get-Date).AddSeconds(45)
    $cdpIdentity = Get-ZeyinMelodySkinVerifiedCdpIdentity -Port $Port -Codex $codex
    while ($null -eq $cdpIdentity) {
      $argumentStatus = Get-ZeyinMelodySkinCodexDebugArgumentStatus `
        -Processes @(Get-ZeyinMelodySkinCodexProcesses -Codex $codex) -Port $Port
      if ($argumentStatus -eq 'protocol-redirected') {
        throw "Codex $($codex.Version) converted the CDP argument into a codex:// navigation path instead of opening a debugging endpoint."
      }
      if ((Get-Date) -ge $deadline) {
        if ($null -ne $debugLaunch -and $debugLaunch.Strategy -eq 'direct-store-executable') {
          throw "The validated direct Store executable fallback did not expose a verified loopback CDP endpoint on port $Port within 45 seconds. Codex $($codex.Version) may disable CDP in this production runtime; no protected app files or permissions were changed."
        }
        throw "Codex did not expose a verified loopback CDP endpoint on port $Port within 45 seconds."
      }
      Start-Sleep -Milliseconds 400
      $cdpIdentity = Get-ZeyinMelodySkinVerifiedCdpIdentity -Port $Port -Codex $codex
    }
  } catch {
    $launchError = $_
    if ($debugLaunchAttempted) {
      try {
        Stop-ZeyinMelodySkinCodex -Codex $codex `
          -PreserveProcessIds $debugLaunchBaselineProcessIds -AllowForce
      } catch {
        Write-Warning 'Launch rollback could not fully close the failed CDP session.'
      }
    }
    if (($closedExistingCodex -or $debugLaunchAttempted) -and
      (Get-ZeyinMelodySkinCodexProcesses -Codex $codex).Count -eq 0) {
      if ($debugLaunchAttempted) {
        Write-Warning 'Zeyin Melody Skin launch failed; reopening Codex without a debugging port.'
      }
      try { $null = Start-ZeyinMelodySkinCodex -Codex $codex } catch {
        Write-Warning 'Launch rollback could not reopen Codex automatically.'
      }
    }
    throw $launchError
  }

  try {
    $recordedInjectorStopped = Stop-ZeyinMelodySkinRecordedInjector -State $previousState
    if (-not $recordedInjectorStopped) {
      $staleStatePath = Archive-ZeyinMelodySkinStateFile -Path $StatePath
      Write-Warning "Archived stale Zeyin Melody Skin state at $staleStatePath"
    }
  } catch {
    if ($launchedWithCdp) {
      try {
        Stop-ZeyinMelodySkinCodex -Codex $codex -AllowForce
        $null = Start-ZeyinMelodySkinCodex -Codex $codex
      } catch {
        Write-Warning 'State validation rollback could not fully restart Codex; close Codex to ensure its CDP port is closed.'
      }
    }
    throw
  }

  # Keep a paused, already-running watcher paused until all state checks and any
  # restart consent have succeeded.  A cancelled prompt must be side-effect free.
  Set-ZeyinMelodySkinPaused -Paused $false -StateRoot $StateRoot | Out-Null
  $pauseCleared = $true

  if ($ForegroundInjector) {
    try {
      Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
      Exit-ZeyinMelodySkinOperationLock -Mutex $operationLock
      $operationLock = $null
      & $node.Path $Injector --watch --port $Port --browser-id $cdpIdentity.BrowserId `
        --theme-dir $skinPaths.ThemeRoot --pause-file $skinPaths.PauseFile
      $foregroundExitCode = $LASTEXITCODE
      if ($foregroundExitCode -ne 0 -and $pauseWasSet) {
        Set-ZeyinMelodySkinPaused -Paused $true -StateRoot $StateRoot | Out-Null
      }
      exit $foregroundExitCode
    } catch {
      if ($pauseWasSet) {
        try { Set-ZeyinMelodySkinPaused -Paused $true -StateRoot $StateRoot | Out-Null } catch {
          Write-Warning 'Foreground startup rollback could not restore the existing paused state.'
        }
      }
      throw
    }
  }

  $state = $null
  $daemon = $null
  try {
    $injectorArgs = @((ConvertTo-ZeyinMelodySkinProcessArgument -Value $Injector), '--watch', '--port', "$Port",
      '--browser-id', $cdpIdentity.BrowserId, '--theme-dir',
      (ConvertTo-ZeyinMelodySkinProcessArgument -Value $skinPaths.ThemeRoot), '--pause-file',
      (ConvertTo-ZeyinMelodySkinProcessArgument -Value $skinPaths.PauseFile))
    $daemon = Start-Process -FilePath $node.Path -ArgumentList $injectorArgs -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
    Start-Sleep -Milliseconds 500
    if ($daemon.HasExited) { throw "The injector exited during startup. See $StderrPath" }

    $injectorStartedAt = Get-ZeyinMelodySkinProcessStartedAt -ProcessId $daemon.Id
    if (-not $injectorStartedAt) { throw 'The injector process identity could not be recorded safely.' }
    $state = [pscustomobject]@{
      schemaVersion = 3
      platform = 'windows'
      port = $Port
      injectorPid = $daemon.Id
      injectorStartedAt = $injectorStartedAt
      injectorPath = $Injector
      nodePath = $node.Path
      nodeVersion = $node.Version
      codexExe = $codex.Executable
      codexPackageRoot = $codex.PackageRoot
      codexPackageFullName = $codex.PackageFullName
      codexPackageFamilyName = $codex.PackageFamilyName
      codexVersion = $codex.Version
      browserId = $cdpIdentity.BrowserId
      profilePath = $ProfilePath
      themeDir = $skinPaths.ThemeRoot
      pauseFile = $skinPaths.PauseFile
      createdAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-ZeyinMelodySkinState -Path $StatePath -State $state

    # The one-shot verify races Codex's first paint: on a slow machine the
    # shell markers are not rendered yet when the daemon has barely started,
    # and a single early miss used to tear the whole startup down.  The
    # watcher keeps applying in the background, so retry until a deadline.
    $verifyDeadline = (Get-Date).AddSeconds(90)
    $forceInjectedAfterVerifyFailure = $false
    while ($true) {
      $verify = Invoke-ZeyinMelodySkinNative -FilePath $node.Path -ArgumentList @(
        $Injector, '--verify', '--port', "$Port",
        '--browser-id', $cdpIdentity.BrowserId, '--theme-dir', $skinPaths.ThemeRoot,
        '--timeout-ms', '30000')
      Write-ZeyinMelodySkinUtf8FileAtomically -Path $VerifyPath -Content (($verify.Output -join "`r`n") + "`r`n")
      if ($verify.ExitCode -eq 0) { break }
      # A verify can fail while the theme is demonstrably on screen: the
      # renderer reports the document visible, the viewport sized and the shell
      # structure present, and only the native-window probe -- which some Codex
      # builds never resolve -- comes back false.  Killing Codex in that state
      # destroys a working skin the user is looking at, so remember it and let
      # the rollback below leave the app alone (#267).
      $skinLooksRendered = $false
      try {
        $verifyJson = ($verify.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop
        $readiness = $verifyJson.readiness
        $skinLooksRendered = [bool]$verifyJson.installed -and [bool]$verifyJson.stylePresent -and
          [bool]$readiness.documentPass -and [bool]$readiness.viewportPass -and
          [bool]$readiness.structurePass
      } catch {
        $skinLooksRendered = $false
      }
      if (-not $forceInjectedAfterVerifyFailure) {
        $forceInjectedAfterVerifyFailure = $true
        try { [void](Invoke-ZeyinMelodySkinCodexWindowActivation -Codex $codex) } catch {}
        $once = Invoke-ZeyinMelodySkinNative -FilePath $node.Path -ArgumentList @(
          $Injector, '--once', '--port', "$Port",
        '--browser-id', $cdpIdentity.BrowserId, '--theme-dir', $skinPaths.ThemeRoot,
          '--timeout-ms', '15000')
        Write-ZeyinMelodySkinUtf8FileAtomically -Path $VerifyPath -Content (
          (($verify.Output + $once.Output) -join "`r`n") + "`r`n"
        )
        if ($once.ExitCode -eq 0) { break }
      }
      if ($daemon.HasExited) { throw "The injector exited during startup. See $StderrPath" }
      if ((Get-Date) -ge $verifyDeadline) { throw "Zeyin Melody Skin verification failed. See $VerifyPath" }
      Start-Sleep -Seconds 3
    }
  } catch {
    $startupError = $_
    # We own the daemon Process object, so stop it directly: the object is
    # immune to PID reuse, and identity re-validation cannot spuriously
    # refuse.  Slow machines also need more than a moment for teardown; a
    # premature "did not stop" here is what used to leave duelling watchers.
    $injectorStopped = $true
    if ($null -ne $daemon) {
      if (-not $daemon.HasExited) {
        try {
          Stop-Process -InputObject $daemon -Force -ErrorAction Stop
        } catch {
          Write-Warning 'The newly created injector could not be signalled during startup rollback.'
        }
      }
      [void]$daemon.WaitForExit(15000)
      $injectorStopped = $daemon.HasExited
      if (-not $injectorStopped) {
        Write-Warning "The rollback injector has not exited yet: PID $($daemon.Id). State was preserved so the next start can reconcile it."
      }
    }
    if ($injectorStopped -and -not $launchedWithCdp) {
      try {
        $rollbackIdentity = Get-ZeyinMelodySkinVerifiedCdpIdentity -Port $Port -Codex $codex
        if ($null -ne $rollbackIdentity -and $rollbackIdentity.BrowserId -ceq $cdpIdentity.BrowserId) {
          $removal = Invoke-ZeyinMelodySkinNative -FilePath $node.Path -ArgumentList @(
            $Injector, '--remove', '--port', "$Port",
            '--browser-id', $cdpIdentity.BrowserId, '--timeout-ms', '5000') -DiscardStderr
          if ($removal.ExitCode -ne 0) { throw 'Injector removal returned a failure status.' }
        }
      } catch {
        Write-Warning 'Startup rollback could not remove the partially applied live skin; reload or close Codex to clear it.'
      }
    }
    if ($injectorStopped) { Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue }
    if ($launchedWithCdp -and -not $skinLooksRendered) {
      try {
        Stop-ZeyinMelodySkinCodex -Codex $codex -AllowForce
        $null = Start-ZeyinMelodySkinCodex -Codex $codex
      } catch {
        Write-Warning 'Startup rollback could not fully restart Codex; close Codex to ensure its CDP port is closed.'
      }
    } elseif ($launchedWithCdp) {
      # The skin is on screen and only an inconclusive probe failed. Force-
      # restarting Codex here would take a working window away from the user
      # and leave them with the stock appearance, which is worse than the
      # unverified state we are in. The injector is already stopped and the
      # state file removed, so nothing claims this session is verified; Codex
      # keeps running with its debug port until the user closes it (#267).
      Write-Warning 'Zeyin Melody Skin could not verify this session, but the theme is rendered. Codex was left running; close and reopen it to return to the stock appearance.'
    }
    if ($pauseWasSet -and $pauseCleared) {
      try {
        Set-ZeyinMelodySkinPaused -Paused $true -StateRoot $StateRoot | Out-Null
      } catch {
        Write-Warning 'Startup rollback could not restore the existing paused state.'
      }
    }
    throw $startupError
  }

  Write-Host "Zeyin Melody Skin for Codex is active on verified loopback port $Port."
} finally {
  if ($null -ne $operationLock) { Exit-ZeyinMelodySkinOperationLock -Mutex $operationLock }
}
