#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$TunnelId,
    [string]$RuntimeApiKey,
    [string]$SourceRef = "main"
)

$ErrorActionPreference = "Stop"
$Root = Join-Path $env:ProgramData "WindowsBridge"
$App = Join-Path $Root "app"
$Bin = Join-Path $Root "bin"
$Logs = Join-Path $Root "logs"
$Venv = Join-Path $Root "venv"
$Config = Join-Path $Root "config.json"
$Launch = Join-Path $Root "launch.ps1"
$TaskName = "WindowsBridge"
$RepoRaw = "https://raw.githubusercontent.com/ZTD38F/WindowsBridge/$SourceRef"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function ConvertFrom-Secure([Security.SecureString]$Secure) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Find-Python {
    $candidates = @(
        "$env:ProgramFiles\Python312\python.exe",
        "$env:ProgramFiles\Python313\python.exe",
        "$env:LocalAppData\Programs\Python\Python312\python.exe",
        "$env:LocalAppData\Programs\Python\Python313\python.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

if (-not $TunnelId) { $TunnelId = Read-Host "OpenAI Tunnel ID (tunnel_...)" }
if (-not $RuntimeApiKey) {
    $secure = Read-Host "OpenAI Runtime API key" -AsSecureString
    $RuntimeApiKey = ConvertFrom-Secure $secure
}
if ($TunnelId -notmatch '^tunnel_[A-Za-z0-9_-]+$') { throw "Invalid Tunnel ID" }
if ([string]::IsNullOrWhiteSpace($RuntimeApiKey)) { throw "Runtime API key is required" }

New-Item -ItemType Directory -Force -Path $Root,$App,$Bin,$Logs | Out-Null

$Python = Find-Python
if (-not $Python) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { throw "Python is missing and winget is unavailable" }
    winget install --id Python.Python.3.12 --scope machine -e --accept-source-agreements --accept-package-agreements
    $Python = Find-Python
    if (-not $Python) { throw "Python installation completed but python.exe was not found" }
}

$LocalAgent = Join-Path $ScriptDir "windowsbridge.py"
$LocalRequirements = Join-Path $ScriptDir "requirements.txt"
if ((Test-Path $LocalAgent) -and (Test-Path $LocalRequirements)) {
    Write-Host "Installing WindowsBridge agent from local package..."
    Copy-Item $LocalAgent (Join-Path $App "windowsbridge.py") -Force
    Copy-Item $LocalRequirements (Join-Path $App "requirements.txt") -Force
} else {
    Write-Host "Downloading WindowsBridge agent..."
    Invoke-WebRequest "$RepoRaw/windowsbridge.py" -OutFile (Join-Path $App "windowsbridge.py") -UseBasicParsing
    Invoke-WebRequest "$RepoRaw/requirements.txt" -OutFile (Join-Path $App "requirements.txt") -UseBasicParsing
}

if (Test-Path $Venv) { Remove-Item $Venv -Recurse -Force }
& $Python -m venv $Venv
$VenvPython = Join-Path $Venv "Scripts\python.exe"
& $VenvPython -m pip install --disable-pip-version-check --upgrade pip
& $VenvPython -m pip install --disable-pip-version-check -r (Join-Path $App "requirements.txt")

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
$release = Invoke-RestMethod "https://api.github.com/repos/openai/tunnel-client/releases/latest" -Headers @{"User-Agent"="WindowsBridge-Installer"}
$tag = $release.tag_name
$pattern = "^tunnel-client-$([regex]::Escape($tag))-windows-$arch\.zip$"
$asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
if (-not $asset) { throw "Could not find official tunnel-client Windows $arch asset in release $tag" }
$tmpZip = Join-Path $env:TEMP "windowsbridge-tunnel.zip"
$tmpDir = Join-Path $env:TEMP "windowsbridge-tunnel"
Remove-Item $tmpZip,$tmpDir -Recurse -Force -ErrorAction SilentlyContinue
Invoke-WebRequest $asset.browser_download_url -OutFile $tmpZip -UseBasicParsing
Expand-Archive $tmpZip -DestinationPath $tmpDir -Force
$tunnel = Get-ChildItem $tmpDir -Filter "tunnel-client.exe" -Recurse | Select-Object -First 1
if (-not $tunnel) { throw "tunnel-client.exe was not found in the official archive" }
Copy-Item $tunnel.FullName (Join-Path $Bin "tunnel-client.exe") -Force
$cloudflared = Get-ChildItem $tmpDir -Filter "cloudflared.exe" -Recurse | Select-Object -First 1
if ($cloudflared) { Copy-Item $cloudflared.FullName (Join-Path $Bin "cloudflared.exe") -Force }

$keyBytes = [Text.Encoding]::UTF8.GetBytes($RuntimeApiKey)
$protected = [Security.Cryptography.ProtectedData]::Protect($keyBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
$configObj = [ordered]@{
    version = "0.1.0"
    tunnel_id = $TunnelId
    api_key_dpapi = [Convert]::ToBase64String($protected)
    installed_at = (Get-Date).ToString("o")
}
$configObj | ConvertTo-Json | Set-Content $Config -Encoding UTF8

$launchContent = @'
$ErrorActionPreference = "Stop"
$Root = Join-Path $env:ProgramData "WindowsBridge"
$cfg = Get-Content (Join-Path $Root "config.json") -Raw | ConvertFrom-Json
$enc = [Convert]::FromBase64String($cfg.api_key_dpapi)
$raw = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
$env:CONTROL_PLANE_API_KEY = [Text.Encoding]::UTF8.GetString($raw)
$env:CONTROL_PLANE_TUNNEL_ID = $cfg.tunnel_id
$env:MCP_COMMAND = '"' + (Join-Path $Root "venv\Scripts\python.exe") + '" "' + (Join-Path $Root "app\windowsbridge.py") + '"'
$env:WINDOWSBRIDGE_ALLOWED_ROOTS = "*"
$env:PYTHONUNBUFFERED = "1"
$tunnel = Join-Path $Root "bin\tunnel-client.exe"
$log = Join-Path $Root "logs\tunnel.log"
& $tunnel run *>> $log
'@
Set-Content $Launch $launchContent -Encoding UTF8

icacls $Root /inheritance:r | Out-Null
icacls $Root /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" | Out-Null

$env:CONTROL_PLANE_API_KEY = $RuntimeApiKey
$env:CONTROL_PLANE_TUNNEL_ID = $TunnelId
$env:MCP_COMMAND = '"' + $VenvPython + '" "' + (Join-Path $App "windowsbridge.py") + '"'
Write-Host "Validating Secure MCP Tunnel..."
& (Join-Path $Bin "tunnel-client.exe") doctor --explain
if ($LASTEXITCODE -ne 0) { throw "tunnel-client doctor failed" }

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Launch`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "WindowsBridge MCP agent for ChatGPT" | Out-Null
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
$state = (Get-ScheduledTask -TaskName $TaskName).State

$RuntimeApiKey = $null
$env:CONTROL_PLANE_API_KEY = $null
Write-Host ""
Write-Host "WindowsBridge installed." -ForegroundColor Green
Write-Host "Task: $TaskName ($state)"
Write-Host "Root: $Root"
Write-Host "Next: ChatGPT -> Settings -> Connectors -> select tunnel $TunnelId -> rescan tools."
