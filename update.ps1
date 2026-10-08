[CmdletBinding()]
param(
    [switch]$Force,
    [string]$Channel = "stable"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Root = Join-Path $env:ProgramData "WindowsBridge"
$Releases = Join-Path $Root "releases"
$State = Join-Path $Root "state"
$Secrets = Join-Path $Root "secrets"
$Management = Join-Path $Root "management"
$Current = Join-Path $Root "current.txt"
$Config = Join-Path $Root "config.json"
$RouteFile = Join-Path $State "route.json"
$Journal = Join-Path $State "update.json"
$ServerPidFile = Join-Path $State "server.pid"
$SupervisorPidFile = Join-Path $State "supervisor.pid"
$TunnelPidFile = Join-Path $State "tunnel.pid"
$RouterTokenFile = Join-Path $Secrets "router_token"
$BackendTokenFile = Join-Path $Secrets "backend_token"
$RuntimeKeyFile = Join-Path $Secrets "control_plane_api_key"
$Log = Join-Path $Root "logs\update.log"
$Repo = "ZTD38F/WindowsBridge"
$TaskName = "WindowsBridge"
$MutexName = "Global\WindowsBridgeUpdate"
$RouterBase = "http://127.0.0.1:18766"
$TunnelHealth = "http://127.0.0.1:18765"
$script:ResolvedRelease = $null

function Log([string]$Message) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Log) | Out-Null
    Add-Content -Path $Log -Value ("{0:o} {1}" -f (Get-Date), $Message) -Encoding UTF8
}

function Test-ProcessId([object]$Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $false }
    $n = 0
    if (-not [int]::TryParse([string]$Value, [ref]$n)) { return $false }
    return $null -ne (Get-Process -Id $n -ErrorAction SilentlyContinue)
}

function Read-Pid([string]$Path) {
    if (-not (Test-Path $Path)) { return 0 }
    $v = (Get-Content $Path -Raw).Trim()
    $n = 0
    if ([int]::TryParse($v, [ref]$n)) { return $n }
    return 0
}

function Assert-TunnelContinuity([int]$ExpectedProcessId) {
    $actualProcessId = Read-Pid $TunnelPidFile
    if ($ExpectedProcessId -le 0 -or $actualProcessId -ne $ExpectedProcessId -or -not (Test-ProcessId $ExpectedProcessId)) {
        throw "Tunnel transport continuity was lost during an ordinary runtime update."
    }
}

function Get-Route {
    if (-not (Test-Path $RouteFile)) { throw "route state is missing" }
    return Get-Content $RouteFile -Raw | ConvertFrom-Json
}

function Set-Route([string]$Generation, [int]$Port) {
    $tmp = "$RouteFile.tmp"
    [ordered]@{ generation = $Generation; port = $Port } | ConvertTo-Json -Compress | Set-Content $tmp -Encoding ASCII
    Move-Item $tmp $RouteFile -Force
}

function Write-State(
    [string]$Phase,
    [string]$CurrentGeneration,
    [string]$CandidateGeneration,
    [string]$PreviousGeneration,
    [int]$PreviousPort,
    [int]$PreviousPid,
    [int]$CandidatePort,
    [int]$CandidatePid,
    [string]$Failure = "",
    [string]$Rollback = ""
) {
    $transaction = [guid]::NewGuid().ToString("N")
    if ($Phase -ne "STAGED" -and (Test-Path $Journal)) {
        try {
            $old = Get-Content $Journal -Raw | ConvertFrom-Json
            if ($old.transaction_id) { $transaction = [string]$old.transaction_id }
        } catch {}
    }
    $tmp = "$Journal.tmp"
    [ordered]@{
        transaction_id = $transaction
        update_kind = "RUNTIME_UPDATE"
        phase = $Phase
        current_generation = $CurrentGeneration
        candidate_generation = $CandidateGeneration
        previous_generation = $PreviousGeneration
        previous_port = $PreviousPort
        previous_pid = $PreviousPid
        candidate_port = $CandidatePort
        candidate_pid = $CandidatePid
        failure_reason = $Failure
        rollback_reason = $Rollback
        updated_at = (Get-Date).ToString("o")
    } | ConvertTo-Json -Compress | Set-Content $tmp -Encoding UTF8
    Move-Item $tmp $Journal -Force
}

