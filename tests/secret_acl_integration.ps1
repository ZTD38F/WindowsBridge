$ErrorActionPreference = "Stop"

$sourceRoot = Split-Path $PSScriptRoot -Parent
$installerPath = Join-Path $sourceRoot "install.ps1"
$installer = Get-Content $installerPath -Raw

$protectMarker = 'Set-RestrictedSecretAcl -Path $Secrets -Container'
$writeMarker = 'Set-Content -Path $RuntimeKeyFile -Value $RuntimeApiKey -Encoding ASCII -NoNewline'
$runtimeAclMarker = 'Set-RestrictedSecretAcl -Path $RuntimeKeyFile'
$routerAclMarker = 'Set-RestrictedSecretAcl -Path $RouterTokenFile'
$backendAclMarker = 'Set-RestrictedSecretAcl -Path $BackendTokenFile'
$protectIndex = $installer.IndexOf($protectMarker)
$writeIndex = $installer.IndexOf($writeMarker)
$runtimeAclIndex = $installer.IndexOf($runtimeAclMarker)

if ($protectIndex -lt 0 -or $writeIndex -lt 0 -or $runtimeAclIndex -lt 0) {
    throw "Installer tunnel-secret ACL contract is incomplete."
}
if ($protectIndex -gt $writeIndex -or $writeIndex -gt $runtimeAclIndex) {
    throw "Installer must protect the secrets directory before writing and then seal the tunnel credential file."
}
foreach ($marker in @($routerAclMarker, $backendAclMarker)) {
    if (-not $installer.Contains($marker)) {
        throw "Installer does not seal every local secret file: $marker"
    }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("WindowsBridge ACL " + [guid]::NewGuid().ToString("N"))
$fixtureSecrets = Join-Path $fixtureRoot "secrets"
$allowedSids = @("S-1-5-18", "S-1-5-32-544")

try {
    New-Item -ItemType Directory -Path $fixtureSecrets -Force | Out-Null
    # Execute the production ACL implementation, not a copy of its logic.
    # This catches regressions even if a marker in install.ps1 is unchanged.
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $installerPath, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) {
        throw "Production installer PowerShell parser errors: $($parseErrors.Count)"
    }
    $aclDefinitions = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Set-RestrictedSecretAcl'
    }, $true))
    if ($aclDefinitions.Count -ne 1) {
        throw "Expected exactly one production Set-RestrictedSecretAcl definition."
    }
    Invoke-Expression $aclDefinitions[0].Extent.Text

    Set-RestrictedSecretAcl -Path $fixtureSecrets -Container
    $directoryAcl = Get-Acl $fixtureSecrets
    if (-not $directoryAcl.AreAccessRulesProtected) {
        throw "The secret directory still inherits access from its parent."
    }
    if ($directoryAcl.Owner -notmatch 'S-1-5-32-544|Administrators') {
        throw "The secret directory owner is not Builtin Administrators: $($directoryAcl.Owner)"
    }

    # Verify directory access rules too: an unprotected directory can expose
    # the token filenames and newly created secrets before their final ACL.
    $directoryRules = @($directoryAcl.GetAccessRules(
        $true, $true, [Security.Principal.SecurityIdentifier]))
    if ($directoryRules.Count -ne 2) {
        throw "Unexpected number of explicit secret-directory ACEs: $($directoryRules.Count)"
    }
    foreach ($rule in $directoryRules) {
        if ($rule.IdentityReference.Value -notin $allowedSids -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            throw "Secret directory has an unexpected access rule."
        }
        if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
            [Security.AccessControl.FileSystemRights]::FullControl) {
            throw "Secret directory ACL rule must grant full control."
        }
    }

    foreach ($secretName in @("control_plane_api_key", "router_token", "backend_token")) {
        $secretPath = Join-Path $fixtureSecrets $secretName
        Set-Content -Path $secretPath -Value "test-runtime-key-not-a-real-secret" -Encoding ASCII -NoNewline
        Set-RestrictedSecretAcl -Path $secretPath
        $fileAcl = Get-Acl $secretPath
        if (-not $fileAcl.AreAccessRulesProtected) {
            throw "Secret file still inherits access: $secretName"
        }
        if ($fileAcl.Owner -notmatch 'S-1-5-32-544|Administrators') {
            throw "Secret file owner is not Builtin Administrators: $secretName ($($fileAcl.Owner))"
        }
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
