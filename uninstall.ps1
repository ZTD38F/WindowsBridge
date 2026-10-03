[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$SelfUrl = "https://raw.githubusercontent.com/ZTD38F/WindowsBridge/stable/uninstall.ps1"
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