function Invoke-LocalJson([string]$Url, [string]$HeaderName, [string]$SecretFile, [string]$Method = "GET", [object]$Body = $null) {
    $secret = (Get-Content $SecretFile -Raw).Trim()
    $headers = @{}
    $headers[$HeaderName] = $secret
    if ($null -eq $Body) {
        return Invoke-RestMethod -Uri $Url -Method $Method -Headers $headers -TimeoutSec 8
    }
    $headers["Accept"] = "application/json, text/event-stream"
    return Invoke-RestMethod -Uri $Url -Method $Method -Headers $headers -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 40 -Compress) -TimeoutSec 15
}

function Get-Tools([string]$Base, [string]$HeaderName, [string]$SecretFile) {
    $init = @{ jsonrpc="2.0"; id=1; method="initialize"; params=@{ protocolVersion="2025-06-18"; capabilities=@{}; clientInfo=@{name="WindowsBridgeUpdater";version="1"} } }
    $null = Invoke-LocalJson "$Base/mcp" $HeaderName $SecretFile "POST" $init
    $list = Invoke-LocalJson "$Base/mcp" $HeaderName $SecretFile "POST" @{ jsonrpc="2.0"; id=2; method="tools/list"; params=@{} }
    return @($list.result.tools)
}

function Assert-CompatibleTools([object[]]$OldTools, [object[]]$NewTools) {
    $new = @{}
    foreach ($t in $NewTools) { $new[[string]$t.name] = ($t.inputSchema | ConvertTo-Json -Depth 50 -Compress) }
    $missing = @()
    $changed = @()
    foreach ($t in $OldTools) {
        $name = [string]$t.name
        if (-not $new.ContainsKey($name)) { $missing += $name; continue }
        $schema = $t.inputSchema | ConvertTo-Json -Depth 50 -Compress
        if ($new[$name] -ne $schema) { $changed += $name }
    }
    if ($missing.Count -or $changed.Count) {
        throw "Breaking MCP tool contract. Missing=$($missing -join ',') Changed=$($changed -join ',')"
    }
}

function Test-Backend([int]$Port) {
    try {
        $r = Invoke-LocalJson "http://127.0.0.1:$Port/healthz" "X-Bridge-Backend-Token" $BackendTokenFile
        return $r.ok -eq $true
    } catch { return $false }
}

function Start-Backend([string]$Release, [int]$Port) {
    $python = Join-Path $Release "venv\Scripts\python.exe"
    $env:WINDOWSBRIDGE_BACKEND_TOKEN_FILE = $BackendTokenFile
    try {
        return Start-Process -FilePath $python -ArgumentList @((Join-Path $Release "app\http_runtime.py"),"--port",[string]$Port) -WindowStyle Hidden -PassThru
    } finally {
        $env:WINDOWSBRIDGE_BACKEND_TOKEN_FILE = $null
    }
}

function Stop-Pid([int]$ProcessId) {
    if ($ProcessId -gt 0) { Stop-Process -Id $ProcessId -ErrorAction SilentlyContinue }
}

function Fail-CandidateBeforeSwitch(
    [int]$CandidatePid,
    [string]$CurrentGeneration,
    [string]$CandidateGeneration,
    [string]$PreviousGeneration,
    [int]$PreviousPort,
    [int]$PreviousPid,
    [int]$CandidatePort,
    [string]$Reason
) {
    Stop-Pid $CandidatePid
    Write-State "FAILED_PRE_SWITCH" $CurrentGeneration $CandidateGeneration $PreviousGeneration $PreviousPort $PreviousPid $CandidatePort $CandidatePid $Reason
}

