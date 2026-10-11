$ErrorActionPreference = "Stop"

$sourceRoot = Split-Path $PSScriptRoot -Parent
$installerPath = Join-Path $sourceRoot "install.ps1"
$installer = Get-Content $installerPath -Raw

$protectMarker = 'icacls $Secrets /inheritance:r'
$grantMarker = 'icacls $Secrets /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F"'
$writeMarker = 'Set-Content -Path $RuntimeKeyFile -Value $RuntimeApiKey -Encoding ASCII -NoNewline'
$protectIndex = $installer.IndexOf($protectMarker)
$grantIndex = $installer.IndexOf($grantMarker)
$writeIndex = $installer.IndexOf($writeMarker)

if ($protectIndex -lt 0 -or $grantIndex -lt 0 -or $writeIndex -lt 0) {
    throw "Installer tunnel-secret ACL contract is incomplete."
}
if ($protectIndex -gt $grantIndex -or $grantIndex -gt $writeIndex) {
    throw "Installer must protect the secrets directory before writing the tunnel credential."
}
if ($installer.Contains('icacls $Secrets /inheritance:e')) {
    throw "Installer must not re-enable inherited access on the secrets directory."
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("WindowsBridge ACL " + [guid]::NewGuid().ToString("N"))
$fixtureSecrets = Join-Path $fixtureRoot "secrets"
$allowedSids = @("S-1-5-18", "S-1-5-32-544")

try {
    New-Item -ItemType Directory -Path $fixtureSecrets -Force | Out-Null
    & icacls.exe $fixtureSecrets /inheritance:r | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not disable inherited ACLs on the secret fixture." }
    & icacls.exe $fixtureSecrets /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not grant the restricted secret fixture ACL." }

    $directoryAcl = Get-Acl $fixtureSecrets
    if (-not $directoryAcl.AreAccessRulesProtected) {
        throw "The secret directory still inherits access from its parent."
    }

    foreach ($secretName in @("control_plane_api_key", "router_token", "backend_token")) {
        $secretPath = Join-Path $fixtureSecrets $secretName
        Set-Content -Path $secretPath -Value "test-runtime-key-not-a-real-secret" -Encoding ASCII -NoNewline
        $fileAcl = Get-Acl $secretPath
        $rules = @($fileAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        if ($rules.Count -eq 0) { throw "Secret file has no access rules: $secretName" }

        foreach ($rule in $rules) {
            $sid = $rule.IdentityReference.Value
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
                throw "Secret file contains an unexpected deny rule for $sid."
            }
            if ($sid -notin $allowedSids) {
                throw "Secret file grants access to unexpected SID $sid."
            }
            if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) {
                throw "Secret file rule for $sid is not the expected full-control rule."
            }
        }

        foreach ($sid in $allowedSids) {
            if ($sid -notin @($rules.IdentityReference.Value)) {
                throw "Secret file is missing the required ACL for $sid."
            }
        }
    }

    Write-Host "Tunnel secret ACL integration checks passed."
} finally {
    if (Test-Path $fixtureRoot) {
        & icacls.exe $fixtureRoot /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null
        Remove-Item $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
