#requires -Version 5.1
<#
Secure one-line launcher for Windows 11 Upgrade Manager.
Fetches source from the GitHub repository's content API, checks Git's blob digest,
then launches it as a saved script (never Invoke-Expression).
#>
$ErrorActionPreference = 'Stop'
$owner = 'ZTD38F'
$repository = 'WindowsBridge'
$path = 'tools/windows11-upgrade/Win11Upgrade.ps1'
try {
    $uri = "https://api.github.com/repos/$owner/$repository/contents/$path" + '?ref=main'
    $meta = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'Win11UpgradeManager' } -TimeoutSec 20
    if ($meta.type -ne 'file' -or -not $meta.content -or $meta.encoding -ne 'base64') {
        throw 'GitHub did not return a valid script file.'
    }
    $bytes = [Convert]::FromBase64String(($meta.content -replace '\s',''))
    if ($bytes.Length -lt 6000 -or $bytes.Length -gt 200000) { throw 'Unexpected script size.' }
    $header = [Text.Encoding]::ASCII.GetBytes(('blob {0}' -f $bytes.Length) + [char]0)
    $mem = New-Object System.IO.MemoryStream
    try {
        $mem.Write($header, 0, $header.Length)
        $mem.Write($bytes, 0, $bytes.Length)
        $sha1 = [System.Security.Cryptography.SHA1]::Create()
        try { $actual = [BitConverter]::ToString($sha1.ComputeHash($mem.ToArray())).Replace('-','').ToLowerInvariant() }
        finally { $sha1.Dispose() }
    } finally { $mem.Dispose() }
    if ($actual -ne [string]$meta.sha) { throw 'Git blob SHA mismatch. Launch refused.' }
    $dir = Join-Path $env:TEMP 'Win11UpgradeManager'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $file = Join-Path $dir ('Win11Upgrade-' + $actual.Substring(0,12) + '.ps1')
    [System.IO.File]::WriteAllBytes($file, $bytes)
    Write-Host ('  Verified Windows 11 Upgrade Manager | Git SHA ' + $actual.Substring(0,12)) -ForegroundColor Green
    & $file
} catch {
    Write-Host ('  [FAILED] ' + $_.Exception.Message) -ForegroundColor Red
    throw
}