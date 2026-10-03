[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BootstrapUrl
)

$ErrorActionPreference = "Stop"
$AllowedHost = "windowsbridge.sonoryx.store"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$uri = [Uri]$BootstrapUrl
if ($uri.Scheme -ne "https" -or $uri.Host -ne $AllowedHost -or -not $uri.AbsolutePath.StartsWith("/b/")) {
    throw "Invalid WindowsBridge bootstrap URL."
}

if (-not (Test-Administrator)) {
    if (-not $PSCommandPath) { throw "Bootstrap must be run from a downloaded .ps1 file." }
    $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $PSCommandPath),"-BootstrapUrl",('"{0}"' -f $BootstrapUrl))
    $p = Start-Process "powershell.exe" -Verb RunAs -ArgumentList $args -Wait -PassThru
    exit $p.ExitCode
}

$cfg = Invoke-RestMethod -Method Get -Uri $uri.AbsoluteUri -Headers @{"Cache-Control"="no-store"}
if (-not $cfg.tunnel_id -or -not $cfg.runtime_api_key) { throw "Bootstrap bundle is incomplete." }
if ($cfg.tunnel_id -notmatch '^tunnel_[0-9a-f]{32}$') { throw "Invalid tunnel ID in bootstrap bundle." }

$ref = if ($cfg.source_ref) { [string]$cfg.source_ref } else { "main" }
if ($ref -notmatch '^[A-Za-z0-9._-]{1,80}$') { throw "Invalid source ref." }

$tmp = Join-Path $env:TEMP ("WindowsBridge-install-" + [guid]::NewGuid().ToString("N") + ".ps1")
try {
    Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/ZTD38F/WindowsBridge/$ref/install.ps1" -OutFile $tmp
    & $tmp -TunnelId ([string]$cfg.tunnel_id) -RuntimeApiKey ([string]$cfg.runtime_api_key) -SourceRef $ref
    if ($LASTEXITCODE -ne 0) { throw "WindowsBridge installer failed with exit code $LASTEXITCODE." }
} finally {
    $cfg.runtime_api_key = $null
    $cfg = $null
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    [GC]::Collect()
}
