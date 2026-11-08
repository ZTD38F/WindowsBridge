Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$html = Get-Content -LiteralPath (Join-Path $root "pages/index.html") -Raw
$match = [regex]::Match($html,'<code id="install-command"[^>]*>(.*?)</code>','Singleline')
if (-not $match.Success) { throw "Installer copy command was not found." }
$launcher = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value.Trim())
$expectedSource = "https://raw.githubusercontent.com/ZTD38F/WindowsBridge/stable/install.ps1"
if ($launcher -notmatch [regex]::Escape($expectedSource)) { throw "Launcher does not use stable." }
if ($launcher -match '/main/install\.ps1') { throw "Launcher points to dev/main." }
$command = [regex]::Match($launcher,'^powershell\.exe -NoProfile -ExecutionPolicy Bypass -Command "(.+)"$')
if (-not $command.Success) { throw "Launcher is not a standalone Win+R PowerShell command." }
$inner = $command.Groups[1].Value
$tokens = $null; $parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseInput($inner,[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count) { throw "Launcher has PowerShell parser errors." }

# Safely simulate the exact copied command without network access or installing.
$originalTemp = $env:TEMP
$testDir = Join-Path ([IO.Path]::GetTempPath()) ("WindowsBridge-launcher-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $testDir | Out-Null
$script:requested = $false
function Invoke-WebRequest {
  [CmdletBinding()]
  param([Parameter(Position=0)][string]$Uri,[switch]$UseBasicParsing,[string]$OutFile)
  if ($Uri -ne $expectedSource) { throw "Unexpected source URL: $Uri" }
  if (-not $UseBasicParsing) { throw "Missing PowerShell 5.1 compatibility flag." }
  if (-not $OutFile.StartsWith($testDir,[StringComparison]::OrdinalIgnoreCase)) {
    throw "Installer file was written outside the isolated temp path."
  }
  $script:requested = $true
  Set-Content -LiteralPath $OutFile -Value 'Write-Output "WindowsBridge launcher mock PASS"' -Encoding ASCII
}
try {
  $env:TEMP = $testDir
  $result = & ([scriptblock]::Create($inner))
  if (-not $script:requested) { throw "Mocked download did not run." }
  if (($result | Out-String).Trim() -ne "WindowsBridge launcher mock PASS") {
    throw "Launcher did not execute the downloaded fixture correctly."
  }
} finally {
  $env:TEMP = $originalTemp
  Remove-Item -LiteralPath $testDir -Force -Recurse -ErrorAction SilentlyContinue
}
Write-Host "WindowsBridge Win+R launcher real PowerShell parsing + mocked E2E PASS."
