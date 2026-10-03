[CmdletBinding()]
param(
    [string]$TunnelId,
    [string]$RuntimeApiKey,
    [ValidateSet("edge","stable")]
    [string]$Channel = "edge"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$SelfUrl = "https://raw.githubusercontent.com/ZTD38F/WindowsBridge/main/install.ps1"
$Root = Join-Path $env:ProgramData "WindowsBridge"
$Bin = Join-Path $Root "bin"
$Logs = Join-Path $Root "logs"
$Config = Join-Path $Root "config.json"
$Launch = Join-Path $Root "launch.ps1"
$TaskName = "WindowsBridge"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertFrom-Secure([Security.SecureString]$Secure) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Invoke-Elevated {
    $tmp = Join-Path $env:TEMP ("WindowsBridge-install-" + [guid]::NewGuid().ToString("N") + ".ps1")
    Invoke-WebRequest -UseBasicParsing $SelfUrl -OutFile $tmp
    if ($TunnelId) { $env:WINDOWSBRIDGE_TUNNEL_ID = $TunnelId }
    if ($RuntimeApiKey) { $env:WINDOWSBRIDGE_RUNTIME_API_KEY = $RuntimeApiKey }
    try {
        $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $tmp),"-Channel",$Channel)
        $p = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args -Wait -PassThru
        exit $p.ExitCode
    } finally {
        $env:WINDOWSBRIDGE_TUNNEL_ID = $null
        $env:WINDOWSBRIDGE_RUNTIME_API_KEY = $null
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-Asset([object]$Release, [string]$Name) {
    $asset = $Release.assets | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $asset) { throw "GitHub Release asset not found: $Name" }
    if (-not $asset.digest -or -not ([string]$asset.digest).StartsWith("sha256:")) {
        throw "GitHub Release asset has no SHA-256 digest: $Name"
    }
    return $asset
}

function Download-VerifiedAsset([object]$Asset, [string]$Destination) {
    Invoke-WebRequest -UseBasicParsing $Asset.browser_download_url -OutFile $Destination
    $expected = ([string]$Asset.digest).Substring(7).ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 $Destination).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        throw "SHA-256 verification failed for $($Asset.name)"
    }
}

function Get-ExistingConfig {
    if (-not (Test-Path $Config)) { return $null }
    try {
        $cfg = Get-Content $Config -Raw | ConvertFrom-Json
        $enc = [Convert]::FromBase64String($cfg.api_key_dpapi)
        $raw = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [pscustomobject]@{
            tunnel_id = [string]$cfg.tunnel_id
            runtime_api_key = [Text.Encoding]::UTF8.GetString($raw)
        }
    } catch {
        return $null
    }
}

if (-not (Test-Administrator)) { Invoke-Elevated }

New-Item -ItemType Directory -Force -Path $Root,$Bin,$Logs | Out-Null

$existing = Get-ExistingConfig
if (-not $TunnelId) { $TunnelId = $env:WINDOWSBRIDGE_TUNNEL_ID }
if (-not $RuntimeApiKey) { $RuntimeApiKey = $env:WINDOWSBRIDGE_RUNTIME_API_KEY }
if (-not $TunnelId -and $existing) { $TunnelId = $existing.tunnel_id }
if (-not $RuntimeApiKey -and $existing) { $RuntimeApiKey = $existing.runtime_api_key }

if (-not $TunnelId) {
    $TunnelId = Read-Host "OpenAI Tunnel ID"
}
if (-not $RuntimeApiKey) {
    $RuntimeApiKey = ConvertFrom-Secure (Read-Host "OpenAI Runtime API key" -AsSecureString)
}
if ($TunnelId -notmatch '^tunnel_[0-9a-f]{32}$') { throw "Invalid OpenAI tunnel ID." }
if ([string]::IsNullOrWhiteSpace($RuntimeApiKey)) { throw "Runtime API key is required." }

Write-Host "Resolving WindowsBridge GitHub Release..."
$wbReleaseUrl = if ($Channel -eq "edge") {
    "https://api.github.com/repos/ZTD38F/WindowsBridge/releases/tags/edge"
} else {
    "https://api.github.com/repos/ZTD38F/WindowsBridge/releases/latest"
}
$wbRelease = Invoke-RestMethod $wbReleaseUrl -Headers @{"User-Agent"="WindowsBridge-Installer"}
$wbAsset = Get-Asset $wbRelease "WindowsBridge.exe"

