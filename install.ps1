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

$Repo = "ZTD38F/WindowsBridge"
$Root = Join-Path $env:ProgramData "WindowsBridge"
$Bin = Join-Path $Root "bin"
$Logs = Join-Path $Root "logs"
$Releases = Join-Path $Root "releases"
$Runtime = Join-Path $Root "runtime"
$Cache = Join-Path $Root "cache"
$Config = Join-Path $Root "config.json"
$Current = Join-Path $Root "current.txt"
$Launch = Join-Path $Root "launch.ps1"
$UpdateScript = Join-Path $Root "update.ps1"
$UpdateStateModule = Join-Path $Root "update-state.psm1"
$UpdateState = Join-Path $Root "update-state.json"
$ControlScript = Join-Path $env:SystemRoot "System32\windowsbridgectl.ps1"
$ControlCmd = Join-Path $env:SystemRoot "System32\windowsbridgectl.cmd"
$TaskName = "WindowsBridge"
$AutoUpdateTaskName = "WindowsBridge Auto Update"
$HealthBase = "http://127.0.0.1:18765"

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

function Resolve-SourceCommit([string]$Ref) {
    if ($Ref -notmatch '^[A-Za-z0-9._-]{1,80}$') { throw "Invalid SourceRef." }

    try {
        $commit = Invoke-RestMethod "https://api.github.com/repos/$Repo/commits/$Ref" -Headers @{"User-Agent"="WindowsBridge-Installer"}
    } catch {
        throw "Could not resolve WindowsBridge source ref '$Ref' to an immutable GitHub commit: $($_.Exception.Message)"
    }

    $sha = [string]$commit.sha
    if ($sha -notmatch '^[0-9a-f]{40}$') { throw "GitHub returned an invalid WindowsBridge commit SHA." }
    return $sha
}

function Invoke-Elevated {
    # Pin the installer before crossing the UAC boundary. The branch may move
    # between the one-line bootstrap and elevation, but this exact commit cannot.
    $ResolvedBootstrapRef = Resolve-SourceCommit $SourceRef
    $selfUrl = "https://raw.githubusercontent.com/$Repo/$ResolvedBootstrapRef/install.ps1"
    $tmp = Join-Path $env:TEMP ("WindowsBridge-install-" + [guid]::NewGuid().ToString("N") + ".ps1")
    Invoke-WebRequest -UseBasicParsing $selfUrl -OutFile $tmp
    if ($TunnelId) { $env:WINDOWSBRIDGE_TUNNEL_ID = $TunnelId }
    if ($RuntimeApiKey) { $env:WINDOWSBRIDGE_RUNTIME_API_KEY = $RuntimeApiKey }
    try {
        $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $tmp),"-SourceRef",$ResolvedBootstrapRef)
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
    Write-Host "  2. Name: WindowsBridge - $env:COMPUTERNAME" -ForegroundColor Yellow
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
    Write-Host "  2. Name: WindowsBridge Runtime - $env:COMPUTERNAME" -ForegroundColor Yellow
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
    Write-Host "  Name:           WindowsBridge - $env:COMPUTERNAME" -ForegroundColor Yellow
    Write-Host "  Connection:     Tunnel" -ForegroundColor Yellow
    Write-Host "  Tunnel:         select WindowsBridge - $env:COMPUTERNAME, or paste:" -ForegroundColor Gray
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

New-Item -ItemType Directory -Force -Path $Root,$Bin,$Logs,$Releases,$Runtime,$Cache | Out-Null

$existing = Get-ExistingConfig
if (-not $TunnelId) { $TunnelId = $env:WINDOWSBRIDGE_TUNNEL_ID }
if (-not $RuntimeApiKey) { $RuntimeApiKey = $env:WINDOWSBRIDGE_RUNTIME_API_KEY }
if (-not $TunnelId -and $existing) { $TunnelId = $existing.tunnel_id }
if (-not $RuntimeApiKey -and $existing) { $RuntimeApiKey = $existing.runtime_api_key }

$PreviousTunnelId = if ($existing) { [string]$existing.tunnel_id } else { $null }

if ($AutoUpdate -and -not $existing) {
    throw "Automatic update requires an existing WindowsBridge installation."
}

if (-not $TunnelId) { $TunnelId = Read-TunnelId }
if (-not $RuntimeApiKey) { $RuntimeApiKey = Read-RuntimeApiKey }

