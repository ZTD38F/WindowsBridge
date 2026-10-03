[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet("check","status","doctor","logs","restart","update","repair","ui","auto-update-enable","auto-update-disable")]
    [string]$Command = "check",
    [Parameter(Position=1)]
    [int]$Lines = 100
)

$ErrorActionPreference = "Stop"
$Root = Join-Path $env:ProgramData "WindowsBridge"
$Config = Join-Path $Root "config.json"
$Current = Join-Path $Root "current.txt"
$TaskName = "WindowsBridge"
$UpdateTaskName = "WindowsBridge Auto Update"
$HealthBase = "http://127.0.0.1:18765"

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-Admin)) {
        throw "This command requires Administrator privileges. Open an elevated PowerShell or approve UAC."
    }
}


if (-not (Test-Admin)) {
    $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $PSCommandPath),"-Command",$Command,"-Lines",$Lines)
    $p = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args -Wait -PassThru
    exit $p.ExitCode
}

function Get-CurrentRelease {
    if (-not (Test-Path $Current)) { throw "WindowsBridge is not installed." }
    $ref = (Get-Content $Current -Raw).Trim()
    [pscustomobject]@{
        Commit = $ref
        Root = Join-Path (Join-Path $Root "releases") $ref
    }
}

function Test-Ready {
    try {
        $r = Invoke-WebRequest -UseBasicParsing "$HealthBase/readyz" -TimeoutSec 3
        return $r.StatusCode -eq 200
    } catch { return $false }
}

switch ($Command) {
    "check" {
        $ok = $true
        Write-Host "WindowsBridge"
        try {
            $release = Get-CurrentRelease
            Write-Host "  OK source commit: $($release.Commit)"
        } catch {
            Write-Host "  FAIL installation state: $($_.Exception.Message)"
            $ok = $false
        }

        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) { Write-Host "  OK runtime task: $($task.State)" } else { Write-Host "  FAIL runtime task missing"; $ok = $false }

        if (Test-Ready) { Write-Host "  OK tunnel readiness: ready" } else { Write-Host "  FAIL tunnel readiness: not ready"; $ok = $false }

        $u = Get-ScheduledTask -TaskName $UpdateTaskName -ErrorAction SilentlyContinue
        if ($u) { Write-Host "  OK auto-update task: $($u.State)" } else { Write-Host "  WARN auto-update task missing" }

        if (-not $ok) { exit 1 }
    }

    "status" {
        $release = Get-CurrentRelease
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $update = Get-ScheduledTask -TaskName $UpdateTaskName -ErrorAction SilentlyContinue
        [pscustomobject]@{
            source_commit = $release.Commit
            runtime_task = if ($task) { [string]$task.State } else { "missing" }
            ready = Test-Ready
            auto_update = if ($update) { [string]$update.State } else { "missing" }
            root = $Root
        } | Format-List
    }

    "doctor" {
        Require-Admin
        $release = Get-CurrentRelease
        $cfg = Get-Content $Config -Raw | ConvertFrom-Json
        $enc = [Convert]::FromBase64String($cfg.api_key_dpapi)
        $raw = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        try {
            $env:CONTROL_PLANE_API_KEY = [Text.Encoding]::UTF8.GetString($raw)
            $env:CONTROL_PLANE_TUNNEL_ID = [string]$cfg.tunnel_id
            $env:MCP_COMMAND = '"' + (Join-Path $release.Root "venv\Scripts\python.exe") + '" "' + (Join-Path $release.Root "app\windowsbridge.py") + '"'
            & (Join-Path $release.Root "bin\tunnel-client.exe") doctor --explain
            exit $LASTEXITCODE
        } finally {
            $env:CONTROL_PLANE_API_KEY = $null
            $env:CONTROL_PLANE_TUNNEL_ID = $null
            $env:MCP_COMMAND = $null
            $raw = $null
        }
    }

    "logs" {
        $Lines = [Math]::Max(1,[Math]::Min($Lines,5000))
        foreach ($name in @("tunnel.log","update.log")) {
            $path = Join-Path (Join-Path $Root "logs") $name
            if (Test-Path $path) {
                Write-Host "== $name =="
                Get-Content $path -Tail $Lines
            }
        }
    }

    "restart" {
        Require-Admin
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 2
        & $PSCommandPath check
    }

    "update" {
        Require-Admin
        & (Join-Path $Root "update.ps1") -Force
    }

    "repair" {
        Require-Admin
        & (Join-Path $Root "update.ps1") -Force
        & $PSCommandPath check
    }

    "ui" {
        Start-Process "$HealthBase/ui"
    }

    "auto-update-enable" {
        Require-Admin
        Enable-ScheduledTask -TaskName $UpdateTaskName | Out-Null
        Write-Host "WindowsBridge automatic updates enabled."
    }

    "auto-update-disable" {
        Require-Admin
        Disable-ScheduledTask -TaskName $UpdateTaskName | Out-Null
        Write-Host "WindowsBridge automatic updates disabled."
    }
}
