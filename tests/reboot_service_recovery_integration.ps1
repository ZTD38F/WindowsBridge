$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
$installerPath = Join-Path $repoRoot "install.ps1"
$installer = Get-Content -LiteralPath $installerPath -Raw

$startupContract = @(
    'New-ScheduledTaskTrigger -AtStartup',
    'New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest',
    '-StartWhenAvailable -RestartCount 999',
    '-ExecutionTimeLimit ([TimeSpan]::Zero)'
)
foreach ($value in $startupContract) {
    if (-not $installer.Contains($value)) {
        throw "Missing reboot startup contract: $value"
    }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) {
    throw "Production installer PowerShell parser errors: $($parseErrors.Count)"
}
$assignments = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$launchContent'
}, $true))
if ($assignments.Count -ne 1 -or $null -eq $assignments[0].Right.Value) {
    throw "Could not extract the production launch.ps1 body from install.ps1."
}
$launchContent = [string]$assignments[0].Right.Value

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "WindowsBridge reboot recovery Ω Ж 漢字 " + [guid]::NewGuid().ToString("N"))
$programData = Join-Path $fixtureRoot "Program Data"
$bridgeRoot = Join-Path $programData "WindowsBridge"
$capturePath = Join-Path $fixtureRoot "starts.jsonl"
$childPath = Join-Path $fixtureRoot "launch-under-test.ps1"
$generation = "a" * 40
$oldProgramData = $env:ProgramData
$oldCapture = $env:WB_REBOOT_CAPTURE

try {
    foreach ($path in @(
        (Join-Path $bridgeRoot "bin"),
        (Join-Path $bridgeRoot "logs"),
        (Join-Path $bridgeRoot "management"),
        (Join-Path $bridgeRoot "secrets"),
        (Join-Path $bridgeRoot "state"),
        (Join-Path (Join-Path $bridgeRoot "releases") $generation)
    )) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    [ordered]@{
        tunnel_id = "tunnel_0123456789abcdef0123456789abcdef"
        api_key_dpapi = ""
    } | ConvertTo-Json | Set-Content (Join-Path $bridgeRoot "config.json") -Encoding UTF8
    Set-Content (Join-Path $bridgeRoot "current.txt") $generation -Encoding ASCII
    [ordered]@{ generation = $generation; port = 18771 } |
        ConvertTo-Json -Compress |
        Set-Content (Join-Path $bridgeRoot "state\route.json") -Encoding ASCII
    Set-Content (Join-Path $bridgeRoot "secrets\control_plane_api_key") "fixture-key" -Encoding ASCII
    Set-Content (Join-Path $bridgeRoot "secrets\router_token") "router-token" -Encoding ASCII
    Set-Content (Join-Path $bridgeRoot "secrets\backend_token") "backend-token" -Encoding ASCII

    $prelude = @'
$script:NextFakePid = 41000

function Get-Process {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$Id)
    return $null
}

function Start-Process {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [object[]]$ArgumentList,
        [string]$WindowStyle,
        [switch]$PassThru,
        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError
    )

    $script:NextFakePid++
    [ordered]@{
        file = $FilePath
        arguments = @($ArgumentList | ForEach-Object { [string]$_ })
        id = $script:NextFakePid
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:WB_REBOOT_CAPTURE -Encoding UTF8

    $process = [pscustomobject]@{
        Id = $script:NextFakePid
        ExitCode = 0
    }
    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { }
    return $process
}
'@

    Set-Content -LiteralPath $childPath -Value ($prelude + [Environment]::NewLine + $launchContent) -Encoding UTF8
    $env:ProgramData = $programData
    $env:WB_REBOOT_CAPTURE = $capturePath

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $childPath
    if ($LASTEXITCODE -ne 0) {
        throw "Production launcher cold-start simulation exited with $LASTEXITCODE."
    }

    $records = @(
        Get-Content -LiteralPath $capturePath |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
    if ($records.Count -ne 3) {
        throw "Expected backend, supervisor, and tunnel starts after reboot; found $($records.Count)."
    }

    $pythonStarts = @($records | Where-Object { $_.file -like "*\venv\Scripts\python.exe" })
    $tunnelStarts = @($records | Where-Object { $_.file -like "*\bin\tunnel-client.exe" })
    if ($pythonStarts.Count -ne 2 -or $tunnelStarts.Count -ne 1) {
        throw "Cold start did not recreate exactly two Python processes and one tunnel process."
    }

    $backend = @($pythonStarts | Where-Object { @($_.arguments) -contains "--port" })
    $supervisor = @($pythonStarts | Where-Object {
        (@($_.arguments) -join " ") -like "*management\supervisor.py*"
    })
    if ($backend.Count -ne 1 -or $supervisor.Count -ne 1) {
        throw "Cold start did not recreate both backend and supervisor roles."
    }
    if (-not (@($backend[0].arguments) -contains "18771")) {
        throw "Recovered backend did not use the persisted route port."
    }
    if (-not ((@($tunnelStarts[0].arguments) -join " ").Contains("http://127.0.0.1:18766/mcp"))) {
        throw "Recovered tunnel did not target the stable loopback supervisor."
    }

    $expectedPids = [ordered]@{
        "server.pid" = "41001"
        "supervisor.pid" = "41002"
        "tunnel.pid" = "41003"
    }
    foreach ($entry in $expectedPids.GetEnumerator()) {
        $actual = (Get-Content (Join-Path $bridgeRoot ("state\" + $entry.Key)) -Raw).Trim()
        if ($actual -ne $entry.Value) {
            throw "Recovered $($entry.Key) recorded PID $actual; expected $($entry.Value)."
        }
    }

    Write-Host "Windows reboot service recovery integration checks passed."
} finally {
    $env:ProgramData = $oldProgramData
    $env:WB_REBOOT_CAPTURE = $oldCapture
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
