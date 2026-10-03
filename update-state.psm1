Set-StrictMode -Version Latest

$script:WindowsBridgeUpdateStates = @(
    "IDLE",
    "CHECKING",
    "DOWNLOADED",
    "STAGED",
    "CANDIDATE_HEALTHY",
    "SWITCHED",
    "DRAINING_OLD",
    "VERIFIED",
    "COMMITTED",
    "FAILED_ROLLED_BACK",
    "LEGACY_RESTARTING"
)

function Assert-WindowsBridgeGeneration([string]$Value, [string]$Name) {
    if ($Value -and $Value -notmatch '^[0-9a-f]{40}$') {
        throw "$Name must be an immutable 40-character Git commit SHA."
    }
}

function Read-WindowsBridgeUpdateState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject][ordered]@{
            schema_version = 1
            state = "IDLE"
            generation_id = $null
            update_class = "NONE"
            current_generation = $null
            candidate_generation = $null
            previous_generation = $null
            transport_restart_required = $false
            reason = "no_update_recorded"
            updated_at = $null
        }
    }

    try {
        $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "WindowsBridge update state is unreadable."
    }

    if ([int]$state.schema_version -ne 1) { throw "Unsupported WindowsBridge update-state schema." }
    if ([string]$state.state -notin $script:WindowsBridgeUpdateStates) { throw "Invalid WindowsBridge update state." }

    Assert-WindowsBridgeGeneration ([string]$state.current_generation) "current_generation"
    Assert-WindowsBridgeGeneration ([string]$state.candidate_generation) "candidate_generation"
    Assert-WindowsBridgeGeneration ([string]$state.previous_generation) "previous_generation"
    return $state
}

function Write-WindowsBridgeUpdateState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet(
            "IDLE","CHECKING","DOWNLOADED","STAGED","CANDIDATE_HEALTHY",
            "SWITCHED","DRAINING_OLD","VERIFIED","COMMITTED",
            "FAILED_ROLLED_BACK","LEGACY_RESTARTING"
        )][string]$State,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$GenerationId,
        [Parameter(Mandatory)][ValidateSet("APPLICATION","TRANSPORT_UPDATE","LEGACY_FULL_INSTALL","NONE")][string]$UpdateClass,
        [string]$CurrentGeneration,
        [string]$CandidateGeneration,
        [string]$PreviousGeneration,
        [bool]$TransportRestartRequired = $false,
        [ValidateLength(0,256)][string]$Reason = ""
    )

    Assert-WindowsBridgeGeneration $CurrentGeneration "current_generation"
    Assert-WindowsBridgeGeneration $CandidateGeneration "candidate_generation"
    Assert-WindowsBridgeGeneration $PreviousGeneration "previous_generation"
    if ($Reason -match '[\r\n]') { throw "Update-state reason must be a single line." }

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = Join-Path $directory (".update-state-" + [guid]::NewGuid().ToString("N") + ".tmp")
    $backup = Join-Path $directory (".update-state-" + [guid]::NewGuid().ToString("N") + ".bak")

    [ordered]@{
        schema_version = 1
        state = $State
        generation_id = $GenerationId
        update_class = $UpdateClass
        current_generation = $CurrentGeneration
        candidate_generation = $CandidateGeneration
        previous_generation = $PreviousGeneration
        transport_restart_required = $TransportRestartRequired
        reason = $Reason
        updated_at = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8

    try {
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, $backup, $true)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Read-WindowsBridgeUpdateState,Write-WindowsBridgeUpdateState
