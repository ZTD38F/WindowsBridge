[CmdletBinding()]
param(
    [string]$TunnelId,
    [string]$RuntimeApiKey,
    [string]$SourceRef = "stable",
    [switch]$AutoUpdate,
    [switch]$DisableAutoUpdate,
    [switch]$PreflightOnly,
    [switch]$ConsoleSetup
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Repo = "ZTD38F/WindowsBridge"
$Root = Join-Path $env:ProgramData "WindowsBridge"
$Bin = Join-Path $Root "bin"
$Logs = Join-Path $Root "logs"
$Releases = Join-Path $Root "releases"
$Runtime = Join-Path $Root "runtime"
$Cache = Join-Path $Root "cache"
$Management = Join-Path $Root "management"
$State = Join-Path $Root "state"
$Secrets = Join-Path $Root "secrets"
$RouterTokenFile = Join-Path $Secrets "router_token"
$BackendTokenFile = Join-Path $Secrets "backend_token"
$RuntimeKeyFile = Join-Path $Secrets "control_plane_api_key"
$RouteFile = Join-Path $State "route.json"
$RouterBase = "http://127.0.0.1:18766"
$Config = Join-Path $Root "config.json"
$Current = Join-Path $Root "current.txt"
$Launch = Join-Path $Root "launch.ps1"
$UpdateScript = Join-Path $Root "update.ps1"
$ControlScript = Join-Path $env:SystemRoot "System32\windowsbridgectl.ps1"
$ControlCmd = Join-Path $env:SystemRoot "System32\windowsbridgectl.cmd"
$TaskName = "WindowsBridge"
$AutoUpdateTaskName = "WindowsBridge Auto Update"
$HealthBase = "http://127.0.0.1:18765"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-InstallerEnvironment {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw "WindowsBridge requires Windows."
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw "WindowsBridge requires 64-bit Windows."
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "WindowsBridge requires Windows PowerShell 5.1 or PowerShell 7."
    }

    $requiredCommands = @(
        "Expand-Archive",
        "Get-FileHash",
        "Invoke-RestMethod",
        "Invoke-WebRequest",
        "Start-Process"
    )
    foreach ($command in $requiredCommands) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required PowerShell command is unavailable: $command"
        }
    }

    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    return [ordered]@{
        ok = $true
        windows_64_bit = [Environment]::Is64BitOperatingSystem
        powershell_version = [string]$PSVersionTable.PSVersion
        powershell_edition = [string]$PSVersionTable.PSEdition
    }
}

function ConvertFrom-Secure([Security.SecureString]$Secure) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Resolve-SourceCommit([string]$Ref) {
    if ($Ref -notmatch '^[A-Za-z0-9._-]{1,80}$') { throw "Invalid SourceRef." }

    try {
        $commit = Invoke-RestMethod "https://api.github.com/repos/$Repo/commits/$Ref" -Headers @{"User-Agent"="WindowsBridge-Installer"}
    } catch {
        throw "Could not resolve WindowsBridge source ref '$Ref' to an immutable GitHub commit: $($_.Exception.Message)"
    }

    $sha = [string]$commit.sha
    if ($sha -notmatch '^[0-9a-f]{40}$') { throw "GitHub returned an invalid WindowsBridge commit SHA." }
    return $sha
}

function Invoke-Elevated {
    # Pin the installer before crossing the UAC boundary. The branch may move
    # between the one-line bootstrap and elevation, but this exact commit cannot.
    $ResolvedBootstrapRef = Resolve-SourceCommit $SourceRef
    $selfUrl = "https://raw.githubusercontent.com/$Repo/$ResolvedBootstrapRef/install.ps1"
    $tmp = Join-Path $env:TEMP ("WindowsBridge-install-" + [guid]::NewGuid().ToString("N") + ".ps1")
    Invoke-WebRequest -UseBasicParsing $selfUrl -OutFile $tmp
    if ($TunnelId) { $env:WINDOWSBRIDGE_TUNNEL_ID = $TunnelId }
    if ($RuntimeApiKey) { $env:WINDOWSBRIDGE_RUNTIME_API_KEY = $RuntimeApiKey }
    try {
        $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $tmp),"-SourceRef",$ResolvedBootstrapRef)
        if ($AutoUpdate) { $args += "-AutoUpdate" }
        if ($DisableAutoUpdate) { $args += "-DisableAutoUpdate" }
        if ($ConsoleSetup) { $args += "-ConsoleSetup" }
        $p = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args -Wait -PassThru
        exit $p.ExitCode
    } finally {
        $env:WINDOWSBRIDGE_TUNNEL_ID = $null
        $env:WINDOWSBRIDGE_RUNTIME_API_KEY = $null
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-ReleaseAsset([object]$Release, [string]$Name) {
    $asset = $Release.assets | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $asset) { throw "GitHub Release asset not found: $Name" }
    if (-not $asset.digest -or -not ([string]$asset.digest).StartsWith("sha256:")) {
        throw "GitHub Release asset has no SHA-256 digest: $Name"
    }
    return $asset
}

function Download-VerifiedAsset([object]$Asset, [string]$Destination) {
    Invoke-WebRequest -UseBasicParsing $Asset.browser_download_url -OutFile $Destination
    $expected = ([string]$Asset.digest).Substring(7).ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 $Destination).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        throw "SHA-256 verification failed for $($Asset.name)"
    }
}

