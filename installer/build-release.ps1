[CmdletBinding()]
param(
  [string]$OutputDirectory,
  [string]$IsccPath,
  [string]$NodeArchivePath,
  [string]$WorkingDirectory,
  [switch]$KeepWorkingDirectory,
  [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$installerRoot = $PSScriptRoot
$repositoryRoot = Split-Path -Parent $installerRoot
$manifestPath = Join-Path $installerRoot 'node-runtime.json'
$definitionPath = Join-Path $installerRoot 'zeyin-melody-skin.iss'
$bootstrapPath = Join-Path $installerRoot 'setup-bootstrap.ps1'
$versionPath = Join-Path $repositoryRoot 'VERSION'
$licensePath = Join-Path $repositoryRoot 'LICENSE'
$noticePath = Join-Path $repositoryRoot 'NOTICE.md'
$assetsRoot = Join-Path $repositoryRoot 'assets'
$scriptsRoot = Join-Path $repositoryRoot 'scripts'
$testRunnerPath = Join-Path $repositoryRoot 'tests\run-tests.ps1'
$languageRoot = Join-Path $installerRoot 'languages'
$chineseLanguagePath = Join-Path $languageRoot 'ChineseSimplified.isl'
$innoLicensePath = Join-Path $languageRoot 'Inno-Setup-License.txt'
$chineseLanguageSha256 = '7D544B9BB1D142CFA11F2E5D3CC8ABE2E55F8E066C5124E3772675AA236E1278'
$innoLicenseSha256 = '0C81595601BCE47EEEF8D865D5DA7F9CA2C6A12235B7482B29F5AB23ED02EE5A'
$iconSha256 = '1940C2DA11194C7265152C273679FD03C2699873ED22FC5E5CC21F598F5FB2F7'
$studioHashes = @{
  'background.jpg' = '0B8744ED2C02D1B7322B8D9E478EA674F5726EDDE617861E8C49D49533EDD388'
  'studio-theme.css' = 'F9C23D29E8ACD1BE78E156E011F83AB84E0D90879B30B003E289A170BB77D409'
  'theme.json' = 'D67B6BC4DAD83F3C971D401CD0CDB7B45B8B8E8A128AB6916E07C451131196D0'
}

function Read-ZeyinMelodyReleaseText {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "缺少发布输入：$Path"
  }
  return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

function Resolve-ZeyinMelodyReleasePath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$BasePath
  )
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Assert-ZeyinMelodyReleaseTree {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "缺少发布目录：$Path"
  }
  foreach ($item in @((Get-Item -LiteralPath $Path -Force)) +
      @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "发布输入不得包含 junction 或符号链接：$($item.FullName)"
    }
  }
}

function Copy-ZeyinMelodyReleaseTree {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  Assert-ZeyinMelodyReleaseTree -Path $Source
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
    Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop
  }
}

function Assert-ZeyinMelodyNodeManifest {
  param([Parameter(Mandatory = $true)][object]$Manifest)
  $expectedVersion = '22.23.1'
  $expectedArchive = "node-v$expectedVersion-win-x64.zip"
  $expectedRoot = "node-v$expectedVersion-win-x64"
  $expectedUrl = "https://nodejs.org/dist/v$expectedVersion/$expectedArchive"
  $expectedHash = '7df0bc9375723f4a86b3aa1b7cc73342423d9677a8df4538aca31a049e309c29'
  if ("$($Manifest.version)" -cne $expectedVersion -or
    "$($Manifest.platform)" -cne 'win' -or
    "$($Manifest.architecture)" -cne 'x64' -or
    "$($Manifest.archive)" -cne $expectedArchive -or
    "$($Manifest.url)" -cne $expectedUrl -or
    "$($Manifest.sha256)" -cne $expectedHash -or
    "$($Manifest.nodeEntry)" -cne "$expectedRoot/node.exe" -or
    "$($Manifest.licenseEntry)" -cne "$expectedRoot/LICENSE") {
    throw 'Node.js 固定运行时清单不符合已审阅的 v22.23.1 win-x64 合同。'
  }
}

