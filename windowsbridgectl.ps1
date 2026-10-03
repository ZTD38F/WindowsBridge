[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet("check","status","update-status","doctor","logs","restart","update","update-now","repair","ui","auto-update-enable","auto-update-disable")]
    [string]$Command = "check",
    [Parameter(Position=1)][int]$Lines = 100
)
$ErrorActionPreference="Stop"
$Root=Join-Path $env:ProgramData "WindowsBridge"
$Current=Join-Path $Root "current.txt"
$Route=Join-Path $Root "state\route.json"
$Journal=Join-Path $Root "state\update.json"
$TaskName="WindowsBridge";$UpdateTaskName="WindowsBridge Auto Update"
$TunnelHealth="http://127.0.0.1:18765"

function Test-Admin {$id=[Security.Principal.WindowsIdentity]::GetCurrent();$p=[Security.Principal.WindowsPrincipal]::new($id);$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
if(-not(Test-Admin)){
  $args=@("-NoProfile","-ExecutionPolicy","Bypass","-File",('"{0}"'-f $PSCommandPath),"-Command",$Command,"-Lines",$Lines)
  $p=Start-Process powershell.exe -Verb RunAs -ArgumentList $args -Wait -PassThru;exit $p.ExitCode
}
function Ready([string]$Url){try{(Invoke-WebRequest -UseBasicParsing $Url -TimeoutSec 3).StatusCode -eq 200}catch{$false}}
function PidAlive([string]$Path){if(-not(Test-Path $Path)){return $false};$v=(Get-Content $Path -Raw).Trim();$n=0;if(-not[int]::TryParse($v,[ref]$n)){return $false};$null-ne(Get-Process -Id $n -ErrorAction SilentlyContinue)}
function Print-Update{
  if(Test-Path $Journal){
    $j=Get-Content $Journal -Raw|ConvertFrom-Json
    foreach($k in @("transaction_id","update_kind","phase","current_generation","candidate_generation","previous_generation","failure_reason","rollback_reason","updated_at")){
      if($null-ne $j.$k -and [string]$j.$k -ne ""){Write-Host ("  {0}: {1}"-f $k,$j.$k)}
    }
  }else{Write-Host "  update_state: none"}
}
switch($Command){
 "check"{
   $ok=$true
   if(Test-Path $Current){Write-Host "OK current: $((Get-Content $Current -Raw).Trim())"}else{Write-Host "FAIL current missing";$ok=$false}
   if(Ready "$TunnelHealth/readyz"){Write-Host "OK tunnel ready"}else{Write-Host "FAIL tunnel not ready";$ok=$false}
   foreach($pair in @(@("supervisor","supervisor.pid"),@("backend","server.pid"),@("tunnel","tunnel.pid"))){$p=Join-Path $Root ("state\"+$pair[1]);if(PidAlive $p){Write-Host "OK $($pair[0]) process"}else{Write-Host "FAIL $($pair[0]) process";$ok=$false}}
   $task=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
   if($task){Write-Host "OK runtime task: $($task.State)"}else{Write-Host "FAIL runtime task missing";$ok=$false}
   if(-not $ok){exit 1}
 }
 "status"{
   Write-Host "WindowsBridge"
   Write-Host "  current: $((Get-Content $Current -Raw -ErrorAction SilentlyContinue).Trim())"
   if(Test-Path $Route){$r=Get-Content $Route -Raw|ConvertFrom-Json;Write-Host "  active_generation: $($r.generation)";Write-Host "  active_port: $($r.port)"}
   Write-Host "  tunnel_ready: $(Ready "$TunnelHealth/readyz")"
   foreach($n in @("supervisor.pid","server.pid","tunnel.pid")){$p=Join-Path $Root ("state\"+$n);if(Test-Path $p){Write-Host ("  {0}: {1}"-f $n,(Get-Content $p -Raw).Trim())}}
   Print-Update
 }
 "update-status"{Print-Update}
 "doctor"{& $PSCommandPath check;Print-Update}
 "logs"{
   $Lines=[Math]::Max(1,[Math]::Min($Lines,5000))
   foreach($n in @("tunnel.log","tunnel.err.log","update.log")){$p=Join-Path $Root "logs\$n";if(Test-Path $p){Write-Host "== $n ==";Get-Content $p -Tail $Lines}}
 }
 "restart"{Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue;Start-ScheduledTask -TaskName $TaskName;Start-Sleep 2;& $PSCommandPath check}
 "update"{& (Join-Path $Root "update.ps1") -Force}
 "update-now"{& (Join-Path $Root "update.ps1") -Force}
 "repair"{& (Join-Path $Root "update.ps1") -Force;& $PSCommandPath check}
 "ui"{Start-Process "$TunnelHealth/ui"}
 "auto-update-enable"{Enable-ScheduledTask -TaskName $UpdateTaskName|Out-Null;Write-Host "WindowsBridge automatic updates enabled."}
 "auto-update-disable"{Disable-ScheduledTask -TaskName $UpdateTaskName|Out-Null;Write-Host "WindowsBridge automatic updates disabled."}
}