function Set-RestrictedSecretAcl([string]$Path, [switch]$Container) {
    $systemSid = [Security.Principal.SecurityIdentifier]::new("S-1-5-18")
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    $inheritance = if ($Container) {
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        [Security.AccessControl.InheritanceFlags]::None
    }

    $acl = if ($Container) {
        [Security.AccessControl.DirectorySecurity]::new()
    } else {
        [Security.AccessControl.FileSecurity]::new()
    }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($administratorsSid)

    foreach ($sid in @($systemSid, $administratorsSid)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }

    Set-Acl -Path $Path -AclObject $acl
}

function Ensure-LocalSecret([string]$Path) {
    if (-not (Test-Path $Path) -or [string]::IsNullOrWhiteSpace((Get-Content $Path -Raw -ErrorAction SilentlyContinue))) {
        $bytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $value = ([BitConverter]::ToString($bytes)).Replace("-", "").ToLowerInvariant()
        Set-Content -Path $Path -Value $value -Encoding ASCII -NoNewline
    }
}

function Get-ExistingConfig {
    if (-not (Test-Path $Config)) { return $null }
    try {
        $cfg = Get-Content $Config -Raw | ConvertFrom-Json
        $enc = [Convert]::FromBase64String($cfg.api_key_dpapi)
        $raw = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [pscustomobject]@{
            tunnel_id = [string]$cfg.tunnel_id
            runtime_api_key = [Text.Encoding]::UTF8.GetString($raw)
        }
    } catch {
        return $null
    }
}


function Open-SetupPage([string]$Url) {
    Write-Host "  OPEN IN BROWSER" -ForegroundColor DarkCyan
    Write-Host "  $Url" -ForegroundColor Cyan
    try {
        Start-Process $Url -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "  Browser did not open automatically. Use the link above." -ForegroundColor Yellow
    }
}

function Write-SetupHeading([int]$Step, [string]$Title, [string]$Subtitle) {
    if ($Step -lt 1 -or $Step -gt 3) { throw "Invalid WindowsBridge setup step." }
    $track = ('#' * $Step) + ('-' * (3 - $Step))
    Write-Host ""
    Write-Host "  WindowsBridge  /  SECURE SETUP" -ForegroundColor Cyan
    Write-Host ("  [{0}]  STEP {1}/3" -f $track, $Step) -ForegroundColor DarkCyan
    Write-Host "  ----------------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  WindowsBridge  [{0}/3]  {1}" -f $Step, $Title) -ForegroundColor White
    Write-Host ("  {0}" -f $Subtitle) -ForegroundColor Gray
    Write-Host ""
}

function Test-GraphicalSetupSupport {
    if ($ConsoleSetup -or $AutoUpdate -or -not [Environment]::UserInteractive) { return $false }
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        Write-Host "WindowsBridge: GUI needs STA; using console." -ForegroundColor Yellow
        return $false
    }
    try {
        if ((Get-Process -Id $PID).SessionId -eq 0) { return $false }
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction Stop
        return $true
    } catch {
        Write-Host "WindowsBridge: WPF unavailable; using console." -ForegroundColor Yellow
        return $false
    }
}

