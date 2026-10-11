$ErrorActionPreference = "Stop"

$sourceRoot = Split-Path $PSScriptRoot -Parent
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("WindowsBridge path with spaces - Unicode Ω Ж 漢字 - " + [guid]::NewGuid().ToString("N"))
$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    foreach ($name in @("install.ps1", "uninstall.ps1", "update.ps1", "update-state.psm1", "windowsbridgectl.ps1")) {
        Copy-Item (Join-Path $sourceRoot $name) (Join-Path $fixtureRoot $name) -Force
    }

    $installer = Join-Path $fixtureRoot "install.ps1"
    $preflightText = (& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $installer -PreflightOnly | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Installer preflight failed from the spaces/Unicode fixture path with exit code $LASTEXITCODE."
    }
    $preflight = $preflightText | ConvertFrom-Json
    if (-not $preflight.ok -or -not $preflight.windows_64_bit) {
        throw "Installer preflight returned an invalid result from the spaces/Unicode fixture path."
    }

    Get-ChildItem $fixtureRoot -Include *.ps1,*.psm1 -Recurse | ForEach-Object {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) {
            throw "PowerShell parser failed for Unicode path '$($_.FullName)': $($errors | Out-String)"
        }
    }

    $utf8 = [Text.Encoding]::UTF8.GetBytes($fixtureRoot)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $expectedPathHash = ([BitConverter]::ToString($sha256.ComputeHash($utf8))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
    $actualPathHash = (& python -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode('utf-8')).hexdigest())" $fixtureRoot | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualPathHash -ne $expectedPathHash) {
        throw "A child process did not receive the spaces/Unicode path unchanged."
    }

    Write-Host "Spaces and Unicode path integration checks passed."
} finally {
    Remove-Item $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
