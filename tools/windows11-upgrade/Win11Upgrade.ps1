#requires -Version 5.1
<#
.SYNOPSIS
    Windows 11 Upgrade Manager - safe, interactive Windows feature updates.
.DESCRIPTION
    Finds applicable, OFFICIALLY OFFERED Windows feature upgrades using Windows
    Update Agent (WUA), and optionally upgrades using a user-supplied official ISO.
    Does not disable safeguards, erase data, or install unsupported updates.
.EXAMPLE
    .\Win11Upgrade.ps1
.EXAMPLE
    .\Win11Upgrade.ps1 -DiagnosticOnly
#>
[CmdletBinding()]
param(
    [switch]$DiagnosticOnly,
    [switch]$NoElevate,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AppName = 'Windows 11 Upgrade Manager'
$script:AppVersion = '1.0.0'
$script:OfficialPage = 'https://www.microsoft.com/software-download/windows11'
$script:KnownStable = '26H2'  # Fallback only; actual offered upgrades discovered via WUA.
$script:Settings = [ordered]@{
    AutoReboot = $false
    DynamicUpdate = $true
    QuietIso = $true
}
$script:CachedUpgrades = $null
$script:StableCache = $null
$script:LogFile = $null

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    if (-not $script:LogFile) { return }
    try {
        Add-Content -LiteralPath $script:LogFile -Value ('[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message) -Encoding UTF8 -ErrorAction Stop
    } catch { Write-Verbose ('Log write failed: ' + $_.Exception.Message) }
}
function Say([string]$Message, [string]$Color = 'Gray') {
    Write-Host $Message -ForegroundColor $Color
}
function Banner([string]$Subtitle = '') {
    try { Clear-Host } catch { }
    Say '  __        ___           _                      __ __ ' 'Cyan'
    Say '  \ \      / (_)_ __   __| | _____      _____  / /_/_' 'Cyan'
    Say '   \ \ /\ / /| |  _ \ / _  |/ _ \ \ /\ / / __|/ /_\ ' 'Blue'
    Say '    \ V  V / | | | | | (_| | (_) \ V  V /\__ \ / /  ' 'Blue'
    Say '     \_/\_/  |_|_| |_|\__,_|\___/ \_/\_/ |___/_/   ' 'DarkCyan'
    Say '  -----------------------------------------------------' 'DarkGray'
    Say ('  UPGRADE MANAGER  v{0}  |  OFFICIAL MICROSOFT SOURCES' -f $script:AppVersion) 'White'
    if ($Subtitle) { Say ('  ' + $Subtitle) 'DarkCyan' }
    Say '  -----------------------------------------------------' 'DarkGray'
    Write-Host ''
}
function Pause-UI {
    [void](Read-Host '  Нажми Enter для продолжения')
}
function YesNo([string]$Question, [bool]$Default = $false) {
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $reply = (Read-Host ('  {0} {1}' -f $Question, $suffix)).Trim()
    if (-not $reply) { return $Default }
    return ($reply -match '^(y|yes|д|да)$')
}
function Get-VersionRank([string]$Version) {
    if ($Version -notmatch '^(\d{2})H([12])$') { return -1 }
    return (([int]$Matches[1]) * 10 + [int]$Matches[2])
}
function Get-FeatureVersion([object]$Update) {
    # Strict filtering: monthly cumulative updates also mention "Windows 11 26H2".
    $title = [string]$Update.Title
    $version = [regex]::Match($title, '(?i)\b(\d{2}H[12])\b')
    if (-not $version.Success -or $title -notmatch '(?i)Windows\s*11') { return $null }
    $kb = @($Update.KBArticleIDs) -join ','
    $isFeature = $title -match '(?i)(feature\s+update|upgrade\s+to\s+windows|обновлени\S*\s+компонент|обновлени\S*\s+функци|обновлени\S*\s+до\s+Windows\s*11)' 
    $isDedicatedTitle = $title -match '(?i)^\s*Windows\s*11\s*,?\s*(?:version|версия|версии)\s+\d{2}H[12]\s*$'
    $isKnownPackage = ($kb -match '(^|,)(5121794|5054156)(,|$)')
    if ($isFeature -or $isDedicatedTitle -or $isKnownPackage) { return $version.Groups[1].Value.ToUpperInvariant() }
    return $null
}
function Get-MicrosoftStableVersion {
    if ($script:StableCache) { return $script:StableCache }
    try {
        $r = Invoke-WebRequest -Uri $script:OfficialPage -UseBasicParsing -TimeoutSec 12
        $m = [regex]::Match([string]$r.Content, '(?is)Current\s+release.{0,500}?(?:Version|Версия)\s*(\d{2}H[12])')
        if ($m.Success) { $script:StableCache = $m.Groups[1].Value.ToUpperInvariant(); return $script:StableCache }
    } catch { Write-Log ('Latest version lookup failed: ' + $_.Exception.Message) 'WARN' }
    $script:StableCache = $script:KnownStable
    return $script:StableCache
}
function Get-Device {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive)
    $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $v = [string]$cv.DisplayVersion
    if (-not $v) { $v = 'Unknown' }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $sys = New-Object -ComObject 'Microsoft.Update.SystemInfo'
    $pending = [bool]$sys.RebootRequired
    $bitLocker = 'Unknown'
    try {
        $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $bitLocker = [string]$vol.ProtectionStatus
    } catch { }
    return [pscustomobject]@{
        Version = $v
        Build = [int]$os.BuildNumber
        Edition = [string]$cv.EditionID
        Name = [string]$os.Caption
        FreeGB = [math]::Round(([double]$disk.FreeSpace / 1GB), 1)
        Admin = $isAdmin
        PendingReboot = $pending
        BitLocker = $bitLocker
    }
}
function Show-Device([object]$Device) {
    Say ('  ОС        {0} ({1}, сборка {2})' -f $Device.Name, $Device.Version, $Device.Build) 'White'
    Say ('  Редакция  {0}' -f $Device.Edition) 'Gray'
    Say ('  Диск C:   {0:N1} ГБ свободно' -f $Device.FreeGB) 'Gray'
    Say ('  Админ     {0}' -f $(if($Device.Admin){'да'}else{'нет'})) 'Gray'
    Say ('  Перезапуск ожидается: {0}' -f $(if($Device.PendingReboot){'ДА'}else{'нет'})) $(if($Device.PendingReboot){'Yellow'}else{'Gray'})
    Say ('  BitLocker {0} (сохрани ключ восстановления заранее)' -f $Device.BitLocker) 'Gray'
}
function Test-Preflight([object]$Device, [int]$MinFreeGB = 8) {
    if ($Device.Build -lt 22000 -or $Device.Name -notmatch 'Windows 11') {
        throw 'Для этого менеджера требуется Windows 11. Другие ОС не поддерживаются.'
    }
    if ($Device.PendingReboot) { throw 'Обнаружен незавершённый перезапуск Windows Update. Сначала перезагрузи ПК.' }
    if ($Device.FreeGB -lt $MinFreeGB) { throw ('Недостаточно места: {0:N1} ГБ. Для этого режима нужно минимум {1} ГБ.' -f $Device.FreeGB, $MinFreeGB) }
    try {
        $battery = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
        foreach ($b in $battery) {
            if ($b.EstimatedChargeRemaining -lt 30 -and $b.BatteryStatus -eq 1) {
                throw 'Батарея ниже 30% и не заряжается. Подключи питание.'
            }
        }
    } catch {
        if ($_.Exception.Message -like '*Батарея ниже*') { throw }
    }
}
function Require-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return $true }
    Say '  Для установки обновлений нужны права администратора.' 'Yellow'
    if ($NoElevate) { return $false }
    if (-not (YesNo 'Перезапустить меню с запросом UAC?')) { return $false }
    if (-not $PSCommandPath) { throw 'Неизвестный путь скрипта: запусти сохранённый .ps1 файл.' }
    $safePath = '"' + $PSCommandPath.Replace('"','') + '"'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File ' + $safePath)
    return $false
}
function Find-WindowsUpgrades([switch]$Refresh) {
    if ($null -ne $script:CachedUpgrades -and -not $Refresh) { return @($script:CachedUpgrades) }
    Say '  [~] Запрашиваю доступные обновления у Windows Update...' 'Cyan'
    Write-Log 'Begin WUA Search (read-only)'
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $session.ClientApplicationID = $script:AppName
    $searcher = $session.CreateUpdateSearcher()
    # Respect configured Windows Update/WSUS source and safeguard holds.
    $result = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    $found = @()
    foreach ($u in $result.Updates) {
        $ver = Get-FeatureVersion $u
        if (-not $ver) { continue }
        $found += [pscustomobject]@{ Version = $ver; Title = [string]$u.Title; Update = $u }
    }
    $script:CachedUpgrades = @($found | Sort-Object -Property @{Expression={Get-VersionRank $_.Version}; Descending=$true})
    Write-Log ('WUA offered {0} matching Windows 11 feature update(s)' -f @($script:CachedUpgrades).Count)
    return @($script:CachedUpgrades)
}
function Invoke-WuaUpgrade([object]$Offer, [object]$Device) {
    if (Get-VersionRank $Offer.Version -le (Get-VersionRank $Device.Version)) { throw 'Выбранная версия не новее установленной.' }
    Test-Preflight $Device 8
    if ((Get-VersionRank $Offer.Version) -gt (Get-VersionRank (Get-MicrosoftStableVersion))) {
        throw 'Эта версия новее подтверждённого стабильного выпуска Microsoft. Insider-сборки автоматически не устанавливаются.'
    }
    Banner 'ПОДТВЕРЖДЕНИЕ ОБНОВЛЕНИЯ'
    Say ('  Найдено: {0}' -f $Offer.Title) 'Green'
    Say '  Источник: предложено самой Windows Update' 'Gray'
    Say '  Сохраняются приложения, настройки и личные файлы (штатный upgrade).' 'Gray'
    Say '  Сделай резервную копию важных файлов и сохрани ключ BitLocker.' 'Yellow'
    Say ('  Автоперезапуск: {0}' -f $(if($script:Settings.AutoReboot){'ВКЛ'}else{'ВЫКЛ'})) 'Gray'
    if (-not (YesNo 'Разрешаешь загрузку и установку этого обновления?')) { return }
    if (-not (Require-Admin)) { return }
    Write-Log ('Confirmed WUA install: ' + $Offer.Title)
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $session.ClientApplicationID = $script:AppName
    $collection = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    $u = $Offer.Update
    if (-not $u.EulaAccepted) { $u.AcceptEula() | Out-Null }
    [void]$collection.Add($u)
    if (-not $u.IsDownloaded) {
        Say '  [1/2] Загрузка пакета Microsoft. Это может занять время...' 'Cyan'
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $collection
        $download = $downloader.Download()
        Write-Log ('Download result=' + $download.ResultCode)
        if ($download.ResultCode -ne 2 -and $download.ResultCode -ne 3) {
            throw ('Загрузка не завершена (ResultCode={0}, HRESULT=0x{1:X8})' -f $download.ResultCode, $download.HResult)
        }
        if (-not $u.IsDownloaded) { throw 'Windows Update не подтвердила загрузку пакета.' }
    }
    Say '  [2/2] Установка пакета Windows 11...' 'Cyan'
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $collection
    $res = $installer.Install()
    $resultCode = [int]$res.ResultCode
    Write-Log ('Install ResultCode={0}; RebootRequired={1}; HResult={2}' -f $resultCode, $res.RebootRequired, $res.HResult)
    if ($resultCode -ne 2) { throw ('Установка не подтверждена (ResultCode={0}, HRESULT={1}). Смотри журнал Windows Update.' -f $resultCode, $res.HResult) }
    Say '  [OK] Пакет успешно установлен Windows Update.' 'Green'
    if ($res.RebootRequired) { Complete-Reboot }
    else { Say '  Перезагрузка сейчас не требуется по результату Windows Update.' 'Green' }
}
function Complete-Reboot {
    Say '  Для завершения обновления требуется перезапуск.' 'Yellow'
    if ($script:Settings.AutoReboot) {
        if (YesNo 'Перезагрузить компьютер СЕЙЧАС?') { Restart-Computer }
    } else {
        Say '  Автоперезапуск выключен. Перезагрузи компьютер вручную.' 'Gray'
    }
}
function Get-IsoSetup([string]$Path) {
    $raw = $Path.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $raw)) { throw 'Указанный файл/путь не существует.' }
    $item = Get-Item -LiteralPath $raw
    if ($item.PSIsContainer) {
        $setup = Join-Path $item.FullName 'setup.exe'
        if (-not (Test-Path -LiteralPath $setup)) { throw 'В папке нет setup.exe.' }
        return $setup
    }
    if ($item.Extension -ieq '.iso') {
        $mounted = Mount-DiskImage -ImagePath $item.FullName -PassThru -ErrorAction Stop
        $vol = $mounted | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1
        if (-not $vol) { throw 'ISO подключён, но буква диска не определена.' }
        $setup = ('{0}:\setup.exe' -f $vol.DriveLetter)
        if (-not (Test-Path -LiteralPath $setup)) { throw 'В образе нет setup.exe.' }
        return $setup
    }
    if ($item.Name -ieq 'setup.exe') { return $item.FullName }
    throw 'Нужен оригинальный .iso Windows 11, корневая папка ISO или setup.exe.'
}
function Convert-ExitCode([int]$Number) {
    return ('0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Number),0))
}
function Get-MediaVersion([string]$SetupPath) {
    $source = Join-Path (Split-Path -Parent $SetupPath) 'sources'
    $image = @('install.wim','install.esd') | ForEach-Object { Join-Path $source $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $image) { throw 'Не найден install.wim/install.esd в sources. Используй полноценный официальный ISO.' }
    $info = Get-WindowsImage -ImagePath $image -Index 1 -ErrorAction Stop
    $ver = [string]$info.Version
    $match = [regex]::Match($ver, '^10\.0\.(\d+)')
    if (-not $match.Success) { throw ('Не удалось определить сборку образа: ' + $ver) }
    $build = [int]$match.Groups[1].Value
    $version = switch ($build) { 26100 {'24H2'} 26200 {'25H2'} 26300 {'26H2'} default {$null} }
    return [pscustomobject]@{ Build = $build; Version = $version }
}
function Invoke-IsoUpgrade([object]$Device, [string]$ExpectedVersion = '') {
    Test-Preflight $Device 25
    if (-not (Require-Admin)) { return }
    Banner 'ОБНОВЛЕНИЕ ИЗ ISO MICROSOFT'
    Say '  Используй только официальный ISO Windows 11 для своей архитектуры.' 'Yellow'
    Say '  Язык и редакция должны позволять сохранить приложения и файлы.' 'Gray'
    Say ('  Загрузка ISO: {0}' -f $script:OfficialPage) 'DarkCyan'
    if (YesNo 'Открыть страницу загрузки официального ISO?') { Start-Process $script:OfficialPage }
    $path = Read-Host '  Путь к .iso, папке ISO или setup.exe (пусто = назад)'
    if (-not $path.Trim()) { return }
    $setup = Get-IsoSetup $path
    Say ('  Установщик: {0}' -f $setup) 'White'
    $media = Get-MediaVersion $setup
    Say ('  Версия образа: {0}; сборка {1}' -f $(if($media.Version){$media.Version}else{'не определена'}), $media.Build) 'Cyan'
    if ($ExpectedVersion -and $media.Version -ne $ExpectedVersion) { throw ('Выбранная версия {0}, но ISO содержит {1}. Установка отменена.' -f $ExpectedVersion, $media.Version) }
    if ($media.Build -le $Device.Build) { throw 'ISO не новее текущей сборки Windows. Понижение версии не поддерживается.' }
    if (-not $media.Version -and -not (YesNo 'Версия ISO не распознана. Продолжить с проверкой совместимости Windows Setup?')) { return }
    $sig = Get-AuthenticodeSignature -LiteralPath $setup
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '(?i)Microsoft') {
        throw 'Цифровая подпись setup.exe Microsoft не подтверждена. Остановлено.'
    }
    Say '  [1/2] Проверка совместимости Windows Setup (без установки)...' 'Cyan'
    $args = '/auto upgrade /quiet /compat scanonly /dynamicupdate {0} /eula accept' -f $(if($script:Settings.DynamicUpdate){'enable'}else{'disable'})
    $scan = Start-Process -FilePath $setup -ArgumentList $args -PassThru -Wait
    $code = Convert-ExitCode $scan.ExitCode
    Write-Log ('ISO compatibility scan exit code=' + $code)
    if ($code -ne '0xC1900210') {
        throw ('Проверка совместимости не пройдена: {0}. Нельзя гарантировать сохранение приложений/файлов. Изучи setupact.log / CompatData*.xml.' -f $code)
    }
    Say '  [OK] Совместимость пройдена: сохранение приложений и файлов доступно.' 'Green'
    Say '  Windows Setup подготовит in-place upgrade с сохранением данных.' 'White'
    Say '  Первую перезагрузку намеренно блокируем параметром /NoReboot.' 'Gray'
    Say '  ВАЖНО: создай независимую резервную копию и сохрани ключ BitLocker.' 'Yellow'
    if (-not (YesNo 'Запустить установку из этого ISO?')) { return }
    $actualArgs = '/auto upgrade /dynamicupdate {0} /eula accept /noreboot' -f $(if($script:Settings.DynamicUpdate){'enable'}else{'disable'})
    if ($script:Settings.QuietIso) { $actualArgs += ' /quiet' }
    Write-Log ('ISO upgrade started, args=' + $actualArgs)
    Say '  [2/2] Windows Setup запускается...' 'Cyan'
    $process = Start-Process -FilePath $setup -ArgumentList $actualArgs -PassThru -Wait
    $code = Convert-ExitCode $process.ExitCode
    Write-Log ('ISO Setup result=' + $code)
    if ($process.ExitCode -ne 0) { throw ('Windows Setup вернул {0}; установка не подтверждена. Проверь C:\$WINDOWS.~BT\Sources\Panther.' -f $code) }
    Say '  Windows Setup завершила первый этап без ошибки запуска.' 'Green'
    Say '  Окончательный результат проверяй после перезагрузки через winver.' 'Yellow'
    Complete-Reboot
}
function Show-Settings {
    while ($true) {
        Banner 'НАСТРОЙКИ'
        Say ('  [1] Автоперезапуск (только после подтверждения) : {0}' -f $(if($script:Settings.AutoReboot){'ON'}else{'OFF'})) 'White'
        Say ('  [2] ISO Dynamic Update (драйверы и исправления): {0}' -f $(if($script:Settings.DynamicUpdate){'ON'}else{'OFF'})) 'White'
        Say ('  [3] ISO тихий режим после проверки          : {0}' -f $(if($script:Settings.QuietIso){'ON'}else{'OFF'})) 'White'
        Say '  [0] Назад' 'DarkGray'
        $choice = (Read-Host '  Выбор').Trim()
        switch ($choice) {
            '1' { $script:Settings.AutoReboot = -not $script:Settings.AutoReboot }
            '2' { $script:Settings.DynamicUpdate = -not $script:Settings.DynamicUpdate }
            '3' { $script:Settings.QuietIso = -not $script:Settings.QuietIso }
            '0' { return }
        }
    }
}
function Show-Upgrades([object]$Device) {
    $updates = @(Find-WindowsUpgrades -Refresh)
    Banner 'ВЫБОР ВЕРСИИ WINDOWS 11'
    $stable = Get-MicrosoftStableVersion
    Say ('  Актуальная версия с сайта Microsoft: {0}' -f $stable) 'Cyan'
    Say ('  Текущая версия: {0}' -f $Device.Version) 'White'
    Write-Host ''
    # Show versions even when not currently offered, but install ONLY if WUA offers it.
    $versions = @(@($updates | ForEach-Object { $_.Version }) + @('25H2', $stable) | Select-Object -Unique |
        Where-Object { (Get-VersionRank $_) -gt (Get-VersionRank $Device.Version) -and (Get-VersionRank $_) -le (Get-VersionRank $stable) } |
        Sort-Object -Descending)
    if ($versions.Count -eq 0) { Say '  Ты уже используешь эту версию или более новую.' 'Green' }
    for ($i=0; $i -lt $versions.Count; $i++) {
        $v = $versions[$i]
        $match = @($updates | Where-Object { $_.Version -eq $v } | Select-Object -First 1)
        $state = if ($match.Count) { 'ПРЕДЛОЖЕНО WINDOWS UPDATE' } else { 'НЕ ПРЕДЛОЖЕНО - НУЖЕН ISO' }
        $color = if ($match.Count) { 'Green' } else { 'Yellow' }
        Say ('  [{0}] Windows 11 {1} - {2}' -f ($i+1), $v, $state) $color
    }
    Say '  [I] Официальный ISO без предварительного выбора версии' 'White'
    Say '  [0] Назад' 'DarkGray'
    $choice = (Read-Host '  Выбор').Trim().ToUpperInvariant()
    if ($choice -eq 'I') { Invoke-IsoUpgrade $Device; return }
    if ($choice -eq '0' -or $choice -notmatch '^\d+$') { return }
    $n = [int]$choice
    if ($n -ge 1 -and $n -le $versions.Count) {
        $selected = $versions[$n-1]
        $offer = @($updates | Where-Object { $_.Version -eq $selected } | Select-Object -First 1)
        if ($offer.Count) { Invoke-WuaUpgrade $offer[0] $Device }
        else {
            Say ('  Windows Update не предлагает {0} этому ПК. Не обходим ограничения.' -f $selected) 'Yellow'
            if (YesNo 'У тебя есть официальный ISO этой версии? Перейти к проверке ISO?') { Invoke-IsoUpgrade $Device $selected }
        }
    }
}
function Initialize-Log {
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'Windows11UpgradeManager\Logs'
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $script:LogFile = Join-Path $dir ('upgrade-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Write-Log ('Started ' + $script:AppName + ' ' + $script:AppVersion)
    } catch { $script:LogFile = $null }
}
function Run-Main {
    Initialize-Log
    if ($SelfTest) {
        # Non-invasive smoke test for version detection and update classification.
        if ((Get-VersionRank '26H2') -le (Get-VersionRank '25H2')) { throw 'version ordering test failed' }
        $f = [pscustomobject]@{Title='Feature update to Windows 11, version 26H2'; KBArticleIDs=@('5121794')}
        $c = [pscustomobject]@{Title='2026-10 Cumulative Update for Windows 11 Version 26H2'; KBArticleIDs=@('5127648')}
        $r = [pscustomobject]@{Title='Обновление компонентов до Windows 11, версия 26H2'; KBArticleIDs=@('5121794')}
        if ((Get-FeatureVersion $f) -ne '26H2' -or $null -ne (Get-FeatureVersion $c) -or (Get-FeatureVersion $r) -ne '26H2') {
            throw 'feature update classifier test failed'
        }
        Say '[PASS] Offline self-tests OK.' 'Green'
        return
    }
    if ($env:OS -ne 'Windows_NT') { throw 'Windows 11 required.' }
    $device = Get-Device
    if ($DiagnosticOnly) {
        Banner 'ДИАГНОСТИКА (БЕЗ ИЗМЕНЕНИЙ)'
        Show-Device $device
        try { Test-Preflight $device 8; Say '  [OK] Базовые проверки пройдены.' 'Green' }
        catch { Say ('  [!] ' + $_.Exception.Message) 'Yellow' }
        Say ('  Log: {0}' -f $script:LogFile) 'DarkGray'
        return
    }
    if (-not $device.Admin -and -not $NoElevate) {
        Banner 'ЗАПРОС ПРАВ АДМИНИСТРАТОРА'
        Say '  Для полноценной установки понадобится подтверждение Windows UAC.' 'Yellow'
        if (YesNo 'Открыть Upgrade Manager с правами администратора?') {
            if (-not $PSCommandPath) { throw 'Неизвестный путь текущего скрипта.' }
            $safePath = '"' + $PSCommandPath.Replace('"','') + '"'
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File ' + $safePath)
            return
        }
    }
    while ($true) {
        Banner 'ОФИЦИАЛЬНЫЕ ИСТОЧНИКИ | БЕЗ ОБХОДА ПРОВЕРОК'
        Show-Device $device
        Write-Host ''
        Say '  [1] Быстро: последняя предложенная версия (Windows Update)' 'Green'
        Say '  [2] Выбрать версию из доступных (Windows Update)' 'White'
        Say '  [3] Обновиться с официального ISO' 'White'
        Say '  [4] Настройки установки и перезапуска' 'White'
        Say '  [5] Проверить совместимость / диагностика' 'White'
        Say '  [6] Открыть официальную страницу Windows 11' 'White'
        Say '  [0] Выход' 'DarkGray'
        Write-Host ''
        $choice = (Read-Host '  Выбери действие').Trim()
        try {
            switch ($choice) {
                '1' {
                    $updates = @(Find-WindowsUpgrades -Refresh)
                    $stable = Get-MicrosoftStableVersion
                    $candidate = @($updates | Where-Object { (Get-VersionRank $_.Version) -gt (Get-VersionRank $device.Version) -and (Get-VersionRank $_.Version) -le (Get-VersionRank $stable) } | Select-Object -First 1)
                    if ($candidate.Count) { Invoke-WuaUpgrade $candidate[0] $device }
                    else { Say '  Для этого устройства Windows Update не предлагает более новую версию.' 'Yellow' }
                    Pause-UI
                }
                '2' { Show-Upgrades $device; Pause-UI }
                '3' { Invoke-IsoUpgrade $device; Pause-UI }
                '4' { Show-Settings }
                '5' {
                    Banner 'ДИАГНОСТИКА'
                    Show-Device $device
                    Test-Preflight $device 8
                    Say '  [OK] Базовая совместимость: пройдена.' 'Green'
                    Say ('  Последняя официальная версия: {0}' -f (Get-MicrosoftStableVersion)) 'Cyan'
                    Pause-UI
                }
                '6' { Start-Process $script:OfficialPage }
                '0' { return }
                default { Say '  Выбери пункт меню.' 'Yellow'; Start-Sleep -Milliseconds 650 }
            }
        } catch {
            $msg = $_.Exception.Message
            Write-Log $msg 'ERROR'
            Say ('  [ОШИБКА] ' + $msg) 'Red'
            Say ('  Журнал: {0}' -f $script:LogFile) 'DarkGray'
            Pause-UI
        }
        # Device state can change externally (e.g. user applies updates in Settings).
        if ($choice -eq '5') { try { $device = Get-Device } catch { } }
    }
}
try { Run-Main }
catch {
    Write-Log $_.Exception.ToString() 'FATAL'
    Say ('[FATAL] ' + $_.Exception.Message) 'Red'
    exit 1
}