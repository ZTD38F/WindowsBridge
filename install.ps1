[CmdletBinding()]
param(
    [string]$TunnelId,
    [string]$RuntimeApiKey,
    [string]$SourceRef = "stable",
    [switch]$AutoUpdate,
    [switch]$DisableAutoUpdate
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$SelfUrl = "https://raw.githubusercontent.com/ZTD38F/WindowsBridge/$SourceRef/install.ps1"
$Root = Join-Path $env:ProgramData "WindowsBridge"
$Bin = Join-Path $Root "bin"
$Logs = Join-Path $Root "logs"
$Releases = Join-Path $Root "releases"
$Config = Join-Path $Root "config.json"
$Current = Join-Path $Root "current.txt"
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
        $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $tmp),"-SourceRef",$SourceRef)
        if ($AutoUpdate) { $args += "-AutoUpdate" }
        if ($DisableAutoUpdate) { $args += "-DisableAutoUpdate" }
        $p = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args -Wait -PassThru
        exit $p.ExitCode
    } finally {
        $env:WINDOWSBRIDGE_TUNNEL_ID = $null
        $env:WINDOWSBRIDGE_RUNTIME_API_KEY = $null
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-ReleaseAsset([object]$Release, [string]$Name) {
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


function Open-SetupPage([string]$Url) {
    Write-Host "  $Url" -ForegroundColor Cyan
    try {
        Start-Process $Url -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "  Open the link above in your browser." -ForegroundColor DarkGray
    }
}

function Read-TunnelId {
    $url = "https://platform.openai.com/settings/organization/tunnels"

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host " WindowsBridge - Step 1 of 3: Create the OpenAI tunnel" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "A browser page will open. In OpenAI Platform:" -ForegroundColor White
    Write-Host "  1. Create a new tunnel." -ForegroundColor Gray
    Write-Host "  2. Name: WindowsBridge" -ForegroundColor Yellow
    Write-Host "  3. If a workspace selector appears, choose the ChatGPT workspace" -ForegroundColor Gray
    Write-Host "     where you will use WindowsBridge." -ForegroundColor Gray
    Write-Host "  4. Create/save the tunnel." -ForegroundColor Gray
    Write-Host "  5. Copy its ID. It looks like:" -ForegroundColor Gray
    Write-Host "     tunnel_0123456789abcdef0123456789abcdef" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "If Create tunnel is unavailable or returns 403, your Platform role needs" -ForegroundColor DarkGray
    Write-Host "Tunnels: Read + Manage." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "OpenAI Tunnels:" -ForegroundColor White
    Open-SetupPage $url
    Write-Host ""

    while ($true) {
        $value = (Read-Host "Paste TUNNEL_ID here").Trim()
        if ($value -match '^tunnel_[0-9a-f]{32}$') {
            Write-Host "OK - Tunnel ID accepted." -ForegroundColor Green
            return $value
        }
        Write-Host "That does not look like a valid Tunnel ID." -ForegroundColor Red
        Write-Host "Expected: tunnel_ followed by 32 lowercase hexadecimal characters." -ForegroundColor DarkGray
    }
}

function Read-RuntimeApiKey {
    $url = "https://platform.openai.com/settings/organization/api-keys"

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host " WindowsBridge - Step 2 of 3: Create the Runtime API key" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "In OpenAI Platform Runtime API keys:" -ForegroundColor White
    Write-Host "  1. Create a new Runtime API key." -ForegroundColor Gray
    Write-Host "  2. Name: WindowsBridge Runtime" -ForegroundColor Yellow
    Write-Host "  3. Choose: Restricted" -ForegroundColor Yellow
    Write-Host "  4. Grant only:" -ForegroundColor Gray
    Write-Host "       Tunnels -> Read" -ForegroundColor Yellow
    Write-Host "       Tunnels -> Use" -ForegroundColor Yellow
    Write-Host "     Do NOT use an Admin API key for the WindowsBridge daemon." -ForegroundColor DarkGray
    Write-Host "  5. Create the key and copy it." -ForegroundColor Gray
    Write-Host ""
    Write-Host "OpenAI Runtime API keys:" -ForegroundColor White
    Open-SetupPage $url
    Write-Host ""

    while ($true) {
        $secure = Read-Host "Paste Runtime API key here (input is hidden)" -AsSecureString
        $value = ConvertFrom-Secure $secure
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Write-Host "OK - Runtime API key received." -ForegroundColor Green
            return $value
        }
        Write-Host "The key cannot be empty." -ForegroundColor Red
    }
}

function Show-ConnectorSetup([string]$ResolvedTunnelId) {
    $url = "https://chatgpt.com/#settings/Connectors"

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host " WindowsBridge - Step 3 of 3: Add it to ChatGPT" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "WindowsBridge is running. Finish the connector in ChatGPT:" -ForegroundColor White
    Write-Host "  Name:           WindowsBridge" -ForegroundColor Yellow
    Write-Host "  Connection:     Tunnel" -ForegroundColor Yellow
    Write-Host "  Tunnel:         select WindowsBridge, or paste:" -ForegroundColor Gray
    Write-Host "                  $ResolvedTunnelId" -ForegroundColor Yellow
    Write-Host "  Authentication: No authentication (NoAuth)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "NoAuth is only the MCP-server authentication mode." -ForegroundColor DarkGray
    Write-Host "The OpenAI Secure MCP Tunnel is still authenticated by the Runtime API key." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "ChatGPT Connectors:" -ForegroundColor White
    Open-SetupPage $url
    Write-Host ""
    Write-Host "After saving the connector, rescan/sync its tools if ChatGPT asks." -ForegroundColor Gray
}

if (-not (Test-Administrator)) { Invoke-Elevated }

if ($SourceRef -notmatch '^[A-Za-z0-9._-]{1,80}$') { throw "Invalid SourceRef." }

New-Item -ItemType Directory -Force -Path $Root,$Bin,$Logs,$Releases | Out-Null

$existing = Get-ExistingConfig
if (-not $TunnelId) { $TunnelId = $env:WINDOWSBRIDGE_TUNNEL_ID }
if (-not $RuntimeApiKey) { $RuntimeApiKey = $env:WINDOWSBRIDGE_RUNTIME_API_KEY }
if (-not $TunnelId -and $existing) { $TunnelId = $existing.tunnel_id }
if (-not $RuntimeApiKey -and $existing) { $RuntimeApiKey = $existing.runtime_api_key }

$PreviousTunnelId = if ($existing) { [string]$existing.tunnel_id } else { $null }

if (-not $TunnelId) { $TunnelId = Read-TunnelId }
if (-not $RuntimeApiKey) { $RuntimeApiKey = Read-RuntimeApiKey }

if ($TunnelId -notmatch '^tunnel_[0-9a-f]{32}$') { throw "Invalid OpenAI tunnel ID." }
if ([string]::IsNullOrWhiteSpace($RuntimeApiKey)) { throw "Runtime API key is required." }

$NeedsConnectorSetup = (-not $existing) -or ($PreviousTunnelId -ne $TunnelId)

Write-Host "Resolving immutable WindowsBridge commit from GitHub..."
$commit = Invoke-RestMethod "https://api.github.com/repos/ZTD38F/WindowsBridge/commits/$SourceRef" -Headers @{"User-Agent"="WindowsBridge-Installer"}
$ResolvedRef = [string]$commit.sha
if ($ResolvedRef -notmatch '^[0-9a-f]{40}$') { throw "Could not resolve a GitHub commit SHA." }
$RawBase = "https://raw.githubusercontent.com/ZTD38F/WindowsBridge/$ResolvedRef"

$stage = Join-Path $Releases (".stage-" + [guid]::NewGuid().ToString("N"))
$releaseDir = Join-Path $Releases $ResolvedRef
$previousRef = if (Test-Path $Current) { (Get-Content $Current -Raw).Trim() } else { $null }

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $stage "app") | Out-Null

    Write-Host "Downloading WindowsBridge source from GitHub commit $ResolvedRef..."
    Invoke-WebRequest -UseBasicParsing "$RawBase/windowsbridge.py" -OutFile (Join-Path $stage "app\windowsbridge.py")
    Invoke-WebRequest -UseBasicParsing "$RawBase/requirements.lock" -OutFile (Join-Path $stage "app\requirements.lock")

    Write-Host "Downloading verified uv from GitHub Releases..."
    $uvRelease = Invoke-RestMethod "https://api.github.com/repos/astral-sh/uv/releases/latest" -Headers @{"User-Agent"="WindowsBridge-Installer"}
    $uvArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64" } else { "x86_64" }
    $uvName = "uv-$uvArch-pc-windows-msvc.zip"
    $uvAsset = Get-ReleaseAsset $uvRelease $uvName
    $uvZip = Join-Path $stage $uvName
    Download-VerifiedAsset $uvAsset $uvZip
    $uvDir = Join-Path $stage "uv"
    Expand-Archive $uvZip -DestinationPath $uvDir -Force
    $uvExe = Get-ChildItem $uvDir -Filter "uv.exe" -Recurse | Select-Object -First 1
    if (-not $uvExe) { throw "uv.exe was not found in the verified GitHub archive." }
    Copy-Item $uvExe.FullName (Join-Path $Bin "uv.exe") -Force
    $uv = Join-Path $Bin "uv.exe"

    Write-Host "Creating isolated Python runtime..."
    & $uv python install 3.12
    if ($LASTEXITCODE -ne 0) { throw "uv could not install Python 3.12." }
    & $uv venv --python 3.12 (Join-Path $stage "venv")
    if ($LASTEXITCODE -ne 0) { throw "uv could not create the WindowsBridge virtual environment." }
    $venvPython = Join-Path $stage "venv\Scripts\python.exe"
    & $uv pip install --python $venvPython -r (Join-Path $stage "app\requirements.lock")
    if ($LASTEXITCODE -ne 0) { throw "WindowsBridge dependency installation failed." }
    & $venvPython -m py_compile (Join-Path $stage "app\windowsbridge.py")
    if ($LASTEXITCODE -ne 0) { throw "WindowsBridge Python compile check failed." }

    Write-Host "Downloading verified official OpenAI tunnel-client from GitHub Releases..."
    $tunnelRelease = Invoke-RestMethod "https://api.github.com/repos/openai/tunnel-client/releases/latest" -Headers @{"User-Agent"="WindowsBridge-Installer"}
    $tunnelArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
    $tunnelName = "tunnel-client-$($tunnelRelease.tag_name)-windows-$tunnelArch.zip"
    $tunnelAsset = Get-ReleaseAsset $tunnelRelease $tunnelName
    $tunnelZip = Join-Path $stage $tunnelName
    Download-VerifiedAsset $tunnelAsset $tunnelZip
    $tunnelDir = Join-Path $stage "tunnel"
    Expand-Archive $tunnelZip -DestinationPath $tunnelDir -Force
    $tunnelExe = Get-ChildItem $tunnelDir -Filter "tunnel-client.exe" -Recurse | Select-Object -First 1
    if (-not $tunnelExe) { throw "tunnel-client.exe was not found in the verified OpenAI GitHub archive." }
    Copy-Item $tunnelExe.FullName (Join-Path $Bin "tunnel-client.exe") -Force
    $tunnelFinal = Join-Path $Bin "tunnel-client.exe"

    $env:CONTROL_PLANE_API_KEY = $RuntimeApiKey
    $env:CONTROL_PLANE_TUNNEL_ID = $TunnelId
    $env:MCP_COMMAND = '"' + $venvPython + '" "' + (Join-Path $stage "app\windowsbridge.py") + '"'
    $env:WINDOWSBRIDGE_ALLOWED_ROOTS = "*"

    Write-Host "Validating OpenAI Secure MCP Tunnel..."
    & $tunnelFinal doctor --explain
    if ($LASTEXITCODE -ne 0) { throw "tunnel-client doctor failed." }

    if (Test-Path $releaseDir) { Remove-Item $releaseDir -Recurse -Force }
    Move-Item $stage $releaseDir

    $keyBytes = [Text.Encoding]::UTF8.GetBytes($RuntimeApiKey)
    $protected = [Security.Cryptography.ProtectedData]::Protect($keyBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)

    [ordered]@{
        version = "0.2.0"
        source_commit = $ResolvedRef
        tunnel_id = $TunnelId
        api_key_dpapi = [Convert]::ToBase64String($protected)
        installed_at = (Get-Date).ToString("o")
        uv_release = [string]$uvRelease.tag_name
        tunnel_client_release = [string]$tunnelRelease.tag_name
    } | ConvertTo-Json | Set-Content $Config -Encoding UTF8

    Set-Content $Current $ResolvedRef -Encoding ASCII

    $launchContent = @'
