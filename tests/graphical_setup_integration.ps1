Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $root "install.ps1"
$source = Get-Content -LiteralPath $installer -Raw -Encoding UTF8
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tokens,[ref]$errors)
if (@($errors).Count -gt 0) { throw "Installer parser errors: $(@($errors).Count)" }

$functionNames = @(
    "ConvertFrom-Secure",
    "Test-GraphicalSetupSupport",
    "New-GraphicalSetupWindow",
    "Set-GraphicalSetupStage",
    "Read-GraphicalSetupCredentials",
    "Show-GraphicalConnectorSetup"
)
foreach ($name in $functionNames) {
    $found = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    },$true))
    if ($found.Count -ne 1) { throw "Missing/duplicate GUI function: $name" }
    Invoke-Expression $found[0].Extent.Text
}
foreach ($pattern in @(
    '[switch]$ConsoleSetup',
    'if ($ConsoleSetup) { $args += "-ConsoleSetup" }',
    '$UseGraphicalSetup = Test-GraphicalSetupSupport',
    'Read-GraphicalSetupCredentials -NeedTunnel',
    'Show-GraphicalConnectorSetup $TunnelId',
    'throw "WindowsBridge setup canceled by user."',
    'if (-not $TunnelId) { $TunnelId = Read-TunnelId }',
    'if (-not $RuntimeApiKey) { $RuntimeApiKey = Read-RuntimeApiKey }'
)) {
    if (-not $source.Contains($pattern)) { throw "GUI routing/CLI fallback contract missing: $pattern" }
}
if ($PSVersionTable.PSEdition -ne "Desktop" -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw "GUI smoke test must use Windows PowerShell 5.1"
}
$script:ConsoleSetup = $true
$script:AutoUpdate = $false
if (Test-GraphicalSetupSupport) { throw "-ConsoleSetup did not disable graphical onboarding" }
$script:ConsoleSetup = $false
$script:AutoUpdate = $true
if (Test-GraphicalSetupSupport) { throw "Background AutoUpdate must never show graphical onboarding" }

Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction Stop
$window = New-GraphicalSetupWindow
try {
    if ($window.Title -notlike "WindowsBridge*") { throw "Invalid native wizard window" }
    $tunnel = $window.FindName("UiTunnel")
    $secret = $window.FindName("UiKey")
    if ($tunnel -isnot [System.Windows.Controls.TextBox]) { throw "Tunnel input is not a TextBox" }
    if ($secret -isnot [System.Windows.Controls.PasswordBox]) { throw "Secret must use WPF PasswordBox" }
    foreach ($name in @("UiProgress","UiProgressText","UiNext","UiCancel","UiConsole","UiBack","UiError","UiOpenLink","UiContentScroll")) {
        if (-not $window.FindName($name)) { throw "Required control missing: $name" }
    }
    Set-GraphicalSetupStage -Window $window -Step 1
    if ($window.FindName("UiTunnelPanel").Visibility -ne "Visible" -or
        $window.FindName("UiKeyPanel").Visibility -ne "Collapsed" -or
        $window.FindName("UiProgress").Value -lt 30) {
        throw "Tunnel page has incorrect controls or progress"
    }
    if ($window.FindName("UiUrl").Text -ne "https://platform.openai.com/settings/organization/tunnels") {
        throw "Tunnel page points to an unexpected origin"
    }
    Set-GraphicalSetupStage -Window $window -Step 2
    if ($window.FindName("UiKeyPanel").Visibility -ne "Visible" -or
        $window.FindName("UiTunnelPanel").Visibility -ne "Collapsed" -or
        $window.FindName("UiProgress").Value -lt 60) {
        throw "Restricted key page has incorrect controls or progress"
    }
    if ($window.FindName("UiUrl").Text -ne "https://platform.openai.com/settings/organization/api-keys") {
        throw "API key page points to an unexpected origin"
    }
    Set-GraphicalSetupStage -Window $window -Step 3 -SelectedTunnelId ("tunnel_" + ("a" * 32))
    if ($window.FindName("UiProgress").Value -ne 100 -or
        $window.FindName("UiNext").Content -ne "Закрыть" -or
        $window.FindName("UiKeyPanel").Visibility -ne "Collapsed" -or
        $window.FindName("UiUrl").Text -ne "https://chatgpt.com/plugins") {
        throw "ChatGPT completion page incorrectly exposes secret input or status"
    }
} finally {
    $window.Close()
}

Write-Output "Native WPF window parsed and 3-stage credential/connector UI smoke check passed (no live secrets)."
