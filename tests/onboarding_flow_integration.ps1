Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root "install.ps1"
$source = Get-Content -LiteralPath $sourcePath -Raw
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $sourcePath, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) {
    throw "Installer parse errors: $(@($parseErrors).Count)"
}

foreach ($name in @("ConvertFrom-Secure","Assert-ValidTunnelId","Read-TunnelId",
                     "Read-RuntimeApiKey","Show-ConnectorSetup")) {
    $nodes = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $name
    }, $true))
    if ($nodes.Count -ne 1) { throw "Expected exactly one production $name function." }
    Invoke-Expression $nodes[0].Extent.Text
}

$script:urls = [System.Collections.Generic.List[string]]::new()
$script:messages = [System.Collections.Generic.List[string]]::new()
$script:prompts = [System.Collections.Generic.List[string]]::new()
$script:inputs = [System.Collections.Generic.Queue[string]]::new()
$script:inputs.Enqueue("tunnel_wrong")
$script:inputs.Enqueue("tunnel_" + ("A" * 32))
$script:validTunnelId = "tunnel_" + ("a" * 32)
$script:inputs.Enqueue("  $script:validTunnelId  ")
$script:fixture = "TEST-ONLY-not-a-real-API-key"

function Open-SetupPage([string]$Url) {
    $script:urls.Add($Url)
}
function Read-Host {
    [CmdletBinding()]
    param([Parameter(Position=0)][string]$Prompt,[switch]$AsSecureString)
    $script:prompts.Add($Prompt)
    if ($AsSecureString) {
        if ($Prompt -ne "Paste Runtime API key here (input is hidden)") {
            throw "Wrong secret prompt."
        }
        return ConvertTo-SecureString $script:fixture -AsPlainText -Force
    }
    if ($script:inputs.Count -lt 1) { throw "Unexpected extra input requested." }
    return $script:inputs.Dequeue()
}
function Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true,ValueFromRemainingArguments=$true)]
        [object[]]$Object,
        [object]$ForegroundColor,
        [switch]$NoNewline
    )
    $script:messages.Add(($Object -join " "))
}

if ((Read-TunnelId) -cne $validTunnelId) {
    throw "Tunnel prompt failed to trim and accept a valid ID."
}
if ((Read-RuntimeApiKey) -cne $fixture) {
    throw "Hidden API-key prompt returned an unexpected value."
}
Show-ConnectorSetup $validTunnelId

if ($urls.Count -ne 3 -or
    $urls[0] -ne "https://platform.openai.com/settings/organization/tunnels" -or
    $urls[1] -ne "https://platform.openai.com/settings/organization/api-keys" -or
    $urls[2] -ne "https://chatgpt.com/plugins") {
    throw "Onboarding did not open exactly the three official pages in order."
}
if ($prompts.Count -ne 4 -or
    $prompts[0] -ne "Tunnel ID" -or $prompts[1] -ne "Tunnel ID" -or
    $prompts[2] -ne "Tunnel ID" -or
    $prompts[3] -ne "Paste Runtime API key here (input is hidden)") {
    throw "Unnecessary user prompt or missing input retry."
}
if ($inputs.Count -ne 0) { throw "Unexpected unconsumed fixture input." }
$transcript = $messages -join [Environment]::NewLine
foreach ($label in @(
    "WindowsBridge  [1/3]  Tunnel",
    "WindowsBridge  [2/3]  API key",
    "WindowsBridge  [3/3]  ChatGPT",
    "create one named WindowsBridge",
    "Reuse a Restricted key, or create one named WindowsBridge",
    "Name: WindowsBridge  |  Connection: Tunnel",
    "No authentication (NoAuth)",
    "Review permissions -> Create as a plugin -> Install.",
    "Only that successful call verifies the end-to-end connection."
)) {
    if (-not $transcript.Contains($label)) { throw "Missing expected wizard text: $label" }
}
if ($transcript.Contains($fixture)) { throw "Sensitive API key appeared in output." }
if ($transcript -match 'WindowsBridge\s*-\s*(?:PC|<COMPUTERNAME>|\$env:COMPUTERNAME)' -or
    $transcript -match 'WindowsBridge Runtime\s*-') {
    throw "User-facing resources contain machine-name or Runtime suffixes."
}
if ($source -notmatch '\$Value -cnotmatch' -or
    $source -notmatch '\$value -cmatch') {
    throw "Tunnel ID validation is not explicitly case-sensitive."
}
foreach ($bad in @("tunnel_" + ("A" * 32), "TUNNEL_" + ("a" * 32), "tunnel_bad")) {
    $thrown = $false
    try { Assert-ValidTunnelId $bad } catch { $thrown = $true }
    if (-not $thrown) { throw "Unsafe tunnel ID accepted: $bad" }
}
Assert-ValidTunnelId $validTunnelId

Write-Output "WindowsBridge onboarding 3-step integration simulation passed."
