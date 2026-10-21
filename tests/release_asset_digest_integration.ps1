$ErrorActionPreference = "Stop"

function Assert-ThrowsMessage([scriptblock]$Action, [string]$Expected) {
    $message = $null
    try {
        & $Action
    } catch {
        $message = $_.Exception.Message
    }
    if ($message -ne $Expected) {
        throw "Expected error '$Expected', received '$message'."
    }
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$updaterPath = Join-Path $repoRoot "update.ps1"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $updaterPath, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) {
    throw "Production updater PowerShell parser errors: $($parseErrors.Count)"
}

$definitions = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Assert-ReleaseAssetDigest"
}, $true))
if ($definitions.Count -ne 1) {
    throw "Expected exactly one production Assert-ReleaseAssetDigest definition."
}
Invoke-Expression $definitions[0].Extent.Text

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "WindowsBridge signed release hash Ω Ж 漢字 " + [guid]::NewGuid().ToString("N"))
$assetPath = Join-Path $fixtureRoot "WindowsBridge-v-test.zip"
try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    Set-Content -LiteralPath $assetPath -Value "immutable-release-content" -Encoding ASCII -NoNewline
    $digest = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $asset = [pscustomobject]@{
        name = "WindowsBridge-v-test.zip"
        digest = "sha256:$digest"
    }

    Assert-ReleaseAssetDigest $asset $assetPath

    Add-Content -LiteralPath $assetPath -Value "-tampered" -Encoding ASCII -NoNewline
    Assert-ThrowsMessage {
        Assert-ReleaseAssetDigest $asset $assetPath
    } "Release asset digest mismatch: WindowsBridge-v-test.zip"

    $missingDigest = [pscustomobject]@{
        name = "WindowsBridge-v-test.zip"
        digest = $null
    }
    Assert-ThrowsMessage {
        Assert-ReleaseAssetDigest $missingDigest $assetPath
    } "Release asset is missing a valid SHA-256 digest."

    $wrongAlgorithm = [pscustomobject]@{
        name = "WindowsBridge-v-test.zip"
        digest = "sha512:$digest"
    }
    Assert-ThrowsMessage {
        Assert-ReleaseAssetDigest $wrongAlgorithm $assetPath
    } "Release asset is missing a valid SHA-256 digest."

    Write-Host "Signed release asset digest integration checks passed."
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
