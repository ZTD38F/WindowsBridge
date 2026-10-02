#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"
$TaskName = "WindowsBridge"
$Root = Join-Path $env:ProgramData "WindowsBridge"
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
Write-Host "WindowsBridge removed. The OpenAI tunnel itself was not deleted." -ForegroundColor Green