if ($TunnelId -notmatch '^tunnel_[0-9a-f]{32}$') { throw "Invalid OpenAI tunnel ID." }
if ([string]::IsNullOrWhiteSpace($RuntimeApiKey)) { throw "Runtime API key is required." }

$NeedsConnectorSetup = (-not $AutoUpdate) -and ((-not $existing) -or ($PreviousTunnelId -ne $TunnelId))

Write-Host "Resolving immutable WindowsBridge commit from GitHub..."
$ResolvedRef = Resolve-SourceCommit $SourceRef
$RawBase = "https://raw.githubusercontent.com/ZTD38F/WindowsBridge/$ResolvedRef"

$stage = Join-Path $Releases (".stage-" + [guid]::NewGuid().ToString("N"))
$releaseDir = Join-Path $Releases $ResolvedRef
$previousRef = if (Test-Path $Current) { (Get-Content $Current -Raw).Trim() } else { $null }

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $stage "app"),(Join-Path $stage "bin"),(Join-Path $stage "management") | Out-Null

    Write-Host "Downloading WindowsBridge source from GitHub commit $ResolvedRef..."
    Invoke-WebRequest -UseBasicParsing "$RawBase/windowsbridge.py" -OutFile (Join-Path $stage "app\windowsbridge.py")
    Invoke-WebRequest -UseBasicParsing "$RawBase/requirements.lock" -OutFile (Join-Path $stage "app\requirements.lock")
    Invoke-WebRequest -UseBasicParsing "$RawBase/update.ps1" -OutFile (Join-Path $stage "management\update.ps1")
    Invoke-WebRequest -UseBasicParsing "$RawBase/update-state.psm1" -OutFile (Join-Path $stage "management\update-state.psm1")
    Invoke-WebRequest -UseBasicParsing "$RawBase/windowsbridgectl.ps1" -OutFile (Join-Path $stage "management\windowsbridgectl.ps1")

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

    Write-Host "Creating isolated Python runtime inside WindowsBridge..."
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $Runtime "python"
    $env:UV_CACHE_DIR = Join-Path $Cache "uv"
    $env:UV_PYTHON_NO_REGISTRY = "1"
    $env:UV_PYTHON_INSTALL_BIN = "0"
    New-Item -ItemType Directory -Force -Path $env:UV_PYTHON_INSTALL_DIR,$env:UV_CACHE_DIR | Out-Null
    & $uv python install 3.12 --install-dir $env:UV_PYTHON_INSTALL_DIR
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
    Copy-Item $tunnelExe.FullName (Join-Path $stage "bin\tunnel-client.exe") -Force
    $tunnelFinal = Join-Path $stage "bin\tunnel-client.exe"

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
$mutex = [Threading.Mutex]::new($false, "Global\WindowsBridgeTunnelRuntime")
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { exit 0 }

    $cfg = Get-Content (Join-Path $Root "config.json") -Raw | ConvertFrom-Json
    $ref = (Get-Content (Join-Path $Root "current.txt") -Raw).Trim()
    $release = Join-Path (Join-Path $Root "releases") $ref
    $log = Join-Path $Root "logs\tunnel.log"

    if ((Test-Path $log) -and (Get-Item $log).Length -gt 10MB) {
        for ($i = 5; $i -ge 1; $i--) {
            $src = if ($i -eq 1) { $log } else { "$log." + ($i - 1) }
            $dst = "$log.$i"
            if (Test-Path $src) { Move-Item $src $dst -Force }
        }
    }

    $enc = [Convert]::FromBase64String($cfg.api_key_dpapi)
    $raw = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    try {
        $env:CONTROL_PLANE_API_KEY = [Text.Encoding]::UTF8.GetString($raw)
        $env:CONTROL_PLANE_TUNNEL_ID = $cfg.tunnel_id
        $env:MCP_COMMAND = '"' + (Join-Path $release "venv\Scripts\python.exe") + '" "' + (Join-Path $release "app\windowsbridge.py") + '"'
        $env:WINDOWSBRIDGE_ALLOWED_ROOTS = "*"
        $env:PYTHONUNBUFFERED = "1"
        $env:HEALTH_LISTEN_ADDR = "127.0.0.1:18765"
        $env:MCP_STARTUP_WAIT_TIMEOUT = "20s"
        & (Join-Path $release "bin\tunnel-client.exe") run *>> $log
    } finally {
        $env:CONTROL_PLANE_API_KEY = $null
        $env:CONTROL_PLANE_TUNNEL_ID = $null
        $env:MCP_COMMAND = $null
        $raw = $null
    }
} finally {
    if ($locked) { $mutex.ReleaseMutex() | Out-Null }
    $mutex.Dispose()
}
'@
    Set-Content $Launch $launchContent -Encoding UTF8

    icacls $Root /inheritance:r | Out-Null
    icacls $Root /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    $actionArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $Launch
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $actionArgs
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "WindowsBridge MCP agent for ChatGPT" | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    $ready = $false
    for ($i = 0; $i -lt 45; $i++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing "$HealthBase/readyz" -TimeoutSec 2
            if ($response.StatusCode -eq 200) { $ready = $true; break }
        } catch {}
        Start-Sleep -Seconds 1
    }

    $state = (Get-ScheduledTask -TaskName $TaskName).State
    if (-not $ready) { throw "WindowsBridge started but the OpenAI tunnel did not become ready at $HealthBase/readyz." }
    if ($state -notin @("Running","Ready")) { throw "WindowsBridge startup task is not healthy: $state" }

    Copy-Item (Join-Path $releaseDir "management\update.ps1") $UpdateScript -Force
    Copy-Item (Join-Path $releaseDir "management\update-state.psm1") $UpdateStateModule -Force
    Copy-Item (Join-Path $releaseDir "management\windowsbridgectl.ps1") $ControlScript -Force
    $controlCmdContent = '@echo off' + [Environment]::NewLine + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SystemRoot%\System32\windowsbridgectl.ps1" %*'
    Set-Content $ControlCmd $controlCmdContent -Encoding ASCII

    if (-not $AutoUpdate) {
        Import-Module $UpdateStateModule -Force
        Write-WindowsBridgeUpdateState -Path $UpdateState -State "COMMITTED" -GenerationId ([guid]::NewGuid().ToString("N")) -UpdateClass "NONE" -CurrentGeneration $ResolvedRef -PreviousGeneration $previousRef -Reason "installation_completed"
    }

    if (-not $DisableAutoUpdate) {
        Stop-ScheduledTask -TaskName $AutoUpdateTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $AutoUpdateTaskName -Confirm:$false -ErrorAction SilentlyContinue
        $updateArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $UpdateScript
        $updateAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $updateArgs
        $updateTrigger = New-ScheduledTaskTrigger -Daily -At 3am
        $updatePrincipal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
        $updateSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        Register-ScheduledTask -TaskName $AutoUpdateTaskName -Action $updateAction -Trigger $updateTrigger -Principal $updatePrincipal -Settings $updateSettings -Description "Safely update WindowsBridge from the stable GitHub channel" | Out-Null
    }

    Get-ChildItem $Releases -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[0-9a-f]{40}$' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -Skip 3 |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host ""
    Write-Host "WindowsBridge installed from GitHub." -ForegroundColor Green
    Write-Host "Source commit: $ResolvedRef"
    Write-Host "OpenAI tunnel-client: $($tunnelRelease.tag_name)"
    Write-Host "Tunnel readiness: ready"
    Write-Host "Automatic updates: $(if ($DisableAutoUpdate) { 'disabled' } else { 'enabled (stable, daily)' })"
    Write-Host "Control command: windowsbridgectl check"

    if ($NeedsConnectorSetup) {
        Show-ConnectorSetup $TunnelId
    } elseif (-not $AutoUpdate) {
        Write-Host ""
        Write-Host "Existing OpenAI tunnel configuration reused; no connector setup is needed." -ForegroundColor Green
    }
} catch {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
    if ($ResolvedRef -and $ResolvedRef -ne $previousRef -and (Test-Path $releaseDir)) {
        Remove-Item $releaseDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($previousRef -and (Test-Path (Join-Path $Releases $previousRef))) {
        Set-Content $Current $previousRef -Encoding ASCII -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    } else {
        Remove-Item $Current -Force -ErrorAction SilentlyContinue
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    throw
} finally {
    $env:CONTROL_PLANE_API_KEY = $null
    $env:CONTROL_PLANE_TUNNEL_ID = $null
    $env:MCP_COMMAND = $null
    $env:UV_PYTHON_INSTALL_DIR = $null
    $env:UV_CACHE_DIR = $null
    $env:UV_PYTHON_NO_REGISTRY = $null
    $env:UV_PYTHON_INSTALL_BIN = $null
    $RuntimeApiKey = $null
    $existing = $null
    [GC]::Collect()
}
