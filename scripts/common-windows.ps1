. (Join-Path $PSScriptRoot 'config-utf8.ps1')

function Enter-ZeyinMelodySkinOperationLock {
  param(
    [ValidateRange(0, 300000)]
    [int]$TimeoutMilliseconds = 0
  )
  $mutex = [System.Threading.Mutex]::new($false, 'Local\ZeyinMelodySkin.Operation')
  $acquired = $false
  try {
    $acquired = $mutex.WaitOne($TimeoutMilliseconds)
  } catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
  }
  if (-not $acquired) {
    $mutex.Dispose()
    if ($TimeoutMilliseconds -eq 0) {
      throw 'Another Zeyin Melody Skin for Codex install, start, restore, or verify operation is already running.'
    }
    throw "Another Zeyin Melody Skin for Codex operation did not finish within $TimeoutMilliseconds ms."
  }
  return $mutex
}

function Exit-ZeyinMelodySkinOperationLock {
  param([Parameter(Mandatory = $true)][System.Threading.Mutex]$Mutex)
  try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Assert-ZeyinMelodySkinPort {
  param([Parameter(Mandatory = $true)][int]$Port)
  if ($Port -lt 1024 -or $Port -gt 65535) { throw "Port must be between 1024 and 65535: $Port" }
}

function Test-ZeyinMelodySkinPathEqual {
  param([string]$Left, [string]$Right)
  if (-not $Left -or -not $Right) { return $false }
  try {
    return ([System.IO.Path]::GetFullPath($Left).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($Right).TrimEnd('\'))
  } catch {
    return $false
  }
}

function Test-ZeyinMelodySkinPathWithin {
  param([string]$Path, [string]$Root)
  if (-not $Path -or -not $Root) { return $false }
  try {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Get-ZeyinMelodySkinRuntimeEnginePaths {
  param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'ZeyinMelodySkin'))
  $root = Join-Path ([System.IO.Path]::GetFullPath($StateRoot)) 'engine'
  $scripts = Join-Path $root 'scripts'
  return [pscustomobject]@{
    Root = $root
    Scripts = $scripts
    Runtime = Join-Path $root 'runtime'
    Version = Join-Path $root 'VERSION'
    Start = Join-Path $scripts 'start-zeyin-melody.ps1'
    Restore = Join-Path $scripts 'restore-zeyin-melody.ps1'
    Tray = Join-Path $scripts 'tray-zeyin-melody.ps1'
    CheckUpdate = Join-Path $scripts 'check-update.ps1'
  }
}

function Test-ZeyinMelodySkinTrayActive {
  $mutex = [System.Threading.Mutex]::new($false, 'Local\ZeyinMelodySkin.Tray')
  $acquired = $false
  try {
    try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] {
      $acquired = $true
    }
    if ($acquired) {
      $mutex.ReleaseMutex()
      $acquired = $false
      return $false
    }
    return $true
  } finally {
    if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
  }
}

function Stop-ZeyinMelodySkinTrayProcess {
  param(
    [string[]]$ScriptPaths = @(),
    [switch]$RequireStopped
  )
  if ($ScriptPaths.Count -eq 0) {
    $ScriptPaths = @((Get-ZeyinMelodySkinRuntimeEnginePaths).Tray)
  }
  $normalized = @($ScriptPaths | ForEach-Object {
    try { [System.IO.Path]::GetFullPath($_) } catch { $null }
  } | Where-Object { $_ })
  $failures = @()
  try {
    $processes = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" `
      -ErrorAction Stop
    foreach ($process in $processes) {
      if ($process.ProcessId -eq $PID -or -not $process.CommandLine) { continue }
      $matchesTray = $false
      foreach ($scriptPath in $normalized) {
        if ($process.CommandLine.IndexOf($scriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
          $matchesTray = $true
          break
        }
      }
      if (-not $matchesTray) { continue }
      try {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        Wait-Process -Id $process.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
      } catch {
        $failures += "PID $($process.ProcessId): $($_.Exception.Message)"
      }
    }
  } catch {
    $failures += $_.Exception.Message
  }
  if ($failures.Count -gt 0) {
    $message = '无法自动关闭 Zeyin Melody 托盘：' + ($failures -join '; ')
    if ($RequireStopped) { throw $message }
    Write-Warning $message
  }
  if ($RequireStopped -and (Test-ZeyinMelodySkinTrayActive)) {
    throw 'Zeyin Melody 托盘仍在运行，请退出托盘后重试。'
  }
}

function Assert-ZeyinMelodySkinRuntimeTree {
  param([Parameter(Mandatory = $true)][string]$Path)
  $root = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Zeyin Melody 运行时目录不存在：$root"
  }
  if (-not (Get-Command Assert-ZeyinMelodySkinNoReparseComponents -ErrorAction SilentlyContinue)) {
    throw 'Zeyin Melody 受管路径校验不可用。'
  }
  Assert-ZeyinMelodySkinNoReparseComponents -Path $root
  foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop) {
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Zeyin Melody 运行时包含 junction 或符号链接：$($item.FullName)"
    }
  }
}

function Remove-ZeyinMelodySkinRuntimeTree {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$StateRoot
  )
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $fullStateRoot = [System.IO.Path]::GetFullPath($StateRoot)
  if (-not (Test-ZeyinMelodySkinPathWithin -Path $fullPath -Root $fullStateRoot)) {
    throw "拒绝删除 Zeyin Melody 状态根目录以外的运行时：$fullPath"
  }
  if (-not (Test-Path -LiteralPath $fullPath)) { return }
  Assert-ZeyinMelodySkinRuntimeTree -Path $fullPath
  Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
}