function Restore-PreviousBackend([object]$JournalState) {
    $generation = [string]$JournalState.previous_generation
    $port = [int]$JournalState.previous_port
    $processId = [int]$JournalState.previous_pid
    if ($generation -notmatch '^[0-9a-f]{40}$' -or $port -le 0) {
        throw "Interrupted update has invalid previous generation state."
    }
    if ((Test-ProcessId $processId) -and (Test-Backend $port)) {
        return [pscustomobject]@{ process_id = $processId; restarted = $false }
    }

    Stop-Pid $processId
    $release = Join-Path $Releases $generation
    $runtime = Join-Path $release "app\http_runtime.py"
    $python = Join-Path $release "venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $runtime -PathType Leaf) -or -not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw "Previous generation cannot be restarted because its immutable runtime is incomplete."
    }

    Log "Restarting previous generation $generation on port $port before rollback"
    $process = Start-Backend $release $port
    for ($i = 0; $i -lt 40; $i++) {
        if ((Test-ProcessId $process.Id) -and (Test-Backend $port)) {
            return [pscustomobject]@{ process_id = [int]$process.Id; restarted = $true }
        }
        Start-Sleep -Milliseconds 250
    }
    Stop-Pid ([int]$process.Id)
    throw "Previous generation failed to become healthy; route was not changed."
}

function Recover-Unfinished {
    if (-not (Test-Path $Journal)) { return }
    try { $j = Get-Content $Journal -Raw | ConvertFrom-Json } catch { return }
    if ($j.phase -in @("COMMITTED","FAILED_ROLLED_BACK","")) { return }
    Log "Recovering interrupted update phase=$($j.phase)"

    # A rollback route must never point at a dead backend. Restore and verify the
    # previous immutable generation first, then switch routing at the boundary.
    $restored = Restore-PreviousBackend $j
    Set-Route ([string]$j.previous_generation) ([int]$j.previous_port)
    if ([int]$j.candidate_pid -ne [int]$restored.process_id) {
        Stop-Pid ([int]$j.candidate_pid)
    }
    Set-Content $Current ([string]$j.previous_generation) -Encoding ASCII
    Set-Content $ServerPidFile ([int]$restored.process_id) -Encoding ASCII

    $j.phase = "FAILED_ROLLED_BACK"
    $j.current_generation = [string]$j.previous_generation
    $j.previous_pid = [int]$restored.process_id
    $j.rollback_reason = if ($restored.restarted) {
        "interrupted update recovered; previous backend restarted"
    } else {
        "interrupted update recovered"
    }
    $j.updated_at = (Get-Date).ToString("o")
    $tmp = "$Journal.tmp"
    $j | ConvertTo-Json -Depth 10 -Compress | Set-Content $tmp -Encoding UTF8
    Move-Item $tmp $Journal -Force
}

function Resolve-Target([string]$Ref) {
    $headers = @{"User-Agent"="WindowsBridge-Updater"}
    $resolved = $Ref
    $script:ResolvedRelease = $null
    if ($Ref -eq "stable") {
        $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers
        if ($release.draft -or $release.prerelease) { throw "Latest stable release is not eligible for automatic update." }
        $resolved = [string]$release.tag_name
        $script:ResolvedRelease = $release
    }
    $remote = Invoke-RestMethod "https://api.github.com/repos/$Repo/commits/$resolved" -Headers $headers
    $sha = [string]$remote.sha
    if ($sha -notmatch '^[0-9a-f]{40}$') { throw "Invalid GitHub commit SHA." }
    return $sha
}

function Remove-StaleReleaseStages {
    $cutoff = (Get-Date).ToUniversalTime().AddHours(-24)
    Get-ChildItem -LiteralPath $Releases -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ".stage-*" -and $_.LastWriteTimeUtc -lt $cutoff } |
        ForEach-Object {
            Log "Removing stale release stage $($_.Name)"
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        }
}

function Assert-ReleaseAssetDigest([object]$Asset, [string]$Path) {
    if (-not $Asset -or [string]$Asset.digest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
        throw "Release asset is missing a valid SHA-256 digest."
    }
    $expected = ([string]$Asset.digest).Substring(7).ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "Release asset digest mismatch: $($Asset.name)" }
}

