$ErrorActionPreference = "Stop"

function Assert-Equal([object]$Expected, [object]$Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected=[$Expected] Actual=[$Actual]"
    }
}

function Assert-NotEqual([object]$Unexpected, [object]$Actual, [string]$Message) {
    if ([string]$Unexpected -eq [string]$Actual) {
        throw "$Message Both=[$Actual]"
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

    # Isolate recovery ordering without touching real runner processes. The
    # production recovery functions still perform all filesystem state changes.
    $script:fakeProcesses = @{}
    $script:healthyPorts = @{}
    $script:recoveryEvents = [Collections.Generic.List[string]]::new()
    $script:routeGuardEnabled = $false
    $script:nextProcessId = 700000

    function Test-ProcessId([object]$Value) {
        return $script:fakeProcesses.ContainsKey([int]$Value)
    }

    function Test-Backend([int]$Port) {
        return $script:healthyPorts.ContainsKey($Port)
    }

    function Start-Backend([string]$Release, [int]$Port) {
        if (-not (Test-Path -LiteralPath (Join-Path $Release "app\http_runtime.py") -PathType Leaf)) {
            throw "Fixture runtime is missing."
        }
        $script:nextProcessId += 1
        $script:fakeProcesses[$script:nextProcessId] = $Port
        $script:healthyPorts[$Port] = $true
        $script:recoveryEvents.Add("start:$Port") | Out-Null
        return [pscustomobject]@{ Id = $script:nextProcessId }
    }

    function Stop-Pid([int]$ProcessId) {
        if ($script:fakeProcesses.ContainsKey($ProcessId)) {
            $port = [int]$script:fakeProcesses[$ProcessId]
            $script:fakeProcesses.Remove($ProcessId)
            if (-not ($script:fakeProcesses.Values -contains $port)) {
                $script:healthyPorts.Remove($port)
            }
        }
        $script:recoveryEvents.Add("stop:$ProcessId") | Out-Null
    }

    function Set-Route([string]$Generation, [int]$Port) {
        if ($script:routeGuardEnabled -and -not (Test-Backend $Port)) {
            throw "Recovery attempted to route to an unhealthy backend."
        }
        $script:recoveryEvents.Add("route:$Port") | Out-Null
        $tmp = "$RouteFile.tmp"
        [ordered]@{ generation = $Generation; port = $Port } | ConvertTo-Json -Compress | Set-Content $tmp -Encoding ASCII
        Move-Item $tmp $RouteFile -Force
    }

    New-Item -ItemType Directory -Force -Path $State,$Releases,$Management | Out-Null
    $previous = "1111111111111111111111111111111111111111"
    $candidate = "2222222222222222222222222222222222222222"
    Write-State "STAGED" $previous $candidate $previous 18771 $PID 18772 0
    $firstTransaction = (Get-Content -LiteralPath $Journal -Raw | ConvertFrom-Json).transaction_id
    Write-State "COMMITTED" $previous $candidate $previous 18771 $PID 18772 0
    $committedTransaction = (Get-Content -LiteralPath $Journal -Raw | ConvertFrom-Json).transaction_id
    Assert-Equal $firstTransaction $committedTransaction "One update must keep its transaction ID."

    $nextCandidate = "3333333333333333333333333333333333333333"
    Write-State "STAGED" $candidate $nextCandidate $candidate 18772 $PID 18771 0
    $secondTransaction = (Get-Content -LiteralPath $Journal -Raw | ConvertFrom-Json).transaction_id
    Assert-NotEqual $firstTransaction $secondTransaction "A new staged update must start a new transaction."
    Write-State "CANDIDATE_STARTING" $candidate $nextCandidate $candidate 18772 $PID 18771 0
    Assert-Equal $secondTransaction ((Get-Content -LiteralPath $Journal -Raw | ConvertFrom-Json).transaction_id) "Later phases must retain the new transaction ID."

    # A candidate that fails health or MCP compatibility before the route switch
    # must be retired immediately instead of occupying the inactive backend port.
    $failedCandidatePid = 720001
    $script:fakeProcesses[$failedCandidatePid] = 18771
    Write-State "CANDIDATE_STARTING" $candidate $nextCandidate $candidate 18772 $PID 18771 $failedCandidatePid
    Fail-CandidateBeforeSwitch $failedCandidatePid $candidate $nextCandidate $candidate 18772 $PID 18771 "fixture schema mismatch"
    $preSwitchFailure = Get-Content -LiteralPath $Journal -Raw | ConvertFrom-Json
    if (Test-ProcessId $failedCandidatePid) { throw "Failed pre-switch candidate remained alive." }
    Assert-Equal "FAILED_PRE_SWITCH" $preSwitchFailure.phase "Pre-switch failure phase was not recorded."
    Assert-Equal "fixture schema mismatch" $preSwitchFailure.failure_reason "Pre-switch failure reason was not recorded."

    $activation = $source.Substring($markerIndex)
    $candidateStart = $activation.IndexOf('$candidatePid=0')
    $preSwitchCatch = $activation.IndexOf('Fail-CandidateBeforeSwitch $candidatePid', $candidateStart)
    $routeSwitch = $activation.IndexOf('Set-Route $targetSha $candidatePort', $candidateStart)
    if ($candidateStart -lt 0 -or $preSwitchCatch -le $candidateStart -or $routeSwitch -le $preSwitchCatch) {
        throw "Candidate cleanup must be wired before the route switch."
    }

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
        $script:fakeProcesses.Clear()
        $script:healthyPorts.Clear()
        $script:recoveryEvents.Clear()
        $script:fakeProcesses[$PID] = 18771
        $script:healthyPorts[18771] = $true
        $script:healthyPorts[18772] = $true
        $script:routeGuardEnabled = $false
        Set-Content -LiteralPath $Current -Value $candidate -Encoding ASCII
        Set-Route $candidate 18772
        $script:routeGuardEnabled = $true
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

    # Reproduce the crash case where routing had switched but the old backend
    # died before the updater could commit. Recovery must restart and verify the
    # previous immutable generation before exposing its route.
    $previousRelease = Join-Path $Releases $previous
    New-Item -ItemType Directory -Force -Path (Join-Path $previousRelease "app"),(Join-Path $previousRelease "venv\Scripts") | Out-Null
    Set-Content -LiteralPath (Join-Path $previousRelease "app\http_runtime.py") -Value "# fixture" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $previousRelease "venv\Scripts\python.exe") -Value "fixture" -Encoding ASCII

    $deadPreviousPid = 710001
    $candidatePid = 710002
    $script:fakeProcesses.Clear()
    $script:healthyPorts.Clear()
    $script:recoveryEvents.Clear()
    $script:fakeProcesses[$candidatePid] = 18772
    $script:healthyPorts[18772] = $true
    $script:routeGuardEnabled = $false
    Set-Content -LiteralPath $Current -Value $candidate -Encoding ASCII
    Set-Route $candidate 18772
    $script:recoveryEvents.Clear()
    $script:routeGuardEnabled = $true
    [ordered]@{
        transaction_id = [guid]::NewGuid().ToString("N")
        update_kind = "RUNTIME_UPDATE"
        phase = "SWITCHED"
        current_generation = $previous
        candidate_generation = $candidate
        previous_generation = $previous
        previous_port = 18771
        previous_pid = $deadPreviousPid
        candidate_port = 18772
        candidate_pid = $candidatePid
        failure_reason = ""
        rollback_reason = ""
        updated_at = (Get-Date).ToString("o")
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $Journal -Encoding UTF8

    Recover-Unfinished

    $restartedPid = [int](Get-Content -LiteralPath $ServerPidFile -Raw).Trim()
    $deadRecovery = Get-Content -LiteralPath $Journal -Raw | ConvertFrom-Json
    $events = @($script:recoveryEvents)
    $startIndex = [Array]::IndexOf($events, "start:18771")
    $routeIndex = [Array]::IndexOf($events, "route:18771")
    $stopIndex = [Array]::IndexOf($events, "stop:$candidatePid")
    if ($startIndex -lt 0 -or $routeIndex -le $startIndex -or $stopIndex -le $routeIndex) {
        throw "Recovery order must be start previous -> route previous -> stop candidate. Events=$($events -join ',')"
    }
    Assert-Equal $previous ((Get-Content -LiteralPath $Current -Raw).Trim()) "Dead-backend recovery must restore current generation."
    Assert-Equal 18771 ((Get-Content -LiteralPath $RouteFile -Raw | ConvertFrom-Json).port) "Dead-backend recovery must restore route."
    Assert-Equal $restartedPid $deadRecovery.previous_pid "Recovery journal must record the restarted backend PID."
    Assert-Equal "interrupted update recovered; previous backend restarted" $deadRecovery.rollback_reason "Recovery must report the backend restart."
    if (-not (Test-ProcessId $restartedPid) -or -not (Test-Backend 18771)) { throw "Restarted previous backend is not healthy." }
    if (Test-ProcessId $candidatePid) { throw "Candidate remained alive after rollback." }

    Write-Host "Interrupted update recovery matrix passed."
} finally {
    $env:ProgramData = $originalProgramData
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
