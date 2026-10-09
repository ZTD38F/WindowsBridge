[CmdletBinding()]
param(
    [string]$SourceRef = "stable"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Repo = "ZTD38F/WindowsBridge"
$TaskName = "WindowsBridge"
$UpdateTaskName = "WindowsBridge Auto Update"
$Root = Join-Path $env:ProgramData "WindowsBridge"
$ControlPs1 = Join-Path $env:SystemRoot "System32\windowsbridgectl.ps1"
$ControlCmd = Join-Path $env:SystemRoot "System32\windowsbridgectl.cmd"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-SourceCommit([string]$Ref) {
    if ($Ref -notmatch '^[A-Za-z0-9._-]{1,80}
if (-not (Test-Administrator)) {
    # Pin the uninstaller before crossing the UAC boundary. A mutable channel
    # may move while the consent prompt is open; this exact commit cannot.
    $ResolvedBootstrapRef = Resolve-SourceCommit $SourceRef
    $selfUrl = "https://raw.githubusercontent.com/$Repo/$ResolvedBootstrapRef/uninstall.ps1"
    $tmp = Join-Path $env:TEMP ("WindowsBridge-uninstall-" + [guid]::NewGuid().ToString("N") + ".ps1")
    Invoke-WebRequest -UseBasicParsing $selfUrl -OutFile $tmp
    try {
        $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $tmp),"-SourceRef",$ResolvedBootstrapRef)
        $p = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args -Wait -PassThru
        exit $p.ExitCode
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

foreach ($name in @($UpdateTaskName,$TaskName)) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}

Remove-Item $ControlPs1,$ControlCmd -Force -ErrorAction SilentlyContinue

if (Test-Path $Root) {
    Remove-Item $Root -Recurse -Force
}

Write-Host "WindowsBridge removed from this Windows computer." -ForegroundColor Green
Write-Host "The OpenAI tunnel object and Platform runtime key were not deleted."
) { throw "Invalid SourceRef." }

    try {
        $commit = Invoke-RestMethod "https://api.github.com/repos/$Repo/commits/$Ref" -Headers @{"User-Agent"="WindowsBridge-Uninstaller"}
    } catch {
        throw "Could not resolve WindowsBridge source ref '$Ref' to an immutable GitHub commit: $($_.Exception.Message)"
    }

    $sha = [string]$commit.sha
    if ($sha -notmatch '^[0-9a-f]{40}
if (-not (Test-Administrator)) {
    $tmp = Join-Path $env:TEMP ("WindowsBridge-uninstall-" + [guid]::NewGuid().ToString("N") + ".ps1")
    Invoke-WebRequest -UseBasicParsing $SelfUrl -OutFile $tmp
    try {
        $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $tmp))
        $p = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args -Wait -PassThru
        exit $p.ExitCode
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

foreach ($name in @($UpdateTaskName,$TaskName)) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}

Remove-Item $ControlPs1,$ControlCmd -Force -ErrorAction SilentlyContinue

if (Test-Path $Root) {
    Remove-Item $Root -Recurse -Force
}

Write-Host "WindowsBridge removed from this Windows computer." -ForegroundColor Green
Write-Host "The OpenAI tunnel object and Platform runtime key were not deleted."
) { throw "GitHub returned an invalid WindowsBridge commit SHA." }
    return $sha
}

if (-not (Test-Administrator)) {
    $tmp = Join-Path $env:TEMP ("WindowsBridge-uninstall-" + [guid]::NewGuid().ToString("N") + ".ps1")
    Invoke-WebRequest -UseBasicParsing $SelfUrl -OutFile $tmp
    try {
        $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $tmp))
        $p = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args -Wait -PassThru
        exit $p.ExitCode
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

foreach ($name in @($UpdateTaskName,$TaskName)) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}

Remove-Item $ControlPs1,$ControlCmd -Force -ErrorAction SilentlyContinue

if (Test-Path $Root) {
    Remove-Item $Root -Recurse -Force
}

Write-Host "WindowsBridge removed from this Windows computer." -ForegroundColor Green
Write-Host "The OpenAI tunnel object and Platform runtime key were not deleted."