$ErrorActionPreference = "Stop"
$Root = Join-Path $env:ProgramData "WindowsBridge"
$cfg = Get-Content (Join-Path $Root "config.json") -Raw | ConvertFrom-Json
$ref = (Get-Content (Join-Path $Root "current.txt") -Raw).Trim()
$release = Join-Path (Join-Path $Root "releases") $ref
$enc = [Convert]::FromBase64String($cfg.api_key_dpapi)
$raw = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
try {
    $env:CONTROL_PLANE_API_KEY = [Text.Encoding]::UTF8.GetString($raw)
    $env:CONTROL_PLANE_TUNNEL_ID = $cfg.tunnel_id
    $env:MCP_COMMAND = '"' + (Join-Path $release "venv\Scripts\python.exe") + '" "' + (Join-Path $release "app\windowsbridge.py") + '"'
    $env:WINDOWSBRIDGE_ALLOWED_ROOTS = "*"
    $env:PYTHONUNBUFFERED = "1"
    & (Join-Path $Root "bin\tunnel-client.exe") run *>> (Join-Path $Root "logs\tunnel.log")
} finally {
    $env:CONTROL_PLANE_API_KEY = $null
    $raw = $null
}
'@
    Set-Content $Launch $launchContent -Encoding UTF8

    icacls $Root /inheritance:r | Out-Null
    icacls $Root /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" | Out-Null

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
    Write-Host "Source commit: $ResolvedRef"
    Write-Host "OpenAI tunnel-client: $($tunnelRelease.tag_name)"
    Write-Host "Task state: $state"

    if ($NeedsConnectorSetup) {
        Show-ConnectorSetup $TunnelId
    } else {
        Write-Host ""
        Write-Host "Existing OpenAI tunnel configuration reused; no connector setup is needed." -ForegroundColor Green
    }
} catch {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
    if ($previousRef -and (Test-Path (Join-Path $Releases $previousRef))) {
        Set-Content $Current $previousRef -Encoding ASCII -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    throw
} finally {
    $env:CONTROL_PLANE_API_KEY = $null
    $env:CONTROL_PLANE_TUNNEL_ID = $null
    $env:MCP_COMMAND = $null
    $RuntimeApiKey = $null
    $existing = $null
    [GC]::Collect()
}