function New-GraphicalSetupWindow {
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WindowsBridge — подключение"
        Width="760" Height="700" MinWidth="580" MinHeight="510"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize"
        Background="#0B1220" Foreground="#E8F1FC" FontFamily="Segoe UI"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="WizardButton" TargetType="{x:Type Button}">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,11"/>
      <Setter Property="Background" Value="#56CEDB"/>
      <Setter Property="Foreground" Value="#071826"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border Background="{TemplateBinding Background}" CornerRadius="9"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Opacity" Value="0.88"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,14">
      <DockPanel LastChildFill="False">
        <TextBlock Text="WindowsBridge" Foreground="#FFFFFF" FontWeight="Bold" FontSize="22"
                   DockPanel.Dock="Left"/>
        <TextBlock Text="SECURE MCP" Foreground="#6C829B" FontSize="11"
                   DockPanel.Dock="Right" Margin="0,6,0,0"/>
      </DockPanel>
      <TextBlock x:Name="UiProgressText" Text="01 / 03" Foreground="#58D9E4"
                 FontSize="12" FontWeight="SemiBold" Margin="0,12,0,6"/>
      <ProgressBar x:Name="UiProgress" Minimum="0" Maximum="100" Value="33" Height="5"
                   Foreground="#58D9E4" Background="#25364C" BorderThickness="0"/>
    </StackPanel>
    <Border Grid.Row="1" Background="#121F33" BorderBrush="#294158"
            BorderThickness="1" CornerRadius="18" Padding="19">
      <ScrollViewer x:Name="UiContentScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel>
          <TextBlock x:Name="UiEyebrow" Text="01  /  ТУННЕЛЬ" Foreground="#58D9E4"
                     FontSize="12" FontWeight="SemiBold"/>
          <TextBlock x:Name="UiTitle" Text="Подключение к OpenAI" FontSize="27"
                     FontWeight="SemiBold" Foreground="#F5F8FF" Margin="0,8,0,8"/>
          <TextBlock x:Name="UiDescription" TextWrapping="Wrap" FontSize="14"
                     Foreground="#B8C9DB" LineHeight="23" MaxWidth="600"/>
          <TextBlock x:Name="UiInstructions" TextWrapping="Wrap" Margin="0,10,0,9"
                     FontSize="13" Foreground="#DEE8F5" LineHeight="23"/>
          <Border x:Name="UiTunnelPanel" Background="#0C1728" CornerRadius="10"
                  Padding="11" Margin="0,0,0,8">
            <StackPanel>
              <TextBlock Text="TUNNEL ID" Foreground="#8BA4BE" FontSize="11" FontWeight="Bold"/>
              <TextBox x:Name="UiTunnel" FontFamily="Consolas" FontSize="14" Margin="0,8,0,0"
                       MinHeight="34" Padding="8" Foreground="#F5F8FF" Background="#192B44"
                       CaretBrush="#56CEDB" BorderBrush="#355774" BorderThickness="1"
                       ToolTip="tunnel_ и 32 строчные шестнадцатеричные цифры"/>
            </StackPanel>
          </Border>
          <Border x:Name="UiKeyPanel" Background="#0C1728" CornerRadius="10"
                  Padding="11" Margin="0,0,0,8" Visibility="Collapsed">
            <StackPanel>
              <TextBlock Text="RESTRICTED API KEY" Foreground="#8BA4BE" FontSize="11"
                         FontWeight="Bold"/>
              <PasswordBox x:Name="UiKey" FontSize="14" Margin="0,8,0,0"
                           MinHeight="34" Padding="8" Foreground="#F5F8FF"
                           Background="#192B44" BorderBrush="#355774"
                           BorderThickness="1" ToolTip="Ввод скрыт; ключ не копируется в логи"/>
            </StackPanel>
          </Border>
          <TextBlock x:Name="UiError" TextWrapping="Wrap" Foreground="#FDA8A8"
                     FontSize="12" Margin="0,0,0,5"/>
          <Button x:Name="UiOpenLink" Style="{StaticResource WizardButton}"
                  Background="#22374D" Foreground="#B9EAF0"
                  HorizontalAlignment="Left" Content="Открыть OpenAI Platform"/>
          <TextBlock x:Name="UiUrl" Foreground="#728EA8" FontSize="11"
                     TextWrapping="Wrap" Margin="0,6,0,0"/>
        </StackPanel>
      </ScrollViewer>
    </Border>
    <Grid Grid.Row="2" Margin="0,14,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Button x:Name="UiConsole" Grid.Column="0" Style="{StaticResource WizardButton}"
              Background="#172638" Foreground="#A9BCD0" Content="Консольный режим"
              Margin="0,0,10,0"/>
      <Button x:Name="UiBack" Grid.Column="2" Style="{StaticResource WizardButton}"
              Background="#24344B" Foreground="#DBE7F4" Content="Назад"
              Margin="0,0,8,0" Visibility="Collapsed"/>
      <Button x:Name="UiCancel" Grid.Column="3" Style="{StaticResource WizardButton}"
              Background="#24344B" Foreground="#DBE7F4" Content="Отмена"
              IsCancel="True" Margin="0,0,8,0"/>
      <Button x:Name="UiNext" Grid.Column="4" Style="{StaticResource WizardButton}"
              Content="Продолжить" IsDefault="True"/>
    </Grid>
  </Grid>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    return [System.Windows.Markup.XamlReader]::Load($reader)
}

function Set-GraphicalSetupStage {
    param([object]$Window, [ValidateSet(1,2,3)][int]$Step, [string]$SelectedTunnelId = "")
    $tunnel = $Window.FindName("UiTunnelPanel")
    $key = $Window.FindName("UiKeyPanel")
    $back = $Window.FindName("UiBack")
    $next = $Window.FindName("UiNext")
    $console = $Window.FindName("UiConsole")
    $cancel = $Window.FindName("UiCancel")
    $Window.FindName("UiError").Text = ""
    $Window.FindName("UiProgress").Value = $Step * 100 / 3
    $Window.FindName("UiProgressText").Text = ("{0:00} / 03" -f $Step)
    $tunnel.Visibility = [System.Windows.Visibility]::Collapsed
    $key.Visibility = [System.Windows.Visibility]::Collapsed
    $back.Visibility = [System.Windows.Visibility]::Collapsed
    $console.Visibility = [System.Windows.Visibility]::Visible
    $cancel.Visibility = [System.Windows.Visibility]::Visible
    $next.Content = "Продолжить"

    $url = ""
    if ($Step -eq 1) {
        $Window.FindName("UiEyebrow").Text = "01  /  ТУННЕЛЬ"
        $Window.FindName("UiTitle").Text = "Подключение к OpenAI"
        $Window.FindName("UiDescription").Text = "Создайте туннель WindowsBridge или выберите существующий. Соединение исходящее: открывать входящие порты на ПК не нужно."
        $Window.FindName("UiInstructions").Text = @(
            "1. Выберите нужную организацию и пространство ChatGPT."
            "2. Создайте туннель с именем WindowsBridge."
            "3. Скопируйте его ID (не ключ). При ошибке 403 нужны права Tunnels: Read + Manage."
        ) -join [Environment]::NewLine
        $tunnel.Visibility = [System.Windows.Visibility]::Visible
        $url = "https://platform.openai.com/settings/organization/tunnels"
    } elseif ($Step -eq 2) {
        $Window.FindName("UiEyebrow").Text = "02  /  ДОСТУП"
        $Window.FindName("UiTitle").Text = "Защищённый ключ"
        $Window.FindName("UiDescription").Text = "Вставьте Restricted API key из той же организации. Ключ скрыт, не выводится на экран и не передаётся сайту WindowsBridge."
        $Window.FindName("UiInstructions").Text = @(
            "1. Откройте API Keys в OpenAI Platform."
            "2. Дайте только Tunnels: Read + Use."
            "3. Вставьте ключ ниже. Admin API key использовать нельзя."
        ) -join [Environment]::NewLine
        $key.Visibility = [System.Windows.Visibility]::Visible
        $back.Visibility = [System.Windows.Visibility]::Visible
        $url = "https://platform.openai.com/settings/organization/api-keys"
    } else {
        $Window.FindName("UiEyebrow").Text = "03  /  CHATGPT"
        $Window.FindName("UiTitle").Text = "WindowsBridge запущен"
        $Window.FindName("UiDescription").Text = "Локальная проверка туннеля завершена. Подключение ChatGPT необходимо подтвердить отдельно."
        $Window.FindName("UiInstructions").Text = @(
            "1. Plugins → + → Add custom MCP server."
            "2. Имя: WindowsBridge. Connection: Tunnel."
            "3. Выберите туннель: $SelectedTunnelId"
            "4. Authentication: No authentication (NoAuth). Проверьте разрешения и установите плагин."
            "5. Для E2E вызовите в ChatGPT ТОЛЬКО read-only инструмент WindowsBridge."
        ) -join [Environment]::NewLine
        $next.Content = "Закрыть"
        $console.Visibility = [System.Windows.Visibility]::Collapsed
        $cancel.Visibility = [System.Windows.Visibility]::Collapsed
        $url = "https://chatgpt.com/plugins"
    }
    $Window.FindName("UiUrl").Text = $url
    $Window.FindName("UiOpenLink").Content = if ($Step -eq 3) { "Открыть ChatGPT Plugins" } else { "Открыть OpenAI Platform" }
}

function Read-GraphicalSetupCredentials {
    param([bool]$NeedTunnel, [bool]$NeedKey, [string]$InitialTunnelId = "")
    $window = New-GraphicalSetupWindow
    $state = [pscustomobject]@{
        Mode = "cancel"
        Step = $(if ($NeedTunnel) { 1 } else { 2 })
        TunnelId = $InitialTunnelId
        RuntimeApiKey = $null
    }
    $inputTunnel = $window.FindName("UiTunnel")
    $inputKey = $window.FindName("UiKey")
    $inputTunnel.Text = $InitialTunnelId
    $next = $window.FindName("UiNext")
    $back = $window.FindName("UiBack")
    $errorText = $window.FindName("UiError")
    Set-GraphicalSetupStage -Window $window -Step $state.Step
    if (-not $NeedTunnel) { $back.Visibility = [System.Windows.Visibility]::Collapsed }

    $window.FindName("UiOpenLink").Add_Click({
        if ($state.Step -eq 1) {
            Open-SetupPage "https://platform.openai.com/settings/organization/tunnels"
        } else {
            Open-SetupPage "https://platform.openai.com/settings/organization/api-keys"
        }
    }.GetNewClosure())
    $next.Add_Click({
        if ($state.Step -eq 1) {
            $candidate = $inputTunnel.Text.Trim()
            if ($candidate -cnotmatch '^tunnel_[0-9a-f]{32}$') {
                $errorText.Text = "Нужен ID формата tunnel_ и 32 строчных шестнадцатеричных символа."
                return
            }
            $state.TunnelId = $candidate
            if ($NeedKey) {
                $state.Step = 2
                Set-GraphicalSetupStage -Window $window -Step 2
                $inputKey.Focus() | Out-Null
            } else {
                $state.Mode = "ok"
                $window.DialogResult = $true
            }
        } else {
            $secret = $inputKey.SecurePassword
            try {
                if ($secret.Length -eq 0) {
                    $errorText.Text = "Ключ не может быть пустым."
                    return
                }
                $state.RuntimeApiKey = ConvertFrom-Secure $secret
            } finally {
                $secret.Dispose()
            }
            if ([string]::IsNullOrWhiteSpace($state.RuntimeApiKey)) {
                $state.RuntimeApiKey = $null
                $errorText.Text = "Ключ не может быть пустым."
                return
            }
            $state.Mode = "ok"
            $window.DialogResult = $true
        }
    }.GetNewClosure())
    $back.Add_Click({
        if ($NeedTunnel -and $state.Step -eq 2) {
            $state.Step = 1
            Set-GraphicalSetupStage -Window $window -Step 1
            $inputTunnel.Focus() | Out-Null
        }
    }.GetNewClosure())
    $window.FindName("UiConsole").Add_Click({
        $state.Mode = "console"
        $window.Close()
    }.GetNewClosure())
    try {
        [void]$window.ShowDialog()
        return $state
    } finally {
        $inputKey.Clear()
    }
}

function Show-GraphicalConnectorSetup([string]$SelectedTunnelId) {
    $window = New-GraphicalSetupWindow
    Set-GraphicalSetupStage -Window $window -Step 3 -SelectedTunnelId $SelectedTunnelId
    $window.FindName("UiOpenLink").Add_Click({
        Open-SetupPage "https://chatgpt.com/plugins"
    }.GetNewClosure())
    $window.FindName("UiNext").Add_Click({
        $window.Close()
    }.GetNewClosure())
    [void]$window.ShowDialog()
}


function Assert-ValidTunnelId([string]$Value) {
    if ($Value -cnotmatch '^tunnel_[0-9a-f]{32}$') {
        throw "Invalid OpenAI tunnel ID. Expected tunnel_ followed by 32 lowercase hexadecimal characters."
    }
}

