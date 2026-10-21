$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @('Win11Upgrade.ps1','bootstrap.ps1')
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ("Parse failed for {0}: {1}" -f $file, ($errors -join '; ')) }
    Write-Host ("[PASS] Parsed {0}" -f $file) -ForegroundColor Green
}
& (Join-Path $root 'Win11Upgrade.ps1') -SelfTest
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Self test exit code nonzero' }
# Validate no unsafe install switches and no fetching ISO from third-party sources.
$s = Get-Content -LiteralPath (Join-Path $root 'Win11Upgrade.ps1') -Raw
foreach ($bad in @('/auto clean','/auto dataonly','/compat ignorewarning','BypassTPMCheck','Disable-WindowsDefender','Remove-Item C:')) {
    if ($s.IndexOf($bad, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw ('Unsafe pattern found: ' + $bad) }
}
Write-Host '[PASS] Safety assertions.' -ForegroundColor Green