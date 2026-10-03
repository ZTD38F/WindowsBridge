[CmdletBinding()]
param(
    [switch]$Force,
    [string]$Channel = "stable"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Root = Join-Path $env:ProgramData "WindowsBridge"
$Current = Join-Path $Root "current.txt"
$Config = Join-Path $Root "config.json"
$Logs = Join-Path $Root "logs"
$Log = Join-Path $Logs "update.log"
$Repo = "ZTD38F/WindowsBridge"
$MutexName = "Global\WindowsBridgeUpdate"

function Write-UpdateLog([string]$Message) {
    New-Item -ItemType Directory -Force -Path $Logs | Out-Null
    if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 5MB) {
        for ($i = 3; $i -ge 1; $i--) {
            $src = if ($i -eq 1) { $Log } else { "$Log." + ($i - 1) }
            $dst = "$Log.$i"
            if (Test-Path $src) { Move-Item $src $dst -Force }
        }
    }
    Add-Content -Path $Log -Value ("{0:o} {1}" -f (Get-Date), $Message) -Encoding UTF8
}

if (-not (Test-Path $Config) -or -not (Test-Path $Current)) {
    throw "WindowsBridge is not installed; automatic update has no existing credentials/state to reuse."
}

$mutex = [Threading.Mutex]::new($false, $MutexName)
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) {
        Write-UpdateLog "skip: another update is already running"
        exit 0
    }

    $currentSha = (Get-Content $Current -Raw).Trim()
    $remote = Invoke-RestMethod "https://api.github.com/repos/$Repo/commits/$Channel" -Headers @{"User-Agent"="WindowsBridge-Updater"}
    $remoteSha = [string]$remote.sha
    if ($remoteSha -notmatch '^[0-9a-f]{40}$') { throw "GitHub did not return a valid commit SHA for channel $Channel." }

    if (-not $Force -and $currentSha -eq $remoteSha) {
        Write-UpdateLog "ok: already current at $currentSha"
        exit 0
    }

    Write-UpdateLog "update: $currentSha -> $remoteSha"
    $tmp = Join-Path $env:TEMP ("WindowsBridge-update-" + [guid]::NewGuid().ToString("N") + ".ps1")
    try {
        $url = "https://raw.githubusercontent.com/$Repo/$remoteSha/install.ps1"
        Invoke-WebRequest -UseBasicParsing $url -OutFile $tmp
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp -SourceRef $remoteSha -AutoUpdate
        if ($LASTEXITCODE -ne 0) { throw "WindowsBridge installer exited with code $LASTEXITCODE." }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }

    $after = (Get-Content $Current -Raw).Trim()
    if ($after -ne $remoteSha) { throw "Update completed without activating expected commit $remoteSha." }
    Write-UpdateLog "ok: activated $after"
} catch {
    Write-UpdateLog ("error: " + $_.Exception.Message)
    throw
} finally {
    if ($locked) { $mutex.ReleaseMutex() | Out-Null }
    $mutex.Dispose()
}