function Read-TunnelId {
    $url = "https://platform.openai.com/settings/organization/tunnels"

    Write-SetupHeading 1 "Tunnel" "Connect your PC to the right OpenAI workspace."
    Write-Host "  YOUR ACTION" -ForegroundColor Yellow
    Write-Host "  1  Reuse your tunnel, or create one named WindowsBridge." -ForegroundColor White
    Write-Host "  2  Confirm the Platform organization and ChatGPT workspace." -ForegroundColor Gray
    Write-Host "  3  Copy the Tunnel ID, not an API key." -ForegroundColor Gray
    Write-Host "     Format: tunnel_ followed by 32 lowercase hex characters." -ForegroundColor DarkGray
    Write-Host "     Cannot create it (403)? Request Tunnels: Read + Manage." -ForegroundColor DarkGray
    Write-Host ""
    Open-SetupPage $url
    Write-Host ""

    while ($true) {
        $value = (Read-Host "Tunnel ID").Trim()
        if ($value -cmatch '^tunnel_[0-9a-f]{32}$') {
            Write-Host "  [OK] Tunnel ID validated locally." -ForegroundColor Green
            return $value
        }
        Write-Host "  [!] Invalid ID. Expected tunnel_ + 32 lowercase hex characters." -ForegroundColor Red
        Write-Host "      Copy the tunnel ID from Platform; do not paste a key." -ForegroundColor Yellow
    }
}

function Read-RuntimeApiKey {
    $url = "https://platform.openai.com/settings/organization/api-keys"

    Write-SetupHeading 2 "API key" "Grant the tunnel only the permissions it needs."
    Write-Host "  YOUR ACTION" -ForegroundColor Yellow
    Write-Host "  1  Reuse a Restricted key, or create one named WindowsBridge." -ForegroundColor White
    Write-Host "  2  Same organization; only Tunnels -> Read + Use." -ForegroundColor Gray
    Write-Host "  3  Copy the key and paste it into the hidden prompt below." -ForegroundColor Gray
    Write-Host "     Never use an Admin API key; do not share it in chat." -ForegroundColor Yellow
    Write-Host ""
    Open-SetupPage $url
    Write-Host ""

    while ($true) {
        $secure = Read-Host "Paste Runtime API key here (input is hidden)" -AsSecureString
        $value = ConvertFrom-Secure $secure
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Write-Host "  [OK] Runtime API key received (content hidden)." -ForegroundColor Green
            return $value
        }
        Write-Host "  [!] Key cannot be empty; try again." -ForegroundColor Red
    }
}

function Show-ConnectorSetup([string]$ResolvedTunnelId) {
    $url = "https://chatgpt.com/plugins"

    Write-SetupHeading 3 "ChatGPT" "Finish the connection and verify it from ChatGPT."
    Write-Host "  YOUR ACTION" -ForegroundColor Yellow
    Write-Host "  1  Plugins -> + -> Add custom MCP server." -ForegroundColor White
    Write-Host "  2  Name: WindowsBridge  |  Connection: Tunnel" -ForegroundColor Yellow
    Write-Host "     Tunnel: select yours or paste $ResolvedTunnelId" -ForegroundColor Gray
    Write-Host "     Authentication: No authentication (NoAuth)" -ForegroundColor Gray
    Write-Host "  3  Review permissions -> Create as a plugin -> Install." -ForegroundColor White
    Write-Host ""
    Open-SetupPage $url
    Write-Host ""
    Write-Host "  VERIFY CONNECTION" -ForegroundColor Yellow
    Write-Host "  Call a READ-ONLY WindowsBridge system-information tool in ChatGPT." -ForegroundColor White
    Write-Host "  Only that successful call verifies the end-to-end connection." -ForegroundColor Yellow
    Write-Host "  Diagnostics: windowsbridgectl check / windowsbridgectl ui" -ForegroundColor DarkGray
}

$InstallerEnvironment = Test-InstallerEnvironment
if ($PreflightOnly) {
    $InstallerEnvironment | ConvertTo-Json -Compress
    exit 0
}

if (-not (Test-Administrator)) { Invoke-Elevated }

New-Item -ItemType Directory -Force -Path $Root,$Bin,$Logs,$Releases,$Runtime,$Cache,$Management,$State,$Secrets | Out-Null
Set-RestrictedSecretAcl -Path $Secrets -Container

$existing = Get-ExistingConfig
if (-not $TunnelId) { $TunnelId = $env:WINDOWSBRIDGE_TUNNEL_ID }
if (-not $RuntimeApiKey) { $RuntimeApiKey = $env:WINDOWSBRIDGE_RUNTIME_API_KEY }
if (-not $TunnelId -and $existing) { $TunnelId = $existing.tunnel_id }
if (-not $RuntimeApiKey -and $existing) { $RuntimeApiKey = $existing.runtime_api_key }

$PreviousTunnelId = if ($existing) { [string]$existing.tunnel_id } else { $null }

if ($AutoUpdate -and -not $existing) {
    throw "Automatic update requires an existing WindowsBridge installation."
}

$UseGraphicalSetup = Test-GraphicalSetupSupport
if ($UseGraphicalSetup -and (-not $TunnelId -or -not $RuntimeApiKey)) {
    $ui = Read-GraphicalSetupCredentials -NeedTunnel (-not $TunnelId) -NeedKey (-not $RuntimeApiKey) -InitialTunnelId $TunnelId
    if ($ui.Mode -eq "console") {
        $UseGraphicalSetup = $false
    } elseif ($ui.Mode -eq "ok") {
        if (-not $TunnelId) { $TunnelId = $ui.TunnelId }
        if (-not $RuntimeApiKey) { $RuntimeApiKey = $ui.RuntimeApiKey }
    } else {
        throw "WindowsBridge setup canceled by user."
    }
    $ui = $null
}