function Copy-VerifiedReleaseBundle([object]$Release, [string]$Sha, [string]$Stage) {
    if (-not $Release -or [string]$Release.tag_name -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "Stable release metadata is invalid."
    }
    $zipName = "WindowsBridge-$($Release.tag_name).zip"
    $zipAsset = $Release.assets | Where-Object { $_.name -eq $zipName } | Select-Object -First 1
    $manifestAsset = $Release.assets | Where-Object { $_.name -eq "bridge-release.json" } | Select-Object -First 1
    if (-not $zipAsset -or -not $manifestAsset) { throw "Required stable release assets are missing." }

    $bundle = Join-Path $Stage ".bundle"
    $expanded = Join-Path $bundle "expanded"
    New-Item -ItemType Directory -Force -Path $bundle,$expanded | Out-Null
    $zipPath = Join-Path $bundle $zipName
    $manifestPath = Join-Path $bundle "bridge-release.json"
    Invoke-WebRequest -UseBasicParsing $zipAsset.browser_download_url -OutFile $zipPath
    Invoke-WebRequest -UseBasicParsing $manifestAsset.browser_download_url -OutFile $manifestPath
    Assert-ReleaseAssetDigest $zipAsset $zipPath
    Assert-ReleaseAssetDigest $manifestAsset $manifestPath

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string]$manifest.bridge -ne "WindowsBridge" -or [string]$manifest.source_commit -ne $Sha) {
        throw "Release manifest identity does not match the resolved commit."
    }
    if ([string]$manifest.tag -ne [string]$Release.tag_name -or [string]$manifest.update_kind -ne "runtime") {
        throw "Release manifest tag or update kind is incompatible."
    }
    if ([int]$manifest.supervisor_protocol -ne 1 -or [int]$manifest.config_schema -ne 1 -or [int]$manifest.state_schema -ne 2) {
        throw "Release manifest declares an unsupported protocol or schema."
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $expanded -Force
    foreach ($name in @("windowsbridge.py","http_runtime.py","requirements.lock")) {
        $source = Join-Path $expanded $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Release bundle is missing $name." }
        Copy-Item -LiteralPath $source -Destination (Join-Path $Stage "app\$name")
    }
    foreach ($name in @("update.ps1","windowsbridgectl.ps1","supervisor.py")) {
        $source = Join-Path $expanded $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Release bundle is missing $name." }
        Copy-Item -LiteralPath $source -Destination (Join-Path $Stage "management\$name")
    }
}