function Resolve-ZeyinMelodyIscc {
  param([string]$RequestedPath)
  $candidates = @()
  if ($RequestedPath) { $candidates += $RequestedPath }
  if (${env:ProgramFiles(x86)}) {
    $candidates += Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
  }
  if ($env:ProgramFiles) {
    $candidates += Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'
  }
  if ($env:LOCALAPPDATA) {
    $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
  }
  if ($env:ChocolateyInstall) {
    $candidates += Join-Path $env:ChocolateyInstall 'bin\iscc.exe'
  }
  $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($command) { $candidates += $command.Source }
  foreach ($candidate in $candidates) {
    if (-not $candidate) { continue }
    $resolved = Resolve-ZeyinMelodyReleasePath -Path $candidate -BasePath $repositoryRoot
    if (Test-Path -LiteralPath $resolved -PathType Leaf) { return $resolved }
  }
  throw '未找到 Inno Setup 6 编译器 ISCC.exe；请安装 Inno Setup 6 或传入 -IsccPath。'
}

function Copy-ZeyinMelodyZipEntry {
  param(
    [Parameter(Mandatory = $true)][object]$Archive,
    [Parameter(Mandatory = $true)][string]$EntryName,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  $entry = $Archive.GetEntry($EntryName)
  if ($null -eq $entry -or $entry.Length -le 0) {
    throw "Node.js 压缩包缺少非空条目：$EntryName"
  }
  New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
  $input = $entry.Open()
  try {
    $output = [System.IO.File]::Open(
      $Destination,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )
    try { $input.CopyTo($output) } finally { $output.Dispose() }
  } finally {
    $input.Dispose()
  }
}

function Receive-ZeyinMelodyPinnedArchive {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  $fullDestination = [System.IO.Path]::GetFullPath($Destination)
  $directory = Split-Path -Parent $fullDestination
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    throw "Node.js 下载目录不存在：$directory"
  }
  if (Test-Path -LiteralPath $fullDestination) {
    $existing = Get-Item -LiteralPath $fullDestination -Force
    if ($existing.PSIsContainer) { throw "Node.js 下载目标不是文件：$fullDestination" }
    [System.IO.File]::Delete($fullDestination)
  }

  $temporary = $fullDestination + '.download-' + [guid]::NewGuid().ToString('N') + '.tmp'
  try {
    $systemCurl = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\curl.exe' } else { $null }
    $trustedCurl = $false
    if ($systemCurl -and (Test-Path -LiteralPath $systemCurl -PathType Leaf)) {
      $curlSignature = Get-AuthenticodeSignature -LiteralPath $systemCurl
      $trustedCurl = $curlSignature.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and
        $curlSignature.SignerCertificate.Subject -match 'Microsoft Corporation'
    }
    if ($trustedCurl) {
      & $systemCurl @(
        '-4', '--fail', '--location', '--silent', '--show-error',
        '--proto', '=https', '--proto-redir', '=https',
        '--tlsv1.2', '--tls-max', '1.2', '--http1.1', '--ssl-no-revoke',
        '--connect-timeout', '15', '--max-time', '300',
        '--output', $temporary, $Uri
      )
      $curlExitCode = $LASTEXITCODE
      if ($curlExitCode -ne 0) {
        throw "curl 下载固定 Node.js 运行时失败，退出码 $curlExitCode。可传入经 SHA-256 验证的 -NodeArchivePath。"
      }
    } else {
      $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
      try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri $Uri -OutFile $temporary
      } finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
      }
    }
    if (-not (Test-Path -LiteralPath $temporary -PathType Leaf) -or
      (Get-Item -LiteralPath $temporary).Length -le 0) {
      throw '固定 Node.js 运行时下载结果为空；拒绝缓存或复用零字节文件。'
    }
    [System.IO.File]::Move($temporary, $fullDestination)
  } finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
      [System.IO.File]::Delete($temporary)
    }
  }
}

function Write-ZeyinMelodyChecksumAtomically {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Content
  )
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $directory = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    throw "校验清单目录不存在：$directory"
  }
  $token = [guid]::NewGuid().ToString('N')
  $temporary = Join-Path $directory ('.SHA256SUMS-' + $token + '.tmp')
  $backup = Join-Path $directory ('.SHA256SUMS-' + $token + '.bak')
  try {
    [System.IO.File]::WriteAllText($temporary, $Content, [System.Text.Encoding]::ASCII)
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
      [System.IO.File]::Replace($temporary, $fullPath, $backup)
      [System.IO.File]::Delete($backup)
    } else {
      [System.IO.File]::Move($temporary, $fullPath)
    }
  } finally {
    if (Test-Path -LiteralPath $temporary) { [System.IO.File]::Delete($temporary) }
    if (Test-Path -LiteralPath $backup) { [System.IO.File]::Delete($backup) }
  }
}

$version = (Read-ZeyinMelodyReleaseText -Path $versionPath).Trim()
if ($version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
  throw "VERSION 必须是三段语义版本：$version"
}
if ($version -cne '0.1.0') { throw "本发布分支只允许构建 0.1.0，实际为 $version。" }

