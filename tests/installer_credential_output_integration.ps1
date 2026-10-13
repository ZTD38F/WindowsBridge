$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$installerPath = Join-Path $repositoryRoot "install.ps1"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "install.ps1 does not parse cleanly: $($parseErrors | Out-String)"
}

$sensitiveVariablePattern = '\$(RuntimeApiKey|secure|raw|keyBytes|protected|enc|existing|cfg)\b'
$outputCommands = @(
    "Write-Host",
    "Write-Output",
    "Write-Information",
    "Write-Verbose",
    "Write-Debug",
    "Write-Warning",
    "Write-Error",
    "Out-Host"
)
$outputViolations = @(
    $ast.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
            return $false
        }
        $name = $node.GetCommandName()
        return $name -and
            $outputCommands -contains $name -and
            $node.Extent.Text -match $sensitiveVariablePattern
    }, $true)
)
if ($outputViolations.Count -gt 0) {
    throw "Installer sends credential-bearing variables to an output sink: $($outputViolations.Extent.Text -join '; ')"
}

$processArgumentViolations = @(
    $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq "Start-Process" -and
        $node.Extent.Text -match '\$(RuntimeApiKey|TunnelId|secure|raw)\b'
    }, $true)
)
if ($processArgumentViolations.Count -gt 0) {
    throw "Installer passes credentials through process arguments: $($processArgumentViolations.Extent.Text -join '; ')"
}

$functions = @{}
$ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object {
    $functions[$_.Name] = $_
}

foreach ($requiredFunction in @("ConvertFrom-Secure","Read-RuntimeApiKey")) {
    if (-not $functions.ContainsKey($requiredFunction)) {
        throw "Installer function is missing: $requiredFunction"
    }
    Invoke-Expression $functions[$requiredFunction].Extent.Text
}

$readFunctionText = $functions["Read-RuntimeApiKey"].Extent.Text
if ($readFunctionText -notmatch 'Read-Host\s+"Paste Runtime API key here \(input is hidden\)"\s+-AsSecureString') {
    throw "Runtime API credential prompt must use hidden SecureString input."
}

$script:credentialFixture = "runtime-" + [guid]::NewGuid().ToString("N") + "-fixture"
$script:hostMessages = New-Object System.Collections.Generic.List[string]
$script:officialPageCalls = New-Object System.Collections.Generic.List[string]

function Open-SetupPage {
    param([string]$Url)
    $script:officialPageCalls.Add($Url)
}

function Read-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [string]$Prompt,
        [switch]$AsSecureString
    )
    if (-not $AsSecureString) {
        throw "Credential prompt did not request SecureString input."
    }
    return ConvertTo-SecureString $script:credentialFixture -AsPlainText -Force
}

function Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position=0, ValueFromPipeline=$true, ValueFromRemainingArguments=$true)]
        [object[]]$Object,
        [object]$ForegroundColor,
        [switch]$NoNewline
    )
    $script:hostMessages.Add(($Object -join " "))
}

$returnedCredential = Read-RuntimeApiKey
if ($returnedCredential -ne $credentialFixture) {
    throw "Credential prompt did not return the exact hidden input to its caller."
}
if ($officialPageCalls.Count -ne 1 -or
    $officialPageCalls[0] -ne "https://platform.openai.com/settings/organization/api-keys") {
    throw "Credential prompt did not use the official Runtime API key page."
}

$hostTranscript = $hostMessages -join [Environment]::NewLine
if ($hostTranscript.Contains($credentialFixture)) {
    throw "Credential value was printed to the interactive host."
}
if (-not $hostTranscript.Contains("input is hidden")) {
    throw "Installer did not tell the user that credential input is hidden."
}
if (-not $hostTranscript.Contains("Runtime API key received")) {
    throw "Installer did not emit a secret-free credential acceptance message."
}

Write-Output "Installer credential output integration test passed."
