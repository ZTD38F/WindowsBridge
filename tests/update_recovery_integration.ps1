$ErrorActionPreference = "Stop"

function Assert-Equal([object]$Expected, [object]$Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected=[$Expected] Actual=[$Actual]"
    }
}

$originalProgramData = $env:ProgramData
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("WindowsBridge recovery é " + [guid]::NewGuid().ToString("N"))
try {
    $env:ProgramData = $fixtureRoot
    $updaterPath = Join-Path (Split-Path $PSScriptRoot -Parent) "update.ps1"
    $source = Get-Content -LiteralPath $updaterPath -Raw
    $marker = 'if (-not (Test-Path $Config) -or -not (Test-Path $Current))'
    $markerIndex = $source.IndexOf($marker)
    if ($markerIndex -lt 0) { throw "Updater function boundary was not found." }
    Invoke-Expression $source.Substring(0, $markerIndex)

    New-Item -ItemType Directory -Force -Path $State,$Releases,$Management | Out-Null
    $previous = "1111111111111111111111111111111111111111"
    $candidate = "2222222222222222222222222222222222222222"
    $phases = @(
        "STAGED",
        "DEFERRED_STATEFUL_HANDLES",
        "CANDIDATE_STARTING",
        "FAILED_PRE_SWITCH",
        "CANDIDATE_HEALTHY",
        "SWITCHED",
        "DRAINING_OLD",
        "OBSERVING"
    )

    foreach ($phase in $phases) {
        Set-Content -LiteralPath $Current -Value $candidate -Encoding ASCII
        Set-Route $candidate 18772
        Set-Content -LiteralPath $ServerPidFile -Value 999999 -Encoding ASCII
        [ordered]@{
            transaction_id = [guid]::NewGuid().ToString("N")
            update_kind = "RUNTIME_UPDATE"
            phase = $phase
            current_generation = $candidate
            candidate_generation = $candidate
            previous_generation = $previous
            previous_port = 18771
            previous_pid = $PID
            candidate_port = 18772
            candidate_pid = 0
            failure_reason = ""
            rollback_reason = ""
            updated_at = (Get-Date).ToString("o")
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $Journal -Encoding UTF8

        Recover-Unfinished

        $route = Get-Content -LiteralPath $RouteFile -Raw | ConvertFrom-Json
        $journalState = Get-Content -LiteralPath $Journal -Raw | ConvertFrom-Json
        Assert-Equal $previous ((Get-Content -LiteralPath $Current -Raw).Trim()) "$phase must restore current.txt."
        Assert-Equal $previous $route.generation "$phase must restore the previous route."
        Assert-Equal 18771 $route.port "$phase must restore the previous port."
        Assert-Equal $PID ((Get-Content -LiteralPath $ServerPidFile -Raw).Trim()) "$phase must restore the previous backend PID."
        Assert-Equal "FAILED_ROLLED_BACK" $journalState.phase "$phase must finish as rolled back."
        Assert-Equal $previous $journalState.current_generation "$phase must report the restored generation."
        Assert-Equal "interrupted update recovered" $journalState.rollback_reason "$phase must record the recovery reason."
        if (Test-Path -LiteralPath "$Journal.tmp") { throw "$phase left a partial recovery journal." }
    }

    Write-Host "Interrupted update recovery matrix passed."
} finally {
    $env:ProgramData = $originalProgramData
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