$manifest = (Read-ZeyinMelodyReleaseText -Path $manifestPath) | ConvertFrom-Json
Assert-ZeyinMelodyNodeManifest -Manifest $manifest
$null = Read-ZeyinMelodyReleaseText -Path $definitionPath
$null = Read-ZeyinMelodyReleaseText -Path $bootstrapPath
$null = Read-ZeyinMelodyReleaseText -Path $licensePath
$null = Read-ZeyinMelodyReleaseText -Path $noticePath
$null = Read-ZeyinMelodyReleaseText -Path $chineseLanguagePath
$null = Read-ZeyinMelodyReleaseText -Path $innoLicensePath
if ((Get-FileHash -LiteralPath $chineseLanguagePath -Algorithm SHA256).Hash -cne $chineseLanguageSha256 -or
  (Get-FileHash -LiteralPath $innoLicensePath -Algorithm SHA256).Hash -cne $innoLicenseSha256) {
  throw '固定的 Inno Setup 简体中文资源或许可文本发生变化。'
}
if ((Get-FileHash -LiteralPath (Join-Path $assetsRoot 'zeyin-melody-skin.ico') -Algorithm SHA256).Hash -cne $iconSha256) {
  throw '应用图标与已审阅资源不一致。'
}
foreach ($relative in $studioHashes.Keys) {
  $actual = (Get-FileHash -LiteralPath (Join-Path $assetsRoot $relative) -Algorithm SHA256).Hash
  if ($actual -cne $studioHashes[$relative]) {
    throw "Studio 固定资源 SHA-256 不匹配：assets\$relative"
  }
}
$theme = (Read-ZeyinMelodyReleaseText -Path (Join-Path $assetsRoot 'theme.json')) | ConvertFrom-Json
if ("$($theme.id)" -cne 'zeyin-melody' -or "$($theme.image)" -cne 'background.jpg' -or
  "$($theme.promoUrl)" -cne 'https://github.com/yousizaitianqiong/Zeyin-Melody-Skin-for-Codex') {
  throw '固定主题元数据身份无效。'
}

if (-not $SkipTests) {
  if (-not (Test-Path -LiteralPath $testRunnerPath -PathType Leaf)) { throw '缺少测试入口 tests\run-tests.ps1。' }
  & powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File $testRunnerPath
  if ($LASTEXITCODE -ne 0) { throw "回归测试失败，退出码 $LASTEXITCODE。" }
}

$compiler = Resolve-ZeyinMelodyIscc -RequestedPath $IsccPath
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repositoryRoot 'dist' }
$OutputDirectory = Resolve-ZeyinMelodyReleasePath -Path $OutputDirectory -BasePath $repositoryRoot
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$createdWorkingDirectory = $false
if ($WorkingDirectory) {
  $WorkingDirectory = Resolve-ZeyinMelodyReleasePath -Path $WorkingDirectory -BasePath $repositoryRoot
  if (Test-Path -LiteralPath $WorkingDirectory) {
    throw "指定的构建工作目录已存在：$WorkingDirectory"
  }
  New-Item -ItemType Directory -Path $WorkingDirectory | Out-Null
  $createdWorkingDirectory = $true
} else {
  $WorkingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
    'zeyin-melody-windows-release-' + [guid]::NewGuid().ToString('N')
  )
  New-Item -ItemType Directory -Path $WorkingDirectory | Out-Null
  $createdWorkingDirectory = $true
}

