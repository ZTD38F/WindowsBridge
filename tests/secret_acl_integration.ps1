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
    function Set-TestRestrictedAcl([string]$Path, [switch]$Container) {
        $systemSid = [Security.Principal.SecurityIdentifier]::new("S-1-5-18")
        $administratorsSid = [Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
        $inheritance = if ($Container) {
            [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        } else {
            [Security.AccessControl.InheritanceFlags]::None
        }
        $acl = if ($Container) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner($administratorsSid)
        foreach ($sid in @($systemSid, $administratorsSid)) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            )
            [void]$acl.AddAccessRule($rule)
        }
        Set-Acl -Path $Path -AclObject $acl
    }

    Set-TestRestrictedAcl -Path $fixtureSecrets -Container
    $directoryAcl = Get-Acl $fixtureSecrets
    if (-not $directoryAcl.AreAccessRulesProtected) {
        throw "The secret directory still inherits access from its parent."
    }
    if ($directoryAcl.Owner -notmatch 'S-1-5-32-544|Administrators') {
        throw "The secret directory owner is not Builtin Administrators: $($directoryAcl.Owner)"
    }

    foreach ($secretName in @("control_plane_api_key", "router_token", "backend_token")) {
        $secretPath = Join-Path $fixtureSecrets $secretName
        Set-Content -Path $secretPath -Value "test-runtime-key-not-a-real-secret" -Encoding ASCII -NoNewline
        Set-TestRestrictedAcl -Path $secretPath
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