function Install-ZeyinMelodySkinRuntimeEngine {
  param(
    [Parameter(Mandatory = $true)][string]$SkillRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot
  )
  if (-not (Get-Command Ensure-ZeyinMelodySkinManagedDirectory -ErrorAction SilentlyContinue)) {
    throw 'Zeyin Melody 受管目录校验不可用。'
  }

  $sourceRoot = [System.IO.Path]::GetFullPath($SkillRoot)
  $fullStateRoot = [System.IO.Path]::GetFullPath($StateRoot)
  $engine = Get-ZeyinMelodySkinRuntimeEnginePaths -StateRoot $fullStateRoot
  $required = @(
    'VERSION',
    'assets\background.jpg',
    'assets\renderer-inject.js',
    'assets\selectors.json',
    'assets\studio-theme.css',
    'assets\structure.css',
    'assets\theme.json',
    'assets\zeyin-melody.css',
    'scripts\common-windows.ps1',
    'scripts\check-update.ps1',
    'scripts\config-utf8.ps1',
    'scripts\fixed-theme-windows.ps1',
    'scripts\image-metadata.mjs',
    'scripts\injector.mjs',
    'scripts\install-zeyin-melody.ps1',
    'scripts\legacy-preflight.ps1',
    'scripts\restore-zeyin-melody.ps1',
    'scripts\start-zeyin-melody.ps1',
    'scripts\tray-zeyin-melody.ps1',
    'scripts\verify-zeyin-melody.ps1'
  )
  $sourceHasBundledRuntime = Test-Path -LiteralPath (Join-Path $sourceRoot 'runtime') `
    -PathType Container
  if ($sourceHasBundledRuntime) {
    $required += @('runtime\node\node.exe', 'runtime\node\LICENSE')
  }
  foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $relative) -PathType Leaf)) {
      throw "Zeyin Melody 运行时源不完整：$relative"
    }
  }
  $sourceDirectories = @('assets', 'scripts')
  if ($sourceHasBundledRuntime) {
    $sourceDirectories += 'runtime'
  }
  foreach ($directoryName in $sourceDirectories) {
    $sourceDirectory = Join-Path $sourceRoot $directoryName
    if ((Test-ZeyinMelodySkinPathEqual -Left $fullStateRoot -Right $sourceDirectory) -or
      (Test-ZeyinMelodySkinPathWithin -Path $fullStateRoot -Root $sourceDirectory)) {
      throw "Zeyin Melody 状态根目录不能位于运行时源内：$fullStateRoot"
    }
    Assert-ZeyinMelodySkinRuntimeTree -Path $sourceDirectory
  }

  Ensure-ZeyinMelodySkinManagedDirectory -Path $fullStateRoot -Root $fullStateRoot
  $token = [guid]::NewGuid().ToString('N')
  $stagingRoot = Join-Path $fullStateRoot ".engine-staging-$token"
  $backupRoot = Join-Path $fullStateRoot ".engine-backup-$token"
  Ensure-ZeyinMelodySkinManagedDirectory -Path $stagingRoot -Root $fullStateRoot

  try {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination $stagingRoot `
      -Force -ErrorAction Stop
    foreach ($directoryName in $sourceDirectories) {
      Copy-Item -LiteralPath (Join-Path $sourceRoot $directoryName) -Destination $stagingRoot `
        -Recurse -Force -ErrorAction Stop
    }
    Assert-ZeyinMelodySkinRuntimeTree -Path $stagingRoot
    foreach ($relative in $required) {
      if (-not (Test-Path -LiteralPath (Join-Path $stagingRoot $relative) -PathType Leaf)) {
        throw "Staged Zeyin Melody Skin runtime is incomplete: $relative"
      }
    }

    $sourcePrefix = $sourceRoot.TrimEnd('\') + '\'
    $sourceFileRoots = @($sourceDirectories | ForEach-Object { Join-Path $sourceRoot $_ })
    $stagedFileRoots = @($sourceDirectories | ForEach-Object { Join-Path $stagingRoot $_ })
    $sourceFiles = @((Get-Item -LiteralPath (Join-Path $sourceRoot 'VERSION'))) + @(
      Get-ChildItem -LiteralPath $sourceFileRoots -Recurse -File -Force -ErrorAction Stop
    )
    $stagedFiles = @((Get-Item -LiteralPath (Join-Path $stagingRoot 'VERSION'))) + @(
      Get-ChildItem -LiteralPath $stagedFileRoots -Recurse -File -Force -ErrorAction Stop
    )
    if ($sourceFiles.Count -ne $stagedFiles.Count) {
      throw 'Staged Zeyin Melody Skin runtime file count does not match its source.'
    }
    foreach ($sourceFile in $sourceFiles) {
      $relative = $sourceFile.FullName.Substring($sourcePrefix.Length)
      $stagedFile = Join-Path $stagingRoot $relative
      if (-not (Test-Path -LiteralPath $stagedFile -PathType Leaf) -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceFile.FullName).Hash -cne
        (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedFile).Hash) {
        throw "Staged Zeyin Melody Skin runtime failed hash verification: $relative"
      }
    }

    # Unblock only verified managed copies so shortcuts can honor RemoteSigned instead of bypassing policy.
    foreach ($runtimeScript in Get-ChildItem -LiteralPath (Join-Path $stagingRoot 'scripts') `
      -Filter '*.ps1' -Recurse -File -Force -ErrorAction Stop) {
      Unblock-File -LiteralPath $runtimeScript.FullName -ErrorAction Stop
    }
    if (Test-Path -LiteralPath (Join-Path $stagingRoot 'runtime') -PathType Container) {
      foreach ($runtimeFile in Get-ChildItem -LiteralPath (Join-Path $stagingRoot 'runtime') `
        -Recurse -File -Force -ErrorAction Stop) {
        Unblock-File -LiteralPath $runtimeFile.FullName -ErrorAction Stop
      }
    }

    $hasBackup = $false
    if (Test-Path -LiteralPath $engine.Root) {
      Assert-ZeyinMelodySkinRuntimeTree -Path $engine.Root
      Move-Item -LiteralPath $engine.Root -Destination $backupRoot -ErrorAction Stop
      $hasBackup = $true
    }
    try {
      Move-Item -LiteralPath $stagingRoot -Destination $engine.Root -ErrorAction Stop
    } catch {
      $installError = $_.Exception.Message
      if ($hasBackup -and -not (Test-Path -LiteralPath $engine.Root)) {
        try {
          Move-Item -LiteralPath $backupRoot -Destination $engine.Root -ErrorAction Stop
          $hasBackup = $false
        } catch {
          throw "Zeyin Melody Skin runtime update failed and its previous engine could not be restored. Backup preserved at ${backupRoot}: $installError"
        }
      }
      throw
    }
    if ($hasBackup) {
      try { Remove-ZeyinMelodySkinRuntimeTree -Path $backupRoot -StateRoot $fullStateRoot } catch {
        try {
          Write-Warning "Installed the new runtime but could not remove its previous backup: $($_.Exception.Message)"
        } catch {
          # Cleanup must never make a committed runtime update look unsuccessful.
        }
      }
    }
    return Get-ZeyinMelodySkinRuntimeEnginePaths -StateRoot $fullStateRoot
  } finally {
    if (Test-Path -LiteralPath $stagingRoot) {
      try { Remove-ZeyinMelodySkinRuntimeTree -Path $stagingRoot -StateRoot $fullStateRoot } catch {
        try {
          Write-Warning "Could not remove the staged Zeyin Melody Skin runtime: $($_.Exception.Message)"
        } catch {
          # Cleanup must never mask the runtime installation result.
        }
      }
    }
  }
}

function Test-ZeyinMelodySkinCommandLineToken {
  param([string]$CommandLine, [string]$Token)
  if (-not $CommandLine -or -not $Token) { return $false }
  $pattern = '(?i)(?:^|[\s"])' + [regex]::Escape($Token) + '(?=$|[\s"])'
  return [regex]::IsMatch($CommandLine, $pattern)
}

function Get-ZeyinMelodySkinCodexDebugArgumentStatus {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes,
    [Parameter(Mandatory = $true)][int]$Port
  )
  Assert-ZeyinMelodySkinPort -Port $Port
  $flag = "--remote-debugging-port=$Port"
  $encodedFlag = [Uri]::EscapeDataString($flag)
  $sawReadableCommandLine = $false
  $sawProtocolRedirect = $false
  foreach ($process in $Processes) {
    $commandLine = "$($process.CommandLine)"
    if (-not $commandLine) { continue }
    $sawReadableCommandLine = $true
    $protocolPattern = '(?i)(?<!\S)"?(?<url>codex://[^\s"]*)"?'
    $protocolMatches = [regex]::Matches($commandLine, $protocolPattern)
    foreach ($protocolMatch in $protocolMatches) {
      $protocolArgument = $protocolMatch.Groups['url'].Value
      if ($protocolArgument.IndexOf($encodedFlag, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $protocolArgument.IndexOf($flag, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $sawProtocolRedirect = $true
      }
    }
    $rawArguments = [regex]::Replace($commandLine, $protocolPattern, ' ')
    if (Test-ZeyinMelodySkinCommandLineToken -CommandLine $rawArguments -Token $flag) {
      return 'forwarded'
    }
  }
  if ($sawProtocolRedirect) { return 'protocol-redirected' }
  if ($sawReadableCommandLine) { return 'not-forwarded' }
  return 'uninspectable'
}

function ConvertTo-ZeyinMelodySkinProcessArgument {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
  if ($Value.Contains('"')) { throw 'Process arguments containing a double quote are not supported.' }
  if ($Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '\s') { return $Value }
  $escaped = [regex]::Replace($Value, '(\\+)$', '$1$1')
  return '"' + $escaped + '"'
}

function ConvertTo-ZeyinMelodySkinArgumentLine {
  param([AllowEmptyCollection()][string[]]$Arguments = @())
  return (($Arguments | ForEach-Object { ConvertTo-ZeyinMelodySkinProcessArgument -Value $_ }) -join ' ')
}

function Get-ZeyinMelodySkinProcessExecutablePath {
  param([Parameter(Mandatory = $true)][object]$ProcessInfo)
  if ($ProcessInfo.ExecutablePath) { return "$($ProcessInfo.ExecutablePath)" }
  try {
    $process = Get-Process -Id ([int]$ProcessInfo.ProcessId) -ErrorAction Stop
    if ($process.Path) { return "$($process.Path)" }
    return "$($process.MainModule.FileName)"
  } catch {
    return $null
  }
}

# Windows PowerShell 5.1 promotes redirected native-command stderr lines to
# ErrorRecords; while $ErrorActionPreference is 'Stop' the first stderr line
# becomes a terminating NativeCommandError before the exit code can be read.
# Run the command with the preference relaxed and report output + exit code.
function Invoke-ZeyinMelodySkinNative {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [switch]$DiscardStderr
  )
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($DiscardStderr) {
      $nativeOutput = @(& $FilePath @ArgumentList 2>$null)
    } else {
      $nativeOutput = @(& $FilePath @ArgumentList 2>&1)
    }
    $exitCode = $LASTEXITCODE
    $output = @($nativeOutput | ForEach-Object { "$_" })
    return [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
  } finally {
    $ErrorActionPreference = $previousPreference
  }
}

function Import-ZeyinMelodySkinPowerShellSecurityModule {
  $command = Get-Command Get-AuthenticodeSignature -CommandType Cmdlet -ErrorAction SilentlyContinue
  if ($command) { return }
  try {
    Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
  } catch {
    $modulePath = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
      throw "PowerShell security module is unavailable: $($_.Exception.Message)"
    }
    Import-Module $modulePath -ErrorAction Stop
  }
  $command = Get-Command Get-AuthenticodeSignature -CommandType Cmdlet -ErrorAction SilentlyContinue
  if (-not $command) {
    throw 'PowerShell security module loaded, but Get-AuthenticodeSignature is unavailable.'
  }
}

function Assert-ZeyinMelodySkinTrustedNodeImage {
  param([Parameter(Mandatory = $true)][string]$Path)

  # Runs BEFORE the binary is ever executed. Get-ZeyinMelodySkinValidatedNodeRuntime
  # learns the version by running `node -p`, so any authenticity check placed
  # after that point would already have executed attacker-controlled code.
  Import-ZeyinMelodySkinPowerShellSecurityModule
  $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
  if ("$($signature.Status)" -ine 'Valid') {
    throw "The Node.js runtime is not validly signed: $Path ($($signature.Status))."
  }
  $subject = "$($signature.SignerCertificate.Subject)"
  # Publisher names observed on official Node.js builds. The subject is echoed
  # in the failure so an unexpected-but-legitimate publisher can be identified
  # and added deliberately, rather than the check being loosened blindly.
  if ($subject -notmatch '(?i)O=("?)(OpenJS Foundation|Node\.js Foundation|Microsoft Corporation|GitHub, Inc\.)') {
    throw "The Node.js runtime is signed by an unexpected publisher: $subject"
  }
}

function Get-ZeyinMelodySkinValidatedNodeRuntime {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$MinimumMajor = 22
  )
  $candidate = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "Node.js runtime does not exist: $candidate"
  }
  Assert-ZeyinMelodySkinTrustedNodeImage -Path $candidate
  $versionProbe = Invoke-ZeyinMelodySkinNative -FilePath $candidate -ArgumentList @('-p', 'process.versions.node') -DiscardStderr
  $version = ($versionProbe.Output -join '').Trim()
  if ($versionProbe.ExitCode -ne 0 -or -not $version) { throw 'The Node.js runtime could not be validated.' }
  $pathProbe = Invoke-ZeyinMelodySkinNative -FilePath $candidate -ArgumentList @('-p', 'process.execPath') -DiscardStderr
  $runtimePath = ($pathProbe.Output -join '').Trim()
  if ($pathProbe.ExitCode -ne 0 -or -not $runtimePath -or -not (Test-Path -LiteralPath $runtimePath)) {
    throw 'The Node.js executable path could not be validated.'
  }
  $major = 0
  if (-not [int]::TryParse(($version -split '\.')[0], [ref]$major) -or $major -lt $MinimumMajor) {
    throw "Node.js $MinimumMajor or newer is required; found $version at $runtimePath."
  }
  return [pscustomobject]@{ Path = $runtimePath; Version = $version; Major = $major }
}

function Get-ZeyinMelodySkinNodeRuntime {
  param([int]$MinimumMajor = 22)

  # 固定主题校验、图片元数据读取和注入器共用此 Node。禁止环境变量覆盖，
  # 否则普通用户可经 HKCU\Environment 把校验链指向攻击者控制的程序。
  # 安装后的引擎必须使用随包 runtime\node\node.exe；源码树仅在开发测试时
  # 回退到 PATH，并在首次执行前经过完全相同的 Authenticode 与发布者校验。
  $runtimeRoot = Split-Path -Parent $PSScriptRoot
  $bundledNode = Join-Path $runtimeRoot 'runtime\node\node.exe'
  if (Test-Path -LiteralPath $bundledNode -PathType Leaf) {
    return Get-ZeyinMelodySkinValidatedNodeRuntime -Path $bundledNode -MinimumMajor $MinimumMajor
  }

  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $command) { $command = Get-Command node -ErrorAction SilentlyContinue }
  if (-not $command) {
    throw "The bundled Node.js runtime is missing ($bundledNode) and Node.js $MinimumMajor or newer was not found in PATH."
  }
  return Get-ZeyinMelodySkinValidatedNodeRuntime -Path $command.Source -MinimumMajor $MinimumMajor
}

function ConvertTo-ZeyinMelodySkinCodexInstall {
  param(
    [Parameter(Mandatory = $true)][object]$Package,
    [AllowNull()][object]$Manifest
  )
  if ("$($Package.Name)" -ine 'OpenAI.Codex' -or -not $Package.InstallLocation -or
    -not $Package.PackageFullName -or -not $Package.PackageFamilyName -or
    "$($Package.SignatureKind)" -ine 'Store' -or [bool]$Package.IsDevelopmentMode) {
    return $null
  }
  $packageRoot = "$($Package.InstallLocation)"
  $executable = Join-Path $packageRoot 'app\ChatGPT.exe'
  if (-not (Test-Path -LiteralPath $executable)) { return $null }
  try {
    if (-not $PSBoundParameters.ContainsKey('Manifest')) {
      $Manifest = Get-AppxPackageManifest -Package $Package -ErrorAction Stop
    }
    $applications = @($Manifest.Package.Applications.Application | Where-Object {
      "$($_.Executable)".Replace('/', '\') -ieq 'app\ChatGPT.exe'
    })
    if ($applications.Count -ne 1) { return $null }
    $applicationId = "$($applications[0].Id)"
  } catch {
    return $null
  }
  $packageFamilyName = "$($Package.PackageFamilyName)"
  if ($packageFamilyName -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
    $applicationId -cnotmatch '^[A-Za-z0-9._-]{1,64}$') {
    return $null
  }
  return [pscustomobject]@{
    PackageRoot = $packageRoot
    Executable = $executable
    Version = "$($Package.Version)"
    PackageFullName = "$($Package.PackageFullName)"
    PackageFamilyName = $packageFamilyName
    ApplicationId = $applicationId
    AppUserModelId = "$packageFamilyName!$applicationId"
    SignatureKind = "$($Package.SignatureKind)"
  }
}

function Get-ZeyinMelodySkinRegisteredCodexInstalls {
  $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Sort-Object Version -Descending)
  $installs = @()
  foreach ($package in $packages) {
    $install = ConvertTo-ZeyinMelodySkinCodexInstall -Package $package
    if ($null -ne $install) { $installs += $install }
  }
  return $installs
}

function Get-ZeyinMelodySkinCodexInstall {
  $installs = @(Get-ZeyinMelodySkinRegisteredCodexInstalls)
  if ($installs.Count -eq 0) { throw 'The official OpenAI.Codex Store package is not installed or its identity cannot be validated.' }
  return $installs[0]
}

function Initialize-ZeyinMelodySkinPackageLauncher {
  if ('ZeyinMelodySkin.PackageLauncher' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ZeyinMelodySkin {
  [Flags]
  internal enum ActivateOptions : uint {
    None = 0
  }

  [ComImport]
  [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
  [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  internal interface IApplicationActivationManager {
    [PreserveSig]
    int ActivateApplication(
      [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
      [MarshalAs(UnmanagedType.LPWStr)] string arguments,
      ActivateOptions options,
      out uint processId);
  }

  [ComImport]
  [Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]
  internal class ApplicationActivationManager {}

  public static class PackageLauncher {
    public static uint Launch(string appUserModelId, string arguments) {
      var manager = (IApplicationActivationManager)new ApplicationActivationManager();
      try {
        uint processId;
        int result = manager.ActivateApplication(
          appUserModelId,
          arguments ?? string.Empty,
          ActivateOptions.None,
          out processId);
        Marshal.ThrowExceptionForHR(result);
        return processId;
      } finally {
        if (Marshal.IsComObject(manager)) Marshal.FinalReleaseComObject(manager);
      }
    }
  }
}
'@
}

function Start-ZeyinMelodySkinCodex {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][string[]]$Arguments = @()
  )
  $appUserModelId = "$($Codex.AppUserModelId)"
  if ($appUserModelId -cnotmatch '^[A-Za-z0-9._-]{1,128}![A-Za-z0-9._-]{1,64}$') {
    throw 'The registered Codex AppUserModelId is unavailable or invalid.'
  }
  Initialize-ZeyinMelodySkinPackageLauncher
  $argumentLine = ConvertTo-ZeyinMelodySkinArgumentLine -Arguments $Arguments
  $processId = [ZeyinMelodySkin.PackageLauncher]::Launch($appUserModelId, $argumentLine)
  if ($processId -le 0) { throw 'Windows did not return a Codex process ID after package activation.' }
  return $processId
}

function Assert-ZeyinMelodySkinCodexDirectLaunchTarget {
  param([Parameter(Mandatory = $true)][object]$Codex)
  $expectedExecutable = if ($Codex.PackageRoot) {
    Join-Path "$($Codex.PackageRoot)" 'app\ChatGPT.exe'
  } else {
    $null
  }
  $expectedAppUserModelId = if ($Codex.PackageFamilyName -and $Codex.ApplicationId) {
    "$($Codex.PackageFamilyName)!$($Codex.ApplicationId)"
  } else {
    $null
  }
  if ("$($Codex.SignatureKind)" -ine 'Store' -or -not $Codex.PackageFullName -or
    -not $expectedExecutable -or -not $expectedAppUserModelId -or
    "$($Codex.AppUserModelId)" -cne $expectedAppUserModelId -or
    -not (Test-ZeyinMelodySkinPathEqual -Left "$($Codex.Executable)" -Right $expectedExecutable) -or
    -not (Test-Path -LiteralPath $expectedExecutable -PathType Leaf)) {
    throw 'Direct launch requires the exact executable from the validated OpenAI.Codex Store package.'
  }
}

function Start-ZeyinMelodySkinCodexDirect {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments
  )
  Assert-ZeyinMelodySkinCodexDirectLaunchTarget -Codex $Codex
  $argumentLine = ConvertTo-ZeyinMelodySkinArgumentLine -Arguments $Arguments
  $process = Start-Process -FilePath "$($Codex.Executable)" -ArgumentList $argumentLine `
    -PassThru -ErrorAction Stop
  try {
    if ($process.Id -le 0) { throw 'Windows did not return a Codex process ID after direct launch.' }
    return $process.Id
  } finally {
    $process.Dispose()
  }
}

function Get-ZeyinMelodySkinDirectLaunchFailureKind {
  param([Parameter(Mandatory = $true)][System.Exception]$Exception)
  $current = $Exception
  while ($null -ne $current) {
    if ($current -is [System.UnauthorizedAccessException] -or
      ($current -is [System.ComponentModel.Win32Exception] -and $current.NativeErrorCode -eq 5) -or
      $current.HResult -eq -2147024891) {
      return 'access-denied'
    }
    $current = $current.InnerException
  }
  return 'start-failed'
}

function Wait-ZeyinMelodySkinCodexDebugArgumentStatus {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][int]$Port,
    [int]$TimeoutSeconds = 5
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastStatus = 'uninspectable'
  do {
    $processes = @(Get-ZeyinMelodySkinCodexProcesses -Codex $Codex)
    $lastStatus = Get-ZeyinMelodySkinCodexDebugArgumentStatus -Processes $processes -Port $Port
    if ($lastStatus -in @('forwarded', 'protocol-redirected')) { return $lastStatus }
    if ((Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
  } while ((Get-Date) -lt $deadline)
  return $lastStatus
}

function Start-ZeyinMelodySkinCodexForDebugging {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
    [Parameter(Mandatory = $true)][int]$Port,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds
  )
  $preservedProcessIds = if ($PSBoundParameters.ContainsKey('PreserveProcessIds')) {
    @($PreserveProcessIds)
  } else {
    @(Get-ZeyinMelodySkinCodexProcesses -Codex $Codex | ForEach-Object { [int]$_.ProcessId })
  }
  $packageProcessId = Start-ZeyinMelodySkinCodex -Codex $Codex -Arguments $Arguments
  $packageStatus = Wait-ZeyinMelodySkinCodexDebugArgumentStatus -Codex $Codex -Port $Port
  if ($packageStatus -ne 'protocol-redirected') {
    return [pscustomobject]@{
      ProcessId = $packageProcessId
      Strategy = 'package-activation'
      ArgumentStatus = $packageStatus
      PackageArgumentStatus = $packageStatus
    }
  }

  try {
    Stop-ZeyinMelodySkinCodex -Codex $Codex -PreserveProcessIds $preservedProcessIds -AllowForce
  } catch {
    throw "Codex package activation did not retain the CDP arguments, and its process could not be closed safely: $($_.Exception.Message)"
  }

  try {
    $directProcessId = Start-ZeyinMelodySkinCodexDirect -Codex $Codex -Arguments $Arguments
  } catch {
    $failureKind = Get-ZeyinMelodySkinDirectLaunchFailureKind -Exception $_.Exception
    throw [System.InvalidOperationException]::new(
      "Codex $($Codex.Version) converted the CDP argument into a codex:// navigation path. Direct launch of the validated Store executable failed ($failureKind), so this Codex/Windows combination cannot expose the Zeyin Melody Skin debugging endpoint without modifying the protected app package.",
      $_.Exception)
  }

  $directStatus = Wait-ZeyinMelodySkinCodexDebugArgumentStatus -Codex $Codex -Port $Port
  if ($directStatus -in @('protocol-redirected', 'not-forwarded')) {
    try {
      Stop-ZeyinMelodySkinCodex -Codex $Codex -PreserveProcessIds $preservedProcessIds -AllowForce
    } catch {
      throw "Direct Codex launch did not retain the CDP arguments and could not be closed safely: $($_.Exception.Message)"
    }
    throw "Codex $($Codex.Version) did not retain the CDP argument during package activation or validated direct launch. Zeyin Melody Skin cannot run without modifying the protected app package."
  }

  return [pscustomobject]@{
    ProcessId = $directProcessId
    Strategy = 'direct-store-executable'
    ArgumentStatus = $directStatus
    PackageArgumentStatus = $packageStatus
  }
}

function Get-ZeyinMelodySkinCodexStatePathCandidate {
  param([AllowNull()][object]$State)
  if ($null -eq $State -or -not $State.codexExe -or -not $State.codexPackageRoot) { return $null }
  $executable = "$($State.codexExe)"
  $packageRoot = "$($State.codexPackageRoot)"
  $expectedExecutable = Join-Path $packageRoot 'app\ChatGPT.exe'
  if (-not (Test-ZeyinMelodySkinPathEqual -Left $executable -Right $expectedExecutable)) { return $null }
  return [pscustomobject]@{
    PackageRoot = $packageRoot
    Executable = $executable
    Version = "$($State.codexVersion)"
    FromState = $true
    RegisteredPackageVerified = $false
  }
}

function Resolve-ZeyinMelodySkinCodexInstallFromState {
  param(
    [AllowNull()][object]$State,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$RegisteredInstalls
  )
  $candidate = Get-ZeyinMelodySkinCodexStatePathCandidate -State $State
  if ($null -eq $candidate) { return $null }

  $hasFullName = [bool]$State.codexPackageFullName
  $hasFamilyName = [bool]$State.codexPackageFamilyName
  if ($hasFullName -xor $hasFamilyName) { return $null }
  foreach ($install in $RegisteredInstalls) {
    $pathMatches = (Test-ZeyinMelodySkinPathEqual -Left $candidate.PackageRoot -Right $install.PackageRoot) -and
      (Test-ZeyinMelodySkinPathEqual -Left $candidate.Executable -Right $install.Executable)
    if (-not $pathMatches) { continue }
    if ($hasFullName -and ("$($State.codexPackageFullName)" -ine $install.PackageFullName -or
      "$($State.codexPackageFamilyName)" -ine $install.PackageFamilyName)) {
      continue
    }
    return [pscustomobject]@{
      PackageRoot = $install.PackageRoot
      Executable = $install.Executable
      Version = $install.Version
      PackageFullName = $install.PackageFullName
      PackageFamilyName = $install.PackageFamilyName
      ApplicationId = $install.ApplicationId
      AppUserModelId = $install.AppUserModelId
      SignatureKind = $install.SignatureKind
      FromState = $true
      RegisteredPackageVerified = $true
    }
  }
  return $null
}

function Get-ZeyinMelodySkinCodexInstallFromState {
  param([AllowNull()][object]$State)
  try { $installs = @(Get-ZeyinMelodySkinRegisteredCodexInstalls) } catch { return $null }
  return Resolve-ZeyinMelodySkinCodexInstallFromState -State $State -RegisteredInstalls $installs
}

function Test-ZeyinMelodySkinWebSocketUrl {
  param([string]$Value, [int]$Port)
  try {
    $uri = [Uri]$Value
    $hostName = $uri.Host.ToLowerInvariant()
    return ($uri.IsAbsoluteUri -and $uri.Scheme -eq 'ws' -and $uri.Port -eq $Port -and
      $hostName -in @('127.0.0.1', 'localhost', '::1', '[::1]') -and -not $uri.UserInfo -and
      -not $uri.Query -and -not $uri.Fragment -and
      $uri.AbsolutePath -cmatch '^/devtools/(?:page|browser)/[A-Za-z0-9._-]{1,200}$')
  } catch {
    return $false
  }
}

function Test-ZeyinMelodySkinCdpPageTarget {
  param([AllowNull()][object]$Target, [int]$Port)
  if ($null -eq $Target -or "$($Target.type)" -cne 'page' -or
    "$($Target.url)" -notlike 'app://*') {
    return $false
  }
  if ($Target.id -isnot [string]) { return $false }
  $targetId = "$($Target.id)"
  $webSocketUrl = "$($Target.webSocketDebuggerUrl)"
  if (-not (Test-ZeyinMelodySkinBrowserId -Value $targetId) -or
    -not (Test-ZeyinMelodySkinWebSocketUrl -Value $webSocketUrl -Port $Port)) {
    return $false
  }
  try {
    return ([Uri]$webSocketUrl).AbsolutePath -ceq "/devtools/page/$targetId"
  } catch {
    return $false
  }
}

function Get-ZeyinMelodySkinCdpTargets {
  param([int]$Port)
  try {
    $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 2 `
      -MaximumRedirection 0 -ErrorAction Stop
    return @($targets | Where-Object { Test-ZeyinMelodySkinCdpPageTarget -Target $_ -Port $Port })
  } catch {
    return @()
  }
}

function Test-ZeyinMelodySkinBrowserId {
  param([string]$Value)
  return [bool]($Value -and $Value.Length -le 200 -and $Value -cmatch '^[A-Za-z0-9._-]+$')
}

function Get-ZeyinMelodySkinCdpBrowserIdentity {
  param([int]$Port)
  try {
    $version = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 `
      -MaximumRedirection 0 -ErrorAction Stop
    $webSocketUrl = "$($version.webSocketDebuggerUrl)"
    if (-not (Test-ZeyinMelodySkinWebSocketUrl -Value $webSocketUrl -Port $Port)) { return $null }
    $uri = [Uri]$webSocketUrl
    $match = [regex]::Match($uri.AbsolutePath, '^/devtools/browser/(?<id>[A-Za-z0-9._-]{1,200})$')
    if (-not $match.Success -or $uri.Query -or $uri.Fragment) { return $null }
    $browserId = $match.Groups['id'].Value
    if (-not (Test-ZeyinMelodySkinBrowserId -Value $browserId)) { return $null }
    return [pscustomobject]@{
      BrowserId = $browserId
      WebSocketDebuggerUrl = $webSocketUrl
      Browser = "$($version.Browser)"
    }
  } catch {
    return $null
  }
}

function Get-ZeyinMelodySkinPortListeners {
  param([int]$Port)
  if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    throw 'Get-NetTCPConnection is required to verify CDP listener ownership.'
  }
  return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Test-ZeyinMelodySkinPortAvailable {
  param([int]$Port)
  return (Get-ZeyinMelodySkinPortListeners -Port $Port).Count -eq 0
}

function Test-ZeyinMelodySkinCodexPortOwner {
  param([int]$Port, [Parameter(Mandatory = $true)][object]$Codex)
  $listeners = Get-ZeyinMelodySkinPortListeners -Port $Port
  if ($listeners.Count -eq 0) { return $false }
  foreach ($listener in $listeners) {
    if ($listener.LocalAddress -notin @('127.0.0.1', '::1')) { return $false }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$listener.OwningProcess)" -ErrorAction SilentlyContinue
    $processPath = if ($process) { Get-ZeyinMelodySkinProcessExecutablePath -ProcessInfo $process } else { $null }
    if (-not $processPath -or -not (Test-ZeyinMelodySkinPathEqual -Left $processPath -Right $Codex.Executable)) {
      return $false
    }
  }
  return $true
}

function Get-ZeyinMelodySkinVerifiedCdpIdentity {
  param([int]$Port, [Parameter(Mandatory = $true)][object]$Codex)
  if (-not (Test-ZeyinMelodySkinCodexPortOwner -Port $Port -Codex $Codex)) { return $null }
  $browser = Get-ZeyinMelodySkinCdpBrowserIdentity -Port $Port
  if ($null -eq $browser) { return $null }
  $targets = Get-ZeyinMelodySkinCdpTargets -Port $Port
  if ($targets.Count -eq 0) { return $null }
  if (-not (Test-ZeyinMelodySkinCodexPortOwner -Port $Port -Codex $Codex)) { return $null }
  return [pscustomobject]@{
    BrowserId = $browser.BrowserId
    BrowserWebSocketDebuggerUrl = $browser.WebSocketDebuggerUrl
    Browser = $browser.Browser
    TargetCount = $targets.Count
  }
}

function Test-ZeyinMelodySkinCodexCdpEndpoint {
  param([int]$Port, [Parameter(Mandatory = $true)][object]$Codex)
  return $null -ne (Get-ZeyinMelodySkinVerifiedCdpIdentity -Port $Port -Codex $Codex)
}

function Get-ZeyinMelodySkinVerifiedCdpIdentityForAnyRegistered {
  # A Store auto-update replaces the "current" package directory while the
  # older version keeps running and owning the verified endpoint.  Accepting
  # any registered OpenAI.Codex install keeps the strict owner validation
  # (every candidate passed the same package identity checks) without
  # restarting a healthy skinned Codex just because the Store updated.
  param([int]$Port)
  foreach ($install in @(Get-ZeyinMelodySkinRegisteredCodexInstalls)) {
    $identity = Get-ZeyinMelodySkinVerifiedCdpIdentity -Port $Port -Codex $install
    if ($null -ne $identity) {
      return [pscustomobject]@{
        Identity = $identity
        Codex = $install
      }
    }
  }
  return $null
}

function Select-ZeyinMelodySkinPort {
  param([int]$PreferredPort)
  for ($candidate = $PreferredPort; $candidate -le [Math]::Min(65535, $PreferredPort + 100); $candidate++) {
    if (Test-ZeyinMelodySkinPortAvailable -Port $candidate) { return $candidate }
  }
  throw "No free loopback port was found between $PreferredPort and $([Math]::Min(65535, $PreferredPort + 100))."
}

function Wait-ZeyinMelodySkinPortAvailable {
  param([int]$Port, [int]$TimeoutSeconds = 5)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    if (Test-ZeyinMelodySkinPortAvailable -Port $Port) { return $true }
    Start-Sleep -Milliseconds 200
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Read-ZeyinMelodySkinState {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $state = (Read-ZeyinMelodySkinUtf8File -Path $Path) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $state -or $state -is [string] -or $state -is [array]) { throw 'State root must be an object.' }
    $properties = @($state.PSObject.Properties.Name)
    if ($properties -contains 'platform' -and "$($state.platform)" -ine 'windows') {
      throw 'State platform is not Windows.'
    }
    $schemaVersion = 1
    if ($properties -contains 'schemaVersion') {
      $schemaVersion = 0
      if (-not [int]::TryParse("$($state.schemaVersion)", [ref]$schemaVersion) -or
        $schemaVersion -lt 1 -or $schemaVersion -gt 3) {
        throw 'State schema is not supported.'
      }
    }
    if ($schemaVersion -ge 3) {
      foreach ($required in @(
        'platform', 'port', 'injectorPid', 'injectorStartedAt', 'injectorPath', 'nodePath',
        'codexExe', 'codexPackageRoot', 'codexPackageFullName', 'codexPackageFamilyName', 'browserId'
      )) {
        if ($properties -notcontains $required -or -not $state.$required) {
          throw "State schema 3 is missing required field: $required"
        }
      }
    }
    if ($properties -contains 'port') {
      $statePort = 0
      if (-not [int]::TryParse("$($state.port)", [ref]$statePort)) { throw 'State port is invalid.' }
      Assert-ZeyinMelodySkinPort -Port $statePort
    }
    if ($properties -contains 'injectorPid' -and $null -ne $state.injectorPid) {
      $statePid = 0
      if (-not [int]::TryParse("$($state.injectorPid)", [ref]$statePid) -or $statePid -le 0) {
        throw 'State injector PID is invalid.'
      }
    }
    if ($properties -contains 'browserId' -and $state.browserId -and
      -not (Test-ZeyinMelodySkinBrowserId -Value "$($state.browserId)")) {
      throw 'State browser ID is invalid.'
    }
    return $state
  } catch {
    throw "Zeyin Melody Skin state is unreadable; it was preserved for inspection: $Path"
  }
}