try {
  $archivePath = if ($NodeArchivePath) {
    Resolve-ZeyinMelodyReleasePath -Path $NodeArchivePath -BasePath $repositoryRoot
  } else {
    Join-Path $WorkingDirectory "$($manifest.archive)"
  }
  if (-not $NodeArchivePath) {
    Write-Host "下载固定 Node.js v$($manifest.version) win-x64 运行时（连接 15 秒、总计 300 秒超时）……"
    Receive-ZeyinMelodyPinnedArchive -Uri "$($manifest.url)" -Destination $archivePath
  }
  if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Node.js 压缩包不存在：$archivePath"
  }
  $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
  if ($archiveHash -cne "$($manifest.sha256)".ToUpperInvariant()) {
    throw "Node.js 压缩包 SHA-256 不匹配：$archiveHash"
  }

  $stageRoot = Join-Path $WorkingDirectory 'stage'
  $payloadRoot = Join-Path $stageRoot 'payload'
  $stagedLanguageRoot = Join-Path $stageRoot 'languages'
  New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $stagedLanguageRoot -Force | Out-Null
  Copy-ZeyinMelodyReleaseTree -Source $assetsRoot -Destination (Join-Path $payloadRoot 'assets')
  Copy-ZeyinMelodyReleaseTree -Source $scriptsRoot -Destination (Join-Path $payloadRoot 'scripts')
  Copy-Item -LiteralPath $versionPath -Destination (Join-Path $payloadRoot 'VERSION') -Force
  Copy-Item -LiteralPath $bootstrapPath -Destination (Join-Path $stageRoot 'setup-bootstrap.ps1') -Force
  Copy-Item -LiteralPath $licensePath -Destination (Join-Path $stageRoot 'LICENSE.txt') -Force
  Copy-Item -LiteralPath $noticePath -Destination (Join-Path $stageRoot 'NOTICE.md') -Force
  Copy-Item -LiteralPath $chineseLanguagePath -Destination (Join-Path $stagedLanguageRoot 'ChineseSimplified.isl') -Force

  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
  try {
    Copy-ZeyinMelodyZipEntry -Archive $zip -EntryName "$($manifest.nodeEntry)" `
      -Destination (Join-Path $payloadRoot 'runtime\node\node.exe')
    Copy-ZeyinMelodyZipEntry -Archive $zip -EntryName "$($manifest.licenseEntry)" `
      -Destination (Join-Path $payloadRoot 'runtime\node\LICENSE')
  } finally {
    $zip.Dispose()
  }

  $requiredPayload = @(
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
  foreach ($relative in $requiredPayload) {
    if (-not (Test-Path -LiteralPath (Join-Path $payloadRoot $relative) -PathType Leaf)) {
      throw "安装器负载不完整：$relative"
    }
  }
  foreach ($relative in $studioHashes.Keys) {
    $stagedHash = (Get-FileHash -LiteralPath (Join-Path (Join-Path $payloadRoot 'assets') $relative) -Algorithm SHA256).Hash
    if ($stagedHash -cne $studioHashes[$relative]) { throw "暂存 Studio 资源改变：$relative" }
  }

  $arguments = @(
    "/DAppVersion=$version",
    "/DStageRoot=$stageRoot",
    "/DOutputDir=$OutputDirectory",
    $definitionPath
  )
  Write-Host "构建 ZeyinMelodySkin-Setup-v$version.exe……"
  & $compiler @arguments
  if ($LASTEXITCODE -ne 0) { throw "ISCC.exe 失败，退出码 $LASTEXITCODE。" }
  $artifactPath = Join-Path $OutputDirectory "ZeyinMelodySkin-Setup-v$version.exe"
  if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
    throw "Inno Setup 未生成预期安装器：$artifactPath"
  }
  $artifactHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
  $artifactName = [System.IO.Path]::GetFileName($artifactPath)
  $checksumPath = Join-Path $OutputDirectory 'SHA256SUMS.txt'
  Write-ZeyinMelodyChecksumAtomically -Path $checksumPath `
    -Content ($artifactHash + '  ' + $artifactName + "`n")
  $checksumText = [System.Text.Encoding]::ASCII.GetString(
    [System.IO.File]::ReadAllBytes($checksumPath))
  $checksumMatch = [regex]::Match(
    $checksumText,
    '\A(?<hash>[A-Fa-f0-9]{64})  (?<name>ZeyinMelodySkin-Setup-v0\.1\.0\.exe)\n\z'
  )
  if (-not $checksumMatch.Success -or
    $checksumMatch.Groups['hash'].Value.ToUpperInvariant() -cne $artifactHash -or
    $checksumMatch.Groups['name'].Value -cne $artifactName -or
    (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash -cne $artifactHash) {
    throw 'SHA256SUMS.txt 无法重解析，或与安装器实际 SHA-256 不一致。'
  }
  Write-Host "Windows 安装器：$artifactPath"
  Write-Host "SHA-256：$artifactHash"
  Write-Host "校验清单：$checksumPath"
} finally {
  if ($createdWorkingDirectory -and -not $KeepWorkingDirectory -and
    (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
    $fullWorking = [System.IO.Path]::GetFullPath($WorkingDirectory).TrimEnd('\')
    $repository = [System.IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\')
    if ($fullWorking.Length -lt 20 -or $fullWorking.Equals($repository, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "拒绝清理异常构建工作目录：$fullWorking"
    }
    Remove-Item -LiteralPath $fullWorking -Recurse -Force -ErrorAction Stop
  } elseif ($KeepWorkingDirectory) {
    Write-Host "保留构建工作目录：$WorkingDirectory"
  }
}
