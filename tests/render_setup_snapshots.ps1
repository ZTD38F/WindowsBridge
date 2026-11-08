Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repo "install.ps1"
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tokens,[ref]$errors)
if (@($errors).Count -gt 0) { throw "Installer parser failed" }
foreach ($name in @("New-GraphicalSetupWindow","Set-GraphicalSetupStage")) {
    $nodes = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    },$true))
    if ($nodes.Count -ne 1) { throw "Missing graphical renderer: $name" }
    Invoke-Expression $nodes[0].Extent.Text
}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction Stop
$out = Join-Path $repo "ci-artifacts"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$window = New-GraphicalSetupWindow
try {
    $root = $window.Content
    $root.Background = ([System.Windows.Media.BrushConverter]::new()).ConvertFromString("#0B1220")
    $fakeId = "tunnel_" + ("a" * 32)
    foreach ($stage in @(1,2,3)) {
        Set-GraphicalSetupStage -Window $window -Step $stage -SelectedTunnelId $fakeId
        $root.Measure([System.Windows.Size]::new(700,625))
        $root.Arrange([System.Windows.Rect]::new(0,0,700,625))
        $root.UpdateLayout()
        $scroll = $window.FindName("UiContentScroll")
        if ($scroll.ComputedVerticalScrollBarVisibility -ne [System.Windows.Visibility]::Collapsed) {
            throw "Default desktop WPF layout clips content at stage $stage"
        }
        $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
            700,625,96,96,[System.Windows.Media.PixelFormats]::Pbgra32
        )
        $bitmap.Render($root)
        if ($bitmap.PixelWidth -ne 700 -or $bitmap.PixelHeight -ne 625) {
            throw "Native UI render has unexpected dimensions"
        }
        $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $path = Join-Path $out ("wpf-step{0}.png" -f $stage)
        $stream = [System.IO.File]::Create($path)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
        if ((Get-Item -LiteralPath $path).Length -lt 3000) {
            throw "Native UI screenshot is unexpectedly small: $path"
        }
        Write-Host "Rendered WPF step $stage without live credentials."
    }
} finally {
    $window.Close()
}