function Write-ZeyinMelodySkinState {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$State)
  $json = $State | ConvertTo-Json -Depth 6
  Write-ZeyinMelodySkinUtf8FileAtomically -Path $Path -Content ($json + "`r`n")
}

function Archive-ZeyinMelodySkinStateFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $archivePath = Join-Path $directory "state.stale-$stamp-$([guid]::NewGuid().ToString('N')).json"
  Move-Item -LiteralPath $Path -Destination $archivePath -ErrorAction Stop
  return $archivePath
}

function Get-ZeyinMelodySkinProcessStartedAt {
  param([int]$ProcessId)
  try {
    return (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
  } catch {
    return $null
  }
}

function Stop-ZeyinMelodySkinRecordedInjector {
  param([AllowNull()][object]$State)
  if ($null -eq $State -or -not $State.injectorPid) { return $true }
  $processId = [int]$State.injectorPid
  $processHandle = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if (-not $processHandle) { return $true }
  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
  if (-not $process) {
    if ($processHandle.HasExited) { return $true }
    throw "The recorded injector PID $processId is running, but its identity cannot be inspected. State was preserved."
  }

  $expectedInjector = if ($State.injectorPath) {
    "$($State.injectorPath)"
  } elseif ($State.skillRoot) {
    Join-Path "$($State.skillRoot)" 'scripts\injector.mjs'
  } else {
    $null
  }
  $processPath = Get-ZeyinMelodySkinProcessExecutablePath -ProcessInfo $process
  $commandLine = "$($process.CommandLine)"
  if (-not $processPath -or -not $commandLine) {
    throw "The recorded injector PID $processId is running, but its identity cannot be inspected. State was preserved."
  }
  $isNodeExecutable = [System.IO.Path]::GetFileName("$processPath") -ieq 'node.exe'
  $nodeMatches = -not $State.nodePath -or
    (Test-ZeyinMelodySkinPathEqual -Left $processPath -Right "$($State.nodePath)")
  $injectorMatches = [bool]($expectedInjector -and
    (Test-ZeyinMelodySkinCommandLineToken -CommandLine $commandLine -Token $expectedInjector) -and
    (Test-ZeyinMelodySkinCommandLineToken -CommandLine $commandLine -Token '--watch'))
  if ($State.port) {
    $portPattern = '(?i)(?:^|\s)--port(?:=|\s+)' + [regex]::Escape("$($State.port)") + '(?=$|\s)'
    $injectorMatches = $injectorMatches -and [regex]::IsMatch($commandLine, $portPattern)
  } else {
    $injectorMatches = $false
  }
  if ($State.browserId) {
    $browserPattern = '(?:^|\s)(?i:--browser-id)(?:=|\s+)' + [regex]::Escape("$($State.browserId)") + '(?=$|\s)'
    $injectorMatches = $injectorMatches -and [regex]::IsMatch($commandLine, $browserPattern)
  }
  try {
    $startedAt = $processHandle.StartTime.ToUniversalTime().ToString('o')
  } catch {
    if ($processHandle.HasExited) { return $true }
    throw "The recorded injector PID $processId is running, but its start time cannot be inspected. State was preserved."
  }
  $startMatches = -not $State.injectorStartedAt -or $startedAt -eq "$($State.injectorStartedAt)"
  $identityMatches = [bool]($isNodeExecutable -and $nodeMatches -and $injectorMatches -and $startMatches)

  if (-not $identityMatches) {
    throw "The recorded injector PID $processId is running, but its visible identity does not match the saved Zeyin Melody Skin process. State was preserved."
  }

  Stop-Process -InputObject $processHandle -Force -ErrorAction Stop
  [void]$processHandle.WaitForExit(15000)
  if (-not $processHandle.HasExited) {
    throw "The recorded Zeyin Melody Skin injector did not stop: PID $processId"
  }
  return $true
}

function Get-ZeyinMelodySkinCodexProcesses {
  param([Parameter(Mandatory = $true)][object]$Codex)
  return @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $processPath = Get-ZeyinMelodySkinProcessExecutablePath -ProcessInfo $_
      Test-ZeyinMelodySkinPathEqual -Left $processPath -Right $Codex.Executable
    })
}

