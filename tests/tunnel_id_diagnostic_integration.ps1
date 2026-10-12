$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
$installerPath = Join-Path $repoRoot "install.ps1"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) {
    throw "Production installer PowerShell parser errors: $($parseErrors.Count)"
}

$definitions = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Assert-ValidTunnelId"
}, $true))
if ($definitions.Count -ne 1) {
    throw "Expected exactly one production Assert-ValidTunnelId definition."
}
Invoke-Expression $definitions[0].Extent.Text

$valid = "tunnel_" + ("a" * 32)
Assert-ValidTunnelId $valid

$expected = "Invalid OpenAI tunnel ID. Expected tunnel_ followed by 32 lowercase hexadecimal characters."
$invalidValues = @(
    "tunnel_0123",
    "tunnel_" + ("A" * 32),
    "not-a-tunnel",
    " tunnel_" + ("a" * 32)
)
foreach ($value in $invalidValues) {
    $message = $null
    try {
        Assert-ValidTunnelId $value
    } catch {
        $message = $_.Exception.Message
    }
    if ($message -ne $expected) {
        throw "Incorrect diagnostic for invalid tunnel ID '$value': '$message'"
    }
}

Write-Host "Tunnel ID diagnostic integration checks passed."
