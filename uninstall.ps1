[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$SelfUrl = "https://raw.githubusercontent.com/ZTD38F/WindowsBridge/main/uninstall.ps1"
$TaskName = "WindowsBridge"
$Root = Join-Path $env:ProgramData "WindowsBridge"

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

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

if (Test-Path $Root) {
    Remove-Item $Root -Recurse -Force
}

Write-Host "WindowsBridge removed from this Windows computer." -ForegroundColor Green
Write-Host "The OpenAI tunnel object and Platform runtime key were not deleted."
