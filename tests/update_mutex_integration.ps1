$ErrorActionPreference = "Stop"

$updaterPath = Join-Path (Split-Path $PSScriptRoot -Parent) "update.ps1"
$updater = Get-Content -LiteralPath $updaterPath -Raw
if (-not $updater.Contains('$MutexName = "Global\WindowsBridgeUpdate"')) {
    throw "Updater no longer uses the expected global update mutex."
}
if (-not $updater.Contains('$mutex.WaitOne(0)')) {
    throw "Updater must acquire its mutex without waiting."
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("WindowsBridge mutex é " + [guid]::NewGuid().ToString("N"))
$readyPath = Join-Path $fixtureRoot "holder.ready"
$releasePath = Join-Path $fixtureRoot "holder.release"
$holderPath = Join-Path $fixtureRoot "hold-update-mutex.ps1"
$holder = $null
$contender = $null
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null

try {
    @'
param([string]$ReadyPath, [string]$ReleasePath)
$ErrorActionPreference = "Stop"
$mutex = [Threading.Mutex]::new($false, "Global\WindowsBridgeUpdate")
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { exit 2 }
    Set-Content -LiteralPath $ReadyPath -Value $PID -Encoding ASCII
    while (-not (Test-Path -LiteralPath $ReleasePath)) { Start-Sleep -Milliseconds 50 }
} finally {
    if ($locked) { $mutex.ReleaseMutex() | Out-Null }
    $mutex.Dispose()
}
'@ | Set-Content -LiteralPath $holderPath -Encoding UTF8

    $holder = Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $holderPath),
        "-ReadyPath", ('"{0}"' -f $readyPath),
        "-ReleasePath", ('"{0}"' -f $releasePath)
    ) -PassThru -WindowStyle Hidden

    $ready = $false
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-Path -LiteralPath $readyPath) { $ready = $true; break }
        if ($holder.HasExited) { throw "Mutex holder exited early with code $($holder.ExitCode)." }
        Start-Sleep -Milliseconds 50
    }
    if (-not $ready) { throw "Mutex holder did not become ready." }

    $contender = [Threading.Mutex]::new($false, "Global\WindowsBridgeUpdate")
    $contenderLocked = $false
    try {
        try { $contenderLocked = $contender.WaitOne(0) } catch [Threading.AbandonedMutexException] { $contenderLocked = $true }
        if ($contenderLocked) { throw "A concurrent updater acquired the global mutex." }
    } finally {
        if ($contenderLocked) { $contender.ReleaseMutex() | Out-Null }
        $contender.Dispose()
        $contender = $null
    }

    Set-Content -LiteralPath $releasePath -Value "release" -Encoding ASCII
    if (-not $holder.WaitForExit(5000)) { throw "Mutex holder did not exit after release." }
    if ($holder.ExitCode -ne 0) { throw "Mutex holder failed with code $($holder.ExitCode)." }

    $after = [Threading.Mutex]::new($false, "Global\WindowsBridgeUpdate")
    $afterLocked = $false
    try {
        try { $afterLocked = $after.WaitOne(0) } catch [Threading.AbandonedMutexException] { $afterLocked = $true }
        if (-not $afterLocked) { throw "Mutex remained locked after the owner exited." }
    } finally {
        if ($afterLocked) { $after.ReleaseMutex() | Out-Null }
        $after.Dispose()
    }

    Write-Host "Concurrent updater suppression passed."
} finally {
    if ($null -ne $contender) { $contender.Dispose() }
    if ($null -ne $holder -and -not $holder.HasExited) {
        Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
        $holder.WaitForExit()
    }
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