$stage = Join-Path $env:TEMP ("WindowsBridge-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$agentStage = Join-Path $stage "WindowsBridge.exe"
Download-VerifiedAsset $wbAsset $agentStage

Write-Host "Resolving official OpenAI tunnel-client GitHub Release..."
$tunnelRelease = Invoke-RestMethod "https://api.github.com/repos/openai/tunnel-client/releases/latest" -Headers @{"User-Agent"="WindowsBridge-Installer"}
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
$tunnelName = "tunnel-client-$($tunnelRelease.tag_name)-windows-$arch.zip"
$tunnelAsset = Get-Asset $tunnelRelease $tunnelName
$tunnelZip = Join-Path $stage $tunnelName
Download-VerifiedAsset $tunnelAsset $tunnelZip
$tunnelDir = Join-Path $stage "tunnel"
Expand-Archive $tunnelZip -DestinationPath $tunnelDir -Force
$tunnelExe = Get-ChildItem $tunnelDir -Filter "tunnel-client.exe" -Recurse | Select-Object -First 1
if (-not $tunnelExe) { throw "tunnel-client.exe was not found in the verified OpenAI archive." }

$agentFinal = Join-Path $Bin "WindowsBridge.exe"
$tunnelFinal = Join-Path $Bin "tunnel-client.exe"
$agentBackup = Join-Path $Bin "WindowsBridge.previous.exe"
$tunnelBackup = Join-Path $Bin "tunnel-client.previous.exe"

if (Test-Path $agentFinal) { Copy-Item $agentFinal $agentBackup -Force }
if (Test-Path $tunnelFinal) { Copy-Item $tunnelFinal $tunnelBackup -Force }

try {
    Copy-Item $agentStage $agentFinal -Force
    Copy-Item $tunnelExe.FullName $tunnelFinal -Force

    $keyBytes = [Text.Encoding]::UTF8.GetBytes($RuntimeApiKey)
    $protected = [Security.Cryptography.ProtectedData]::Protect($keyBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    [ordered]@{
        version = "0.2"
        channel = $Channel
        tunnel_id = $TunnelId
        api_key_dpapi = [Convert]::ToBase64String($protected)
        installed_at = (Get-Date).ToString("o")
        windowsbridge_release = [string]$wbRelease.tag_name
        tunnel_client_release = [string]$tunnelRelease.tag_name
    } | ConvertTo-Json | Set-Content $Config -Encoding UTF8

    $launchContent = @'
$ErrorActionPreference = "Stop"
$Root = Join-Path $env:ProgramData "WindowsBridge"
$cfg = Get-Content (Join-Path $Root "config.json") -Raw | ConvertFrom-Json
$enc = [Convert]::FromBase64String($cfg.api_key_dpapi)
$raw = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
try {
    $env:CONTROL_PLANE_API_KEY = [Text.Encoding]::UTF8.GetString($raw)
    $env:CONTROL_PLANE_TUNNEL_ID = $cfg.tunnel_id
    $env:MCP_COMMAND = '"' + (Join-Path $Root "bin\WindowsBridge.exe") + '"'
    $env:WINDOWSBRIDGE_ALLOWED_ROOTS = "*"
    & (Join-Path $Root "bin\tunnel-client.exe") run *>> (Join-Path $Root "logs\tunnel.log")
} finally {
    $env:CONTROL_PLANE_API_KEY = $null
    $raw = $null
}
'@
    Set-Content $Launch $launchContent -Encoding UTF8

    icacls $Root /inheritance:r | Out-Null
    icacls $Root /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" | Out-Null

    $env:CONTROL_PLANE_API_KEY = $RuntimeApiKey
    $env:CONTROL_PLANE_TUNNEL_ID = $TunnelId
    $env:MCP_COMMAND = '"' + $agentFinal + '"'
    Write-Host "Validating OpenAI Secure MCP Tunnel..."
    & $tunnelFinal doctor --explain
    if ($LASTEXITCODE -ne 0) { throw "tunnel-client doctor failed." }

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $actionArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $Launch
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $actionArgs
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "WindowsBridge MCP agent for ChatGPT" | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
    $state = (Get-ScheduledTask -TaskName $TaskName).State
    if ($state -notin @("Running","Ready")) { throw "WindowsBridge startup task is not healthy: $state" }

    Write-Host ""
    Write-Host "WindowsBridge installed from GitHub." -ForegroundColor Green
    Write-Host "WindowsBridge release: $($wbRelease.tag_name)"
    Write-Host "OpenAI tunnel-client release: $($tunnelRelease.tag_name)"
    Write-Host "Task state: $state"
} catch {
    if (Test-Path $agentBackup) { Copy-Item $agentBackup $agentFinal -Force }
    if (Test-Path $tunnelBackup) { Copy-Item $tunnelBackup $tunnelFinal -Force }
    throw
} finally {
    $env:CONTROL_PLANE_API_KEY = $null
    $env:CONTROL_PLANE_TUNNEL_ID = $null
    $env:MCP_COMMAND = $null
    $RuntimeApiKey = $null
    $existing = $null
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    [GC]::Collect()
}
