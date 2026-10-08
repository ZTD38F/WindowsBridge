$ErrorActionPreference = "Stop"

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

$originalProgramData = $env:ProgramData
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("WindowsBridge tunnel continuity é " + [guid]::NewGuid().ToString("N"))
$holder = $null
$replacement = $null
try {
    $env:ProgramData = $fixtureRoot
    $updaterPath = Join-Path (Split-Path $PSScriptRoot -Parent) "update.ps1"
    $source = Get-Content -LiteralPath $updaterPath -Raw
    $marker = 'if (-not (Test-Path $Config) -or -not (Test-Path $Current))'
    $markerIndex = $source.IndexOf($marker)
    if ($markerIndex -lt 0) { throw "Updater function boundary was not found." }
    Invoke-Expression $source.Substring(0, $markerIndex)

    New-Item -ItemType Directory -Force -Path $State | Out-Null
    $holder = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-Command","Start-Sleep -Seconds 60") -PassThru -WindowStyle Hidden
    Set-Content -LiteralPath $TunnelPidFile -Value $holder.Id -Encoding ASCII
    $holderIdentity = Get-ProcessIdentity $holder.Id
    if ($null -eq $holderIdentity) { throw "Could not capture the tunnel process identity." }

    Assert-TunnelContinuity $holderIdentity
    Assert-TunnelContinuity $holderIdentity

    $replacement = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-Command","Start-Sleep -Seconds 60") -PassThru -WindowStyle Hidden
    Set-Content -LiteralPath $TunnelPidFile -Value $replacement.Id -Encoding ASCII
    Assert-Throws { Assert-TunnelContinuity $holderIdentity } "A changed tunnel process was accepted."

    Set-Content -LiteralPath $TunnelPidFile -Value $holder.Id -Encoding ASCII
    Stop-Process -Id $holder.Id -Force
    $holder.WaitForExit()
    Assert-Throws { Assert-TunnelContinuity $holderIdentity } "A dead or PID-reused tunnel process was accepted."

    $activation = $source.Substring($markerIndex)
    $capture = $activation.IndexOf('$tunnelIdentityBefore=Get-ProcessIdentity (Read-Pid $TunnelPidFile)')
    $preflight = $activation.IndexOf('Assert-TunnelContinuity $tunnelIdentityBefore', $capture)
    $staged = $activation.IndexOf('Write-State "STAGED"', $preflight)
    $observing = $activation.IndexOf('Write-State "OBSERVING"', $staged)
    $postObservation = $activation.IndexOf('Assert-TunnelContinuity $tunnelIdentityBefore', $observing)
    $commit = $activation.IndexOf('Set-Content $Current $targetSha', $postObservation)
    if ($capture -lt 0 -or $preflight -le $capture -or $staged -le $preflight) {
        throw "Tunnel continuity preflight is not before staging."
    }
    if ($observing -lt 0 -or $postObservation -le $observing -or $commit -le $postObservation) {
        throw "Tunnel continuity verification is not after observation and before commit."
    }

    Write-Host "Tunnel PID continuity contract passed."
} finally {
    foreach ($process in @($holder,$replacement)) {
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    $env:ProgramData = $originalProgramData
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
