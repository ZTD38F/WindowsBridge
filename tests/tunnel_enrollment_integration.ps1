Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$installerPath = Join-Path (Split-Path -Parent $PSScriptRoot) "install.ps1"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
    throw "install.ps1 parse failed: $($parseErrors[0].Message)"
}

$functionNode = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Read-TunnelId"
}, $true)
if (-not $functionNode) {
    throw "Production Read-TunnelId function was not found."
}
Invoke-Expression $functionNode.Extent.Text

$script:OpenedUrls = [System.Collections.Generic.List[string]]::new()
$script:Responses = [System.Collections.Generic.Queue[string]]::new()
$script:Responses.Enqueue("not-a-tunnel")
$validTunnelId = "tunnel_" + ("a" * 32)
$script:Responses.Enqueue("  $validTunnelId  ")

function Open-SetupPage([string]$Url) {
    $script:OpenedUrls.Add($Url)
}

function Read-Host([string]$Prompt) {
    if ($script:Responses.Count -eq 0) {
        throw "Read-TunnelId requested more input than expected."
    }
    return $script:Responses.Dequeue()
}

$result = Read-TunnelId
if ($result -ne $validTunnelId) {
    throw "Guided enrollment returned an unexpected tunnel ID."
}
if ($script:Responses.Count -ne 0) {
    throw "Guided enrollment did not retry after the invalid tunnel ID."
}
if ($script:OpenedUrls.Count -ne 1 -or
    $script:OpenedUrls[0] -ne "https://platform.openai.com/settings/organization/tunnels") {
    throw "Guided enrollment did not open the canonical OpenAI tunnel settings page exactly once."
}

$source = Get-Content -LiteralPath $installerPath -Raw
foreach ($requiredText in @(
    "WindowsBridge - Step 1 of 3: Create the OpenAI tunnel",
    "Tunnels: Read + Manage.",
    "That does not look like a valid Tunnel ID.",
    "Expected: tunnel_ followed by 32 lowercase hexadecimal characters."
)) {
    if (-not $source.Contains($requiredText)) {
        throw "Guided enrollment is missing required text: $requiredText"
    }
}

Write-Host "Guided tunnel enrollment integration checks passed."
