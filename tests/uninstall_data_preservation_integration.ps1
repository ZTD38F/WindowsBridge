$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$uninstallerPath = Join-Path $repositoryRoot "uninstall.ps1"
$source = [System.IO.File]::ReadAllText($uninstallerPath)
$marker = 'foreach ($name in @($UpdateTaskName,$TaskName))'
$markerIndex = $source.IndexOf($marker, [System.StringComparison]::Ordinal)
if ($markerIndex -lt 0) {
    throw "Could not locate the production elevated uninstall body."
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $uninstallerPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "uninstall.ps1 does not parse cleanly: $($parseErrors | Out-String)"
}

$removeCommands = @(
    $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq "Remove-Item" -and
        $node.Extent.StartOffset -ge $markerIndex
    }, $true) | ForEach-Object {
        ($_.Extent.Text -replace '\s+', ' ').Trim()
    }
)
$allowedRemoveCommands = @(
    'Remove-Item $ControlPs1,$ControlCmd -Force -ErrorAction SilentlyContinue',
    'Remove-Item $Root -Recurse -Force'
)
if ($removeCommands.Count -ne $allowedRemoveCommands.Count) {
    throw "Unexpected Remove-Item command count in the elevated uninstall body: $($removeCommands -join '; ')"
}
foreach ($command in $removeCommands) {
    if ($allowedRemoveCommands -notcontains $command) {
        throw "Unsafe or unreviewed Remove-Item target in the elevated uninstall body: $command"
    }
}

$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("WindowsBridge uninstall Ω Ж 漢字 " + [guid]::NewGuid().ToString("N"))
$originalProgramData = $env:ProgramData
$originalUserProfile = $env:USERPROFILE
$taskCalls = New-Object System.Collections.Generic.List[string]

function Stop-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $script:taskCalls.Add("stop:$TaskName")
}

function Unregister-ScheduledTask {
    [CmdletBinding()]
    param(
        [string]$TaskName,
        [object]$Confirm
    )
    $script:taskCalls.Add("unregister:$TaskName")
}

try {
    $env:ProgramData = Join-Path $fixture "Program Data"
    $env:USERPROFILE = Join-Path $fixture "User Profile"

    $Root = Join-Path $env:ProgramData "WindowsBridge"
    $ControlDir = Join-Path $fixture "Windows System32"
    $ControlPs1 = Join-Path $ControlDir "windowsbridgectl.ps1"
    $ControlCmd = Join-Path $ControlDir "windowsbridgectl.cmd"
    $TaskName = "WindowsBridge"
    $UpdateTaskName = "WindowsBridge Auto Update"

    $userFile = Join-Path $env:USERPROFILE "Documents\critical user data.bin"
    $siblingFile = Join-Path $env:ProgramData "Unrelated App\database.bin"
    $managedSecret = Join-Path $Root "config\secrets\tunnel.env"

    foreach ($path in @($userFile,$siblingFile,$managedSecret,$ControlPs1,$ControlCmd)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    }

    $userBytes = [byte[]](0,255,10,13,42,99,128,7)
    $siblingBytes = [byte[]](17,23,5,201,0,88)
    [System.IO.File]::WriteAllBytes($userFile, $userBytes)
    [System.IO.File]::WriteAllBytes($siblingFile, $siblingBytes)
    [System.IO.File]::WriteAllText($managedSecret, "fixture-only-secret")
    [System.IO.File]::WriteAllText($ControlPs1, "fixture-control")
    [System.IO.File]::WriteAllText($ControlCmd, "fixture-control")

    $userHashBefore = (Get-FileHash $userFile -Algorithm SHA256).Hash
    $siblingHashBefore = (Get-FileHash $siblingFile -Algorithm SHA256).Hash

    $elevatedBody = $source.Substring($markerIndex)
    Invoke-Expression $elevatedBody

    if (Test-Path $Root) {
        throw "The uninstaller did not remove its managed root."
    }
    if ((Test-Path $ControlPs1) -or (Test-Path $ControlCmd)) {
        throw "The uninstaller did not remove its control shims."
    }
    if (-not (Test-Path $userFile)) {
        throw "The uninstaller removed user data outside its managed root."
    }
    if (-not (Test-Path $siblingFile)) {
        throw "The uninstaller removed another application's ProgramData."
    }
    if ((Get-FileHash $userFile -Algorithm SHA256).Hash -ne $userHashBefore) {
        throw "The uninstaller modified user data outside its managed root."
    }
    if ((Get-FileHash $siblingFile -Algorithm SHA256).Hash -ne $siblingHashBefore) {
        throw "The uninstaller modified another application's ProgramData."
    }

    $expectedTaskCalls = @(
        "stop:WindowsBridge Auto Update",
        "unregister:WindowsBridge Auto Update",
        "stop:WindowsBridge",
        "unregister:WindowsBridge"
    )
    if (($taskCalls -join "|") -ne ($expectedTaskCalls -join "|")) {
        throw "Unexpected scheduled-task cleanup sequence: $($taskCalls -join ', ')"
    }

    Write-Host "Uninstaller data preservation integration test passed."
}
finally {
    $env:ProgramData = $originalProgramData
    $env:USERPROFILE = $originalUserProfile
    if (Test-Path $fixture) {
        Remove-Item $fixture -Recurse -Force
    }
}