if (-not $TunnelId) { $TunnelId = Read-TunnelId }
if (-not $RuntimeApiKey) { $RuntimeApiKey = Read-RuntimeApiKey }

Assert-ValidTunnelId $TunnelId
if ([string]::IsNullOrWhiteSpace($RuntimeApiKey)) { throw "Runtime API key is required." }

$NeedsConnectorSetup = (-not $AutoUpdate) -and ((-not $existing) -or ($PreviousTunnelId -ne $TunnelId))

Write-Host ""
Write-Host "  WindowsBridge  /  INSTALLING" -ForegroundColor Cyan
Write-Host "  Pin source -> verify downloads -> start runtime -> check readiness" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Resolving immutable WindowsBridge commit from GitHub..."
$ResolvedRef = Resolve-SourceCommit $SourceRef
$RawBase = "https://raw.githubusercontent.com/ZTD38F/WindowsBridge/$ResolvedRef"

$stage = Join-Path $Releases (".stage-" + [guid]::NewGuid().ToString("N"))
$releaseDir = Join-Path $Releases $ResolvedRef
$previousRef = if (Test-Path $Current) { (Get-Content $Current -Raw).Trim() } else { $null }

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $stage "app"),(Join-Path $stage "bin"),(Join-Path $stage "management") | Out-Null

    Write-Host "Downloading WindowsBridge source from GitHub commit $ResolvedRef..."
    Invoke-WebRequest -UseBasicParsing "$RawBase/windowsbridge.py" -OutFile (Join-Path $stage "app\windowsbridge.py")
    Invoke-WebRequest -UseBasicParsing "$RawBase/http_runtime.py" -OutFile (Join-Path $stage "app\http_runtime.py")
    Invoke-WebRequest -UseBasicParsing "$RawBase/requirements.lock" -OutFile (Join-Path $stage "app\requirements.lock")
    Invoke-WebRequest -UseBasicParsing "$RawBase/update.ps1" -OutFile (Join-Path $stage "management\update.ps1")
    Invoke-WebRequest -UseBasicParsing "$RawBase/windowsbridgectl.ps1" -OutFile (Join-Path $stage "management\windowsbridgectl.ps1")
    Invoke-WebRequest -UseBasicParsing "$RawBase/supervisor.py" -OutFile (Join-Path $stage "management\supervisor.py")

    Write-Host "Downloading verified uv from GitHub Releases..."
    $uvRelease = Invoke-RestMethod "https://api.github.com/repos/astral-sh/uv/releases/latest" -Headers @{"User-Agent"="WindowsBridge-Installer"}
    $uvArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64" } else { "x86_64" }
    $uvName = "uv-$uvArch-pc-windows-msvc.zip"
    $uvAsset = Get-ReleaseAsset $uvRelease $uvName
    $uvZip = Join-Path $stage $uvName
    Download-VerifiedAsset $uvAsset $uvZip
    $uvDir = Join-Path $stage "uv"
    Expand-Archive $uvZip -DestinationPath $uvDir -Force
    $uvExe = Get-ChildItem $uvDir -Filter "uv.exe" -Recurse | Select-Object -First 1
    if (-not $uvExe) { throw "uv.exe was not found in the verified GitHub archive." }
    Copy-Item $uvExe.FullName (Join-Path $Bin "uv.exe") -Force
    $uv = Join-Path $Bin "uv.exe"

    Write-Host "Creating isolated Python runtime inside WindowsBridge..."
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $Runtime "python"
    $env:UV_CACHE_DIR = Join-Path $Cache "uv"
    $env:UV_PYTHON_NO_REGISTRY = "1"
    $env:UV_PYTHON_INSTALL_BIN = "0"
    New-Item -ItemType Directory -Force -Path $env:UV_PYTHON_INSTALL_DIR,$env:UV_CACHE_DIR | Out-Null
    & $uv python install 3.12 --install-dir $env:UV_PYTHON_INSTALL_DIR
    if ($LASTEXITCODE -ne 0) { throw "uv could not install Python 3.12." }
    & $uv venv --python 3.12 (Join-Path $stage "venv")
    if ($LASTEXITCODE -ne 0) { throw "uv could not create the WindowsBridge virtual environment." }
    $venvPython = Join-Path $stage "venv\Scripts\python.exe"
    & $uv pip install --python $venvPython -r (Join-Path $stage "app\requirements.lock")
    if ($LASTEXITCODE -ne 0) { throw "WindowsBridge dependency installation failed." }
    & $venvPython -m py_compile (Join-Path $stage "app\windowsbridge.py") (Join-Path $stage "app\http_runtime.py") (Join-Path $stage "management\supervisor.py")
    if ($LASTEXITCODE -ne 0) { throw "WindowsBridge Python compile check failed." }

    Write-Host "Downloading verified official OpenAI tunnel-client from GitHub Releases..."
    $tunnelRelease = Invoke-RestMethod "https://api.github.com/repos/openai/tunnel-client/releases/latest" -Headers @{"User-Agent"="WindowsBridge-Installer"}
    $tunnelArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
    $tunnelName = "tunnel-client-$($tunnelRelease.tag_name)-windows-$tunnelArch.zip"
    $tunnelAsset = Get-ReleaseAsset $tunnelRelease $tunnelName
    $tunnelZip = Join-Path $stage $tunnelName
    Download-VerifiedAsset $tunnelAsset $tunnelZip
    $tunnelDir = Join-Path $stage "tunnel"
    Expand-Archive $tunnelZip -DestinationPath $tunnelDir -Force
    $tunnelExe = Get-ChildItem $tunnelDir -Filter "tunnel-client.exe" -Recurse | Select-Object -First 1
    if (-not $tunnelExe) { throw "tunnel-client.exe was not found in the verified OpenAI GitHub archive." }
    Copy-Item $tunnelExe.FullName (Join-Path $stage "bin\tunnel-client.exe") -Force
    Copy-Item $tunnelExe.FullName (Join-Path $Bin "tunnel-client.exe") -Force
    $tunnelFinal = Join-Path $stage "bin\tunnel-client.exe"

    $env:CONTROL_PLANE_API_KEY = $RuntimeApiKey
    $env:CONTROL_PLANE_TUNNEL_ID = $TunnelId
    $env:MCP_COMMAND = '"' + $venvPython + '" "' + (Join-Path $stage "app\windowsbridge.py") + '"'
    $env:WINDOWSBRIDGE_ALLOWED_ROOTS = "*"

    Write-Host "Validating OpenAI Secure MCP Tunnel..."
    & $tunnelFinal doctor --explain
    if ($LASTEXITCODE -ne 0) { throw "tunnel-client doctor failed." }

    if (Test-Path $releaseDir) { Remove-Item $releaseDir -Recurse -Force }
    Move-Item $stage $releaseDir

    $keyBytes = [Text.Encoding]::UTF8.GetBytes($RuntimeApiKey)
    $protected = [Security.Cryptography.ProtectedData]::Protect($keyBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)

    [ordered]@{
        version = "0.4.17"
        source_commit = $ResolvedRef
        tunnel_id = $TunnelId
        api_key_dpapi = [Convert]::ToBase64String($protected)
        installed_at = (Get-Date).ToString("o")
        uv_release = [string]$uvRelease.tag_name
        tunnel_client_release = [string]$tunnelRelease.tag_name
    } | ConvertTo-Json | Set-Content $Config -Encoding UTF8

    Set-Content $Current $ResolvedRef -Encoding ASCII
    Set-Content -Path $RuntimeKeyFile -Value $RuntimeApiKey -Encoding ASCII -NoNewline
    Set-RestrictedSecretAcl -Path $RuntimeKeyFile
    Ensure-LocalSecret $RouterTokenFile
    Set-RestrictedSecretAcl -Path $RouterTokenFile
    Ensure-LocalSecret $BackendTokenFile
    Set-RestrictedSecretAcl -Path $BackendTokenFile
    [ordered]@{ generation = $ResolvedRef; port = 18771 } | ConvertTo-Json -Compress | Set-Content $RouteFile -Encoding ASCII
    Copy-Item (Join-Path $releaseDir "management\supervisor.py") (Join-Path $Management "supervisor.py") -Force

    $launchContent = @'
