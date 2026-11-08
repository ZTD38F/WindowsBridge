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
    "WindowsBridge  |  1/3  |  Tunnel",
    "Reuse your tunnel, or create one named WindowsBridge.",
    "Platform organization and ChatGPT workspace.",
    "Paste its tunnel_... ID below (not the API key).",
    "Tunnels: Read + Manage.",
    "Invalid ID: expected tunnel_ + 32 lowercase hex characters."
)) {
    if (-not $source.Contains($requiredText)) {
        throw "Guided enrollment is missing required text: $requiredText"
    }
}

# User-facing resource names must stay minimal and identical. The underlying
# tunnel ID distinguishes different devices, so no COMPUTERNAME suffix is needed.
$labels = @(
    'create one named WindowsBridge.',
    'Name: WindowsBridge',
    'Connection: Tunnel'
)
foreach ($label in $labels) {
    if (-not $source.Contains($label)) {
        throw "Missing minimal onboarding label: $label"
    }
}
if ($source -match 'WindowsBridge\s*-\s*(?:\$env:COMPUTERNAME|<COMPUTERNAME>|PC)\b' -or
    $source -match 'WindowsBridge Runtime\s*-') {
    throw "User-facing WindowsBridge resource name includes an unnecessary suffix."
}

Write-Host "Guided tunnel enrollment integration checks passed."