function Get-ZeyinMelodySkinCodexProcessesExcept {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds = @()
  )
  $preserved = @{}
  foreach ($processId in $PreserveProcessIds) {
    if ($processId -gt 0) { $preserved[$processId] = $true }
  }
  return @(
    Get-ZeyinMelodySkinCodexProcesses -Codex $Codex | Where-Object {
      -not $preserved.ContainsKey([int]$_.ProcessId)
    }
  )
}

function Stop-ZeyinMelodySkinCodex {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds = @(),
    [switch]$AllowForce
  )
  $processes = Get-ZeyinMelodySkinCodexProcessesExcept -Codex $Codex -PreserveProcessIds $PreserveProcessIds
  if ($processes.Count -eq 0) { return }
  foreach ($item in $processes) {
    try { [void](Get-Process -Id $item.ProcessId -ErrorAction Stop).CloseMainWindow() } catch {}
  }

  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-ZeyinMelodySkinCodexProcessesExcept -Codex $Codex `
      -PreserveProcessIds $PreserveProcessIds).Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
  }
  $remaining = Get-ZeyinMelodySkinCodexProcessesExcept -Codex $Codex -PreserveProcessIds $PreserveProcessIds
  if ($remaining.Count -eq 0) { return }
  if (-not $AllowForce) {
    throw 'Codex did not close within 15 seconds. Close it manually or explicitly authorize a forced restart.'
  }
  foreach ($item in $remaining) {
    $current = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$item.ProcessId)" -ErrorAction SilentlyContinue
    $currentPath = if ($current) { Get-ZeyinMelodySkinProcessExecutablePath -ProcessInfo $current } else { $null }
    if ($currentPath -and (Test-ZeyinMelodySkinPathEqual -Left $currentPath -Right $Codex.Executable)) {
      Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
  Start-Sleep -Milliseconds 500
  if ((Get-ZeyinMelodySkinCodexProcessesExcept -Codex $Codex `
      -PreserveProcessIds $PreserveProcessIds).Count -gt 0) {
    throw 'Codex could not be stopped safely.'
  }
}

function Confirm-ZeyinMelodySkinRestart {
  param([string]$Message)
  $shell = New-Object -ComObject WScript.Shell
  return $shell.Popup($Message, 0, 'Zeyin Melody Skin for Codex', 52) -eq 6
}

function Invoke-ZeyinMelodySkinCodexWindowActivation {
  param([Parameter(Mandatory = $true)][object]$Codex)
  $processes = @(Get-ZeyinMelodySkinCodexProcesses -Codex $Codex)
  if ($processes.Count -eq 0) { return $false }
  $shell = New-Object -ComObject WScript.Shell
  foreach ($process in $processes) {
    try {
      if ($shell.AppActivate([int]$process.ProcessId)) { return $true }
    } catch {}
  }
  return $false
}