function Stage-Release([string]$Sha) {
    $release = Join-Path $Releases $Sha
    if (Test-Path (Join-Path $release "app\http_runtime.py")) { return $release }
    $stage = Join-Path $Releases (".stage-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $stage "app"),(Join-Path $stage "management") | Out-Null
        if ($null -ne $script:ResolvedRelease) {
            Copy-VerifiedReleaseBundle $script:ResolvedRelease $Sha $stage
        } else {
            $base = "https://raw.githubusercontent.com/$Repo/$Sha"
            foreach ($name in @("windowsbridge.py","http_runtime.py","requirements.lock")) {
                Invoke-WebRequest -UseBasicParsing "$base/$name" -OutFile (Join-Path $stage "app\$name")
            }
            foreach ($name in @("update.ps1","windowsbridgectl.ps1","supervisor.py")) {
                Invoke-WebRequest -UseBasicParsing "$base/$name" -OutFile (Join-Path $stage "management\$name")
            }
        }
        $uv = Join-Path $Root "bin\uv.exe"
        if (-not (Test-Path $uv)) { throw "Managed uv runtime is missing." }
        $env:UV_PYTHON_INSTALL_DIR = Join-Path $Root "runtime\python"
        $env:UV_CACHE_DIR = Join-Path $Root "cache\uv"
        $env:UV_PYTHON_NO_REGISTRY = "1"
        $env:UV_PYTHON_INSTALL_BIN = "0"
        & $uv venv --python 3.12 (Join-Path $stage "venv")
        if ($LASTEXITCODE -ne 0) { throw "uv venv failed." }
        $python = Join-Path $stage "venv\Scripts\python.exe"
        & $uv pip install --python $python -r (Join-Path $stage "app\requirements.lock")
        if ($LASTEXITCODE -ne 0) { throw "dependency install failed." }
        & $python -m py_compile (Join-Path $stage "app\windowsbridge.py") (Join-Path $stage "app\http_runtime.py") (Join-Path $stage "management\supervisor.py")
        if ($LASTEXITCODE -ne 0) { throw "candidate compile failed." }
        Move-Item $stage $release
        return $release
    } finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Ensure-NewTopology([string]$Target) {
    if ((Test-Path $RouteFile) -and (Test-ProcessId (Read-Pid $SupervisorPidFile))) { return }
    Log "One-time migration from stdio topology"
    $tmp = Join-Path $env:TEMP ("WindowsBridge-migrate-" + [guid]::NewGuid().ToString("N") + ".ps1")
    try {
        Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/$Repo/$Target/install.ps1" -OutFile $tmp
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp -SourceRef $Target -AutoUpdate
        if ($LASTEXITCODE -ne 0) { throw "Topology migration installer failed." }
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    exit 0
}

function Update-Supervisor([string]$CandidateFile) {
    $currentFile = Join-Path $Management "supervisor.py"
    if ((Test-Path $currentFile) -and ((Get-FileHash $currentFile).Hash -eq (Get-FileHash $CandidateFile).Hash)) { return }
    $status = Invoke-LocalJson "$RouterBase/__bridge/status" "X-Bridge-Token" $RouterTokenFile
    $busy = 0; foreach ($p in $status.inflight.PSObject.Properties) { $busy += [int]$p.Value }
    if ($busy -ne 0) { Log "Supervisor update deferred: inflight=$busy"; return }
    $backup = "$currentFile.previous"
    if (Test-Path $currentFile) { Copy-Item $currentFile $backup -Force }
    $oldPid = Read-Pid $SupervisorPidFile
    Stop-Pid $oldPid
    Copy-Item $CandidateFile $currentFile -Force
    $ref = (Get-Content $Current -Raw).Trim()
    $python = Join-Path (Join-Path $Releases $ref) "venv\Scripts\python.exe"
    $env:WINDOWSBRIDGE_ROOT = $Root
    try { $p = Start-Process -FilePath $python -ArgumentList @($currentFile) -WindowStyle Hidden -PassThru }
    finally { $env:WINDOWSBRIDGE_ROOT = $null }
    Set-Content $SupervisorPidFile $p.Id -Encoding ASCII
    Start-Sleep -Milliseconds 700
    try {
        $health = Invoke-LocalJson "$RouterBase/__bridge/healthz" "X-Bridge-Token" $RouterTokenFile
        if ($health.ok -ne $true) { throw "supervisor health false" }
    } catch {
        Stop-Pid $p.Id
        if (Test-Path $backup) { Copy-Item $backup $currentFile -Force }
        $env:WINDOWSBRIDGE_ROOT = $Root
        try { $old = Start-Process -FilePath $python -ArgumentList @($currentFile) -WindowStyle Hidden -PassThru }
        finally { $env:WINDOWSBRIDGE_ROOT = $null }
        Set-Content $SupervisorPidFile $old.Id -Encoding ASCII
        throw
    }
}

function Update-Transport([string]$TargetSha) {
    $pinUrl = "https://raw.githubusercontent.com/$Repo/$TargetSha/TUNNEL_CLIENT_VERSION"
    try { $pin = (Invoke-WebRequest -UseBasicParsing $pinUrl).Content.Trim() } catch { return }
    if ($pin -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw "Invalid transport pin." }
    $cfg = Get-Content $Config -Raw | ConvertFrom-Json
    $previousTransportRelease = [string]$cfg.tunnel_client_release
    if ($previousTransportRelease -eq $pin) { return }
    Log "TRANSPORT_UPDATE $previousTransportRelease -> $pin"
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
    $release = Invoke-RestMethod "https://api.github.com/repos/openai/tunnel-client/releases/tags/$pin" -Headers @{"User-Agent"="WindowsBridge-Updater"}
    $name = "tunnel-client-$pin-windows-$arch.zip"
    $asset = $release.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $asset -or -not $asset.digest) { throw "Transport asset/digest missing." }
    $tmpDir = Join-Path $env:TEMP ("WindowsBridge-transport-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory $tmpDir | Out-Null
    try {
        $zip = Join-Path $tmpDir $name
        Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile $zip
        $expected = ([string]$asset.digest).Replace("sha256:","").ToLowerInvariant()
        if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw "Transport digest mismatch." }
        Expand-Archive $zip -DestinationPath $tmpDir -Force
        $exe = Get-ChildItem $tmpDir -Filter tunnel-client.exe -Recurse | Select-Object -First 1
        if (-not $exe) { throw "Transport binary missing." }
        $live = Join-Path $Root "bin\tunnel-client.exe"
        $backup = Join-Path $Root "bin\tunnel-client.previous.exe"
        Copy-Item $live $backup -Force
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Copy-Item $exe.FullName $live -Force
        $cfg.tunnel_client_release = $pin
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $Config -Encoding UTF8
        Start-ScheduledTask -TaskName $TaskName
        $ok=$false
        for($i=0;$i -lt 30;$i++){try{$r=Invoke-WebRequest -UseBasicParsing "$TunnelHealth/readyz" -TimeoutSec 2;if($r.StatusCode -eq 200){$ok=$true;break}}catch{};Start-Sleep 1}
        if(-not $ok){
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Copy-Item $backup $live -Force
            $cfg.tunnel_client_release = $previousTransportRelease
            $cfg | ConvertTo-Json -Depth 10 | Set-Content $Config -Encoding UTF8
            Start-ScheduledTask -TaskName $TaskName
            throw "Transport update failed; previous binary and config restored."
        }
    } finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-CurrentGenerationMaintenance([string]$TargetSha) {
    Ensure-NewTopology $TargetSha
    $release = Stage-Release $TargetSha
    Update-Supervisor (Join-Path $release "management\supervisor.py")
    Update-Transport $TargetSha
}

if (-not (Test-Path $Config) -or -not (Test-Path $Current)) { throw "WindowsBridge is not installed." }
New-Item -ItemType Directory -Force -Path $State,$Releases,$Management | Out-Null

$mutex=[Threading.Mutex]::new($false,$MutexName); $locked=$false
try {
    try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if(-not $locked){Log "skip another update is running";exit 0}
    if(-not $Force){Start-Sleep -Seconds (Get-Random -Minimum 0 -Maximum 900)}
    Recover-Unfinished
    Remove-StaleReleaseStages

    $currentSha=(Get-Content $Current -Raw).Trim()
    $targetSha=Resolve-Target $Channel
    if(-not $Force -and $currentSha -eq $targetSha){
        Invoke-CurrentGenerationMaintenance $targetSha
        Log "ok already current $currentSha; deferred maintenance checked"
        exit 0
    }

    Ensure-NewTopology $targetSha
    $candidate=Stage-Release $targetSha
    $route=Get-Route
    $previousGeneration=[string]$route.generation
    $previousPort=[int]$route.port
    $previousPid=Read-Pid $ServerPidFile
    $candidatePort=if($previousPort -eq 18771){18772}else{18771}
    $tunnelPidBefore=Read-Pid $TunnelPidFile
    Assert-TunnelContinuity $tunnelPidBefore
    Write-State "STAGED" $currentSha $targetSha $previousGeneration $previousPort $previousPid $candidatePort 0

    $runtime=Invoke-LocalJson "http://127.0.0.1:$previousPort/__bridge/runtime-status" "X-Bridge-Backend-Token" $BackendTokenFile
    if([int]$runtime.live_process_sessions -gt 0){
        Log "runtime update deferred: $($runtime.live_process_sessions) stateful process session(s)"
        Write-State "DEFERRED_STATEFUL_HANDLES" $currentSha $targetSha $previousGeneration $previousPort $previousPid $candidatePort 0
        exit 0
    }

    $oldTools=Get-Tools $RouterBase "X-Bridge-Token" $RouterTokenFile
    $candidatePid=0
    try {
        $p=Start-Backend $candidate $candidatePort
        $candidatePid=$p.Id
        Write-State "CANDIDATE_STARTING" $currentSha $targetSha $previousGeneration $previousPort $previousPid $candidatePort $candidatePid
        for($i=0;$i -lt 40;$i++){if((Test-ProcessId $candidatePid) -and (Test-Backend $candidatePort)){break};Start-Sleep -Milliseconds 250}
        if(-not (Test-ProcessId $candidatePid) -or -not (Test-Backend $candidatePort)){throw "Candidate health failed."}
        $newTools=Get-Tools "http://127.0.0.1:$candidatePort" "X-Bridge-Backend-Token" $BackendTokenFile
        Assert-CompatibleTools $oldTools $newTools
        Write-State "CANDIDATE_HEALTHY" $currentSha $targetSha $previousGeneration $previousPort $previousPid $candidatePort $candidatePid
    } catch {
        Fail-CandidateBeforeSwitch $candidatePid $currentSha $targetSha $previousGeneration $previousPort $previousPid $candidatePort $_.Exception.Message
        throw
    }

    Set-Route $targetSha $candidatePort
    Write-State "SWITCHED" $currentSha $targetSha $previousGeneration $previousPort $previousPid $candidatePort $candidatePid
    try {
        $switchedTools=Get-Tools $RouterBase "X-Bridge-Token" $RouterTokenFile
        Assert-CompatibleTools $oldTools $switchedTools
        Write-State "DRAINING_OLD" $currentSha $targetSha $previousGeneration $previousPort $previousPid $candidatePort $candidatePid
        $drained=$false
        for($i=0;$i -lt 120;$i++){
            $s=Invoke-LocalJson "$RouterBase/__bridge/status" "X-Bridge-Token" $RouterTokenFile
            $count=0
            if($s.inflight.PSObject.Properties.Name -contains $previousGeneration){$count=[int]$s.inflight.$previousGeneration}
            if($count -eq 0){$drained=$true;break}
            Start-Sleep -Milliseconds 500
        }
        if(-not $drained){throw "Old generation did not drain."}
        Write-State "OBSERVING" $currentSha $targetSha $previousGeneration $previousPort $previousPid $candidatePort $candidatePid
        Start-Sleep 3
        if(-not (Test-Backend $candidatePort)){throw "Candidate failed observation."}
        $null=Get-Tools $RouterBase "X-Bridge-Token" $RouterTokenFile
        Assert-TunnelContinuity $tunnelPidBefore
    } catch {
        Set-Route $previousGeneration $previousPort
        Stop-Pid $candidatePid
        Write-State "FAILED_ROLLED_BACK" $currentSha $targetSha $previousGeneration $previousPort $previousPid $candidatePort $candidatePid $_.Exception.Message "route restored before candidate retirement"
        throw
    }

    Set-Content $Current $targetSha -Encoding ASCII
    Set-Content $ServerPidFile $candidatePid -Encoding ASCII
    Copy-Item (Join-Path $candidate "management\update.ps1") (Join-Path $Root "update.ps1") -Force
    Copy-Item (Join-Path $candidate "management\windowsbridgectl.ps1") (Join-Path $env:SystemRoot "System32\windowsbridgectl.ps1") -Force
    Write-State "COMMITTED" $currentSha $targetSha $previousGeneration $previousPort $previousPid $candidatePort $candidatePid
    Stop-Pid $previousPid
    Invoke-CurrentGenerationMaintenance $targetSha
    Log "ok seamless runtime activation $targetSha tunnel_pid=$(Read-Pid $TunnelPidFile)"
} finally {
    $env:UV_PYTHON_INSTALL_DIR=$null;$env:UV_CACHE_DIR=$null;$env:UV_PYTHON_NO_REGISTRY=$null;$env:UV_PYTHON_INSTALL_BIN=$null
    if($locked){$mutex.ReleaseMutex()|Out-Null};$mutex.Dispose()
}