$ErrorActionPreference = "Stop"
$Root = Join-Path $env:ProgramData "WindowsBridge"
$mutex = [Threading.Mutex]::new($false, "Global\WindowsBridgeTunnelRuntime")
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { exit 0 }

    $cfg = Get-Content (Join-Path $Root "config.json") -Raw | ConvertFrom-Json
    $ref = (Get-Content (Join-Path $Root "current.txt") -Raw).Trim()
    $release = Join-Path (Join-Path $Root "releases") $ref
    $python = Join-Path $release "venv\Scripts\python.exe"
    $route = Get-Content (Join-Path $Root "state\route.json") -Raw | ConvertFrom-Json
    $serverPidFile = Join-Path $Root "state\server.pid"
    $supervisorPidFile = Join-Path $Root "state\supervisor.pid"
    $tunnelPidFile = Join-Path $Root "state\tunnel.pid"
    $routerToken = Join-Path $Root "secrets\router_token"
    $backendToken = Join-Path $Root "secrets\backend_token"
    $runtimeKey = Join-Path $Root "secrets\control_plane_api_key"
    $tunnel = Join-Path $Root "bin\tunnel-client.exe"
    $log = Join-Path $Root "logs\tunnel.log"
    $errLog = Join-Path $Root "logs\tunnel.err.log"

    function Alive([string]$Path) {
        if (-not (Test-Path $Path)) { return $false }
        $v = (Get-Content $Path -Raw).Trim()
        if ($v -notmatch '^\d+$') { return $false }
        return $null -ne (Get-Process -Id ([int]$v) -ErrorAction SilentlyContinue)
    }

    if (-not (Test-Path $runtimeKey)) {
        $enc = [Convert]::FromBase64String($cfg.api_key_dpapi)
        $raw = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        try { Set-Content -Path $runtimeKey -Value ([Text.Encoding]::UTF8.GetString($raw)) -Encoding ASCII -NoNewline }
        finally { $raw = $null }
    }

    if (-not (Alive $serverPidFile)) {
        $env:WINDOWSBRIDGE_BACKEND_TOKEN_FILE = $backendToken
        $p = Start-Process -FilePath $python -ArgumentList @((Join-Path $release "app\http_runtime.py"),"--port",[string]$route.port) -WindowStyle Hidden -PassThru
        Set-Content $serverPidFile $p.Id -Encoding ASCII
        $env:WINDOWSBRIDGE_BACKEND_TOKEN_FILE = $null
    }

    if (-not (Alive $supervisorPidFile)) {
        $env:WINDOWSBRIDGE_ROOT = $Root
        $p = Start-Process -FilePath $python -ArgumentList @((Join-Path $Root "management\supervisor.py")) -WindowStyle Hidden -PassThru
        Set-Content $supervisorPidFile $p.Id -Encoding ASCII
        $env:WINDOWSBRIDGE_ROOT = $null
    }

    $env:CONTROL_PLANE_TUNNEL_ID = [string]$cfg.tunnel_id
    $args = @(
      "run",
      "--control-plane.api-key","file:$runtimeKey",
      "--mcp.server-url","http://127.0.0.1:18766/mcp",
      "--mcp.extra-headers","X-Bridge-Token: file:$routerToken",
      "--health.listen-addr","127.0.0.1:18765"
    )
    $p = Start-Process -FilePath $tunnel -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $errLog
    Set-Content $tunnelPidFile $p.Id -Encoding ASCII
    $p.WaitForExit()
    exit $p.ExitCode
} finally {
    $env:CONTROL_PLANE_TUNNEL_ID = $null
    $env:WINDOWSBRIDGE_BACKEND_TOKEN_FILE = $null
    $env:WINDOWSBRIDGE_ROOT = $null
    if ($locked) { $mutex.ReleaseMutex() | Out-Null }
    $mutex.Dispose()
}
'@
    Set-Content $Launch $launchContent -Encoding UTF8

    icacls $Root /inheritance:r | Out-Null
    icacls $Root /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    $actionArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $Launch
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $actionArgs
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "WindowsBridge MCP agent for ChatGPT" | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    $ready = $false
    for ($i = 0; $i -lt 45; $i++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing "$HealthBase/readyz" -TimeoutSec 2
            if ($response.StatusCode -eq 200) { $ready = $true; break }
        } catch {}
        Start-Sleep -Seconds 1
    }

    $state = (Get-ScheduledTask -TaskName $TaskName).State
    if (-not $ready) { throw "WindowsBridge started but the OpenAI tunnel did not become ready at $HealthBase/readyz." }
    if ($state -notin @("Running","Ready")) { throw "WindowsBridge startup task is not healthy: $state" }

    Copy-Item (Join-Path $releaseDir "management\update.ps1") $UpdateScript -Force
    Copy-Item (Join-Path $releaseDir "management\supervisor.py") (Join-Path $Management "supervisor.py") -Force
    Copy-Item (Join-Path $releaseDir "management\windowsbridgectl.ps1") $ControlScript -Force
    $controlCmdContent = '@echo off' + [Environment]::NewLine + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SystemRoot%\System32\windowsbridgectl.ps1" %*'
    Set-Content $ControlCmd $controlCmdContent -Encoding ASCII

    if (-not $DisableAutoUpdate) {
        Stop-ScheduledTask -TaskName $AutoUpdateTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $AutoUpdateTaskName -Confirm:$false -ErrorAction SilentlyContinue
        $updateArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $UpdateScript
        $updateAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $updateArgs
        $updateTrigger = New-ScheduledTaskTrigger -Daily -At 3am
        $updatePrincipal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
        $updateSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        Register-ScheduledTask -TaskName $AutoUpdateTaskName -Action $updateAction -Trigger $updateTrigger -Principal $updatePrincipal -Settings $updateSettings -Description "Safely update WindowsBridge from the stable GitHub channel" | Out-Null
    }

    Get-ChildItem $Releases -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[0-9a-f]{40}$' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -Skip 3 |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host ""
    Write-Host "  [READY] WindowsBridge installed from GitHub." -ForegroundColor Green
    Write-Host "Source commit: $ResolvedRef"
    Write-Host "OpenAI tunnel-client: $($tunnelRelease.tag_name)"
    Write-Host "Tunnel readiness: ready"
    Write-Host "Automatic updates: $(if ($DisableAutoUpdate) { 'disabled' } else { 'enabled (stable, daily)' })"
    Write-Host "Control command: windowsbridgectl check"

    if ($NeedsConnectorSetup) {
        if ($UseGraphicalSetup) {
            try {
                Show-GraphicalConnectorSetup $TunnelId
            } catch {
                Write-Host "Graphical completion window unavailable; showing console instructions." -ForegroundColor Yellow
                Show-ConnectorSetup $TunnelId
            }
        } else {
            Show-ConnectorSetup $TunnelId
        }
    } elseif (-not $AutoUpdate) {
        Write-Host ""
        Write-Host "Existing OpenAI tunnel configuration reused; no connector setup is needed." -ForegroundColor Green
    }
} catch {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
    if ($ResolvedRef -and $ResolvedRef -ne $previousRef -and (Test-Path $releaseDir)) {
        Remove-Item $releaseDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($previousRef -and (Test-Path (Join-Path $Releases $previousRef))) {
        Set-Content $Current $previousRef -Encoding ASCII -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    } else {
        Remove-Item $Current -Force -ErrorAction SilentlyContinue
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    throw
} finally {
    $env:CONTROL_PLANE_API_KEY = $null
    $env:CONTROL_PLANE_TUNNEL_ID = $null
    $env:MCP_COMMAND = $null
    $env:UV_PYTHON_INSTALL_DIR = $null
    $env:UV_CACHE_DIR = $null
    $env:UV_PYTHON_NO_REGISTRY = $null
    $env:UV_PYTHON_INSTALL_BIN = $null
    $RuntimeApiKey = $null
    $existing = $null
    [GC]::Collect()
}
