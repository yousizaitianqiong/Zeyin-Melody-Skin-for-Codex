[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $nodeCommand) { $nodeCommand = Get-Command node -ErrorAction Stop }
$node = $nodeCommand.Source

function Invoke-ZeyinTestCommand {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$Label
  )
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Label 失败，退出码 $LASTEXITCODE。" }
}

Push-Location $repositoryRoot
try {
  foreach ($script in @(
    'scripts\image-metadata.mjs',
    'scripts\injector.mjs',
    'assets\renderer-inject.js',
    'tests\static-contracts.test.mjs',
    'tests\renderer-runtime.test.mjs',
    'tests\renderer-inject.test.mjs'
  )) {
    Invoke-ZeyinTestCommand -FilePath $node -Arguments @('--check', $script) `
      -Label "JavaScript 语法检查 $script"
  }
  Invoke-ZeyinTestCommand -FilePath $node -Arguments @('--test', 'tests\static-contracts.test.mjs') `
    -Label '静态身份与安全回归'
  Invoke-ZeyinTestCommand -FilePath $node -Arguments @('tests\renderer-inject.test.mjs') `
    -Label 'renderer 26.803 与 cleanup 夹具'
  Invoke-ZeyinTestCommand -FilePath $node -Arguments @('scripts\injector.mjs', '--self-test') `
    -Label 'loopback CDP 自检'
  Invoke-ZeyinTestCommand -FilePath $node -Arguments @('scripts\injector.mjs', '--check-payload') `
    -Label '固定负载自检'
  Invoke-ZeyinTestCommand -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source `
    -Arguments @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File',
      (Join-Path $PSScriptRoot 'powershell-contracts.ps1')) `
    -Label 'Windows PowerShell 5.1 回归'
  Write-Host 'PASS: Zeyin Melody Skin for Codex Windows 全套回归。'
} finally {
  Pop-Location
}
