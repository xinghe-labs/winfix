param(
  [ValidateSet('overview', 'health', 'baseline', 'compare', 'disk', 'memory', 'dev', 'network', 'net-test', 'app', 'chrome', 'vscode', 'wechat', 'android', 'wsl', 'docker', 'large', 'system', 'events', 'startup', 'services', 'drivers', 'updates', 'devices', 'power', 'audio', 'display', 'printer', 'security', 'repair-check', 'issue', 'cleanup-temp')]
  [string]$Mode = 'overview',
  [int]$Top = 15,
  [string]$Issue = '',
  [string]$Target = '',
  [string]$ProcessName = '',
  [string]$BaselinePath = '',
  [switch]$Apply,
  [ValidateSet('text', 'json')]
  [string]$Format = 'text'
)

$WinfixVersion = '0.2.1'
$ErrorActionPreference = 'SilentlyContinue'
$MaxFilesPerFolder = 20000

function Join-Local([string]$Base, [string]$Child) {
  if ([string]::IsNullOrWhiteSpace($Base)) { return $null }
  return (Join-Path $Base $Child)
}

function Format-Bytes([double]$Bytes) {
  if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
  if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
  return "$Bytes B"
}

function Redact-SensitiveText([object]$Value) {
  if ($null -eq $Value) { return $null }
  $text = [string]$Value
  $text = $text -replace '([a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s:@]+:[^@\s/]+@', '$1***:***@'
  $text = $text -replace '(?i)(password|passwd|pwd|token|apikey|api_key|secret)=([^&\s]+)', '$1=***'
  return $text
}

function Test-SafeTempRoot([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
  if (-not $resolved) { return $false }
  $full = [System.IO.Path]::GetFullPath($resolved.Path).TrimEnd('\')
  $allowed = @(
    [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Temp')).TrimEnd('\'),
    [System.IO.Path]::GetFullPath('C:\Windows\Temp').TrimEnd('\')
  ) | Sort-Object -Unique
  return ($allowed -contains $full)
}

function Get-FolderSize([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{ Path = $Path; Exists = $false; Bytes = 0; Size = 'missing' }
  }
  $files = Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue |
    Select-Object -First $MaxFilesPerFolder
  $sum = ($files | Measure-Object -Property Length -Sum).Sum
  if ($null -eq $sum) { $sum = 0 }
  $note = if (($files | Measure-Object).Count -ge $MaxFilesPerFolder) { 'sampled' } else { 'full' }
  return [pscustomobject]@{ Path = $Path; Exists = $true; Bytes = [int64]$sum; Size = (Format-Bytes $sum); Scan = $note }
}

function Get-ChildFolderSizes([string]$Path, [int]$Limit = 15) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{ Path = $Path; Exists = $false; Bytes = 0; Size = 'missing' }
  }
  Get-ChildItem -LiteralPath $Path -Force -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Get-FolderSize $_.FullName } |
    Sort-Object Bytes -Descending |
    Select-Object -First $Limit
}

function Show-Drives {
  Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
    Select-Object DeviceID,
      @{Name='Size';Expression={Format-Bytes $_.Size}},
      @{Name='Free';Expression={Format-Bytes $_.FreeSpace}},
      @{Name='FreePercent';Expression={[math]::Round(($_.FreeSpace / $_.Size) * 100, 1)}}
}

function Get-DriveData {
  Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
    ForEach-Object {
      [pscustomobject]@{
        device = $_.DeviceID
        size_bytes = [int64]$_.Size
        free_bytes = [int64]$_.FreeSpace
        free_percent = [math]::Round(($_.FreeSpace / $_.Size) * 100, 1)
        status = if (($_.FreeSpace / $_.Size) -lt 0.10) { 'low' } elseif (($_.FreeSpace / $_.Size) -lt 0.20) { 'watch' } else { 'ok' }
      }
    }
}

function Get-MemoryData {
  $os = Get-CimInstance Win32_OperatingSystem
  $total = [double]$os.TotalVisibleMemorySize * 1KB
  $free = [double]$os.FreePhysicalMemory * 1KB
  [pscustomobject]@{
    total_bytes = [int64]$total
    free_bytes = [int64]$free
    used_percent = if ($total -gt 0) { [math]::Round((1 - ($free / $total)) * 100, 1) } else { $null }
  }
}

function Get-TopProcessData {
  Get-Process |
    Sort-Object WorkingSet64 -Descending |
    Select-Object -First $Top |
    ForEach-Object {
      [pscustomobject]@{
        name = $_.ProcessName
        id = $_.Id
        memory_bytes = [int64]$_.WorkingSet64
        cpu = [math]::Round($_.CPU, 1)
      }
    }
}

function Get-DiskCandidateData {
  Show-DiskCandidates | ForEach-Object {
    [pscustomobject]@{
      path = $_.Path
      exists = $_.Exists
      bytes = [int64]$_.Bytes
      size = $_.Size
      scan = $_.Scan
      risk = if ($_.Path -match 'Temp|Cache|Code Cache|GPUCache|npm-cache|pip\\Cache|pnpm\\store') { 'low' } else { 'medium' }
    }
  }
}

function Get-HealthData {
  $score = Get-HealthScore
  $os = Get-CimInstance Win32_OperatingSystem
  $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1,2; StartTime = (Get-Date).AddDays(-3) } -MaxEvents 20)
  $problemDevices = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
  $defender = Get-MpComputerStatus
  $memory = Get-MemoryData
  $drives = @(Get-DriveData)
  [pscustomobject]@{
    mode = 'health'
    version = $WinfixVersion
    generated_at = (Get-Date).ToString('s')
    score = $score
    summary = [pscustomobject]@{
      computer = $env:COMPUTERNAME
      uptime_days = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2)
      memory_used_percent = $memory.used_percent
      critical_or_error_events_last_3_days = $events.Count
      problem_devices = $problemDevices.Count
      defender_realtime = $defender.RealTimeProtectionEnabled
      drive_status = @($drives | Select-Object device, free_percent, status)
    }
    findings = @(
      if (($drives | Where-Object { $_.status -ne 'ok' }).Count -gt 0) { 'One or more drives are low or should be watched.' }
      if ($memory.used_percent -ge 80) { 'Memory usage is high.' }
      if ($events.Count -gt 0) { 'Recent critical/error system events exist.' }
      if ($problemDevices.Count -gt 0) { 'Windows reports problem devices.' }
      if ($defender.RealTimeProtectionEnabled -eq $false) { 'Defender real-time protection is off.' }
      if ($score.pending_reboot) { 'A reboot is pending; some fixes stay incomplete until then.' }
    )
    recommended_actions = @(
      'Use the route matching the strongest finding: disk, memory, events, devices, or security.'
      'Do not run repair commands before reviewing evidence and impact.'
    )
  }
}

function Get-PendingReboot {
  $keys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
  )
  foreach ($key in $keys) { if (Test-Path $key) { return $true } }
  $renames = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
  if ($renames -and @($renames.PendingFileRenameOperations).Count -gt 0) { return $true }
  return $false
}

function Get-BootDurations {
  # Boot duration comes from the Diagnostics-Performance log, which some
  # systems do not have; callers must treat $null as "component unavailable".
  # Event 100 carries duration fields as raw numeric properties; the largest
  # plausible millisecond value is the total boot time (main path + post boot).
  $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 3 -ErrorAction SilentlyContinue)
  if (-not $events) { return $null }
  $out = @()
  foreach ($event in $events) {
    $candidates = @($event.Properties |
      Where-Object { $_.Value -is [int] -or $_.Value -is [long] } |
      ForEach-Object { [long]$_.Value } |
      Where-Object { $_ -ge 1000 -and $_ -le 3600000 })
    if ($candidates.Count -gt 0) {
      $out += [pscustomobject]@{ boot_at = $event.TimeCreated.ToString('s'); total_ms = ($candidates | Measure-Object -Maximum).Maximum }
    }
  }
  if ($out.Count -eq 0) { return $null }
  return $out
}

function Get-StartupInventory {
  # Baselines intentionally store identity (name + location) only.  Full
  # command lines can embed API keys and tokens; they must not be persisted.
  Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue |
    Select-Object name, location
}

function Get-HealthScore {
  $drives = @(Get-DriveData)
  $memory = Get-MemoryData
  $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1,2; StartTime = (Get-Date).AddDays(-3) } -MaxEvents 50)
  $problemDevices = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
  $boot = Get-BootDurations
  $startupCount = @(Get-StartupInventory).Count
  $lastHotfix = Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1
  $updateAgeDays = if ($lastHotfix -and $lastHotfix.InstalledOn) { [int][math]::Round(((Get-Date) - $lastHotfix.InstalledOn).TotalDays) } else { $null }
  $pending = Get-PendingReboot

  $components = @()
  if ($drives.Count -gt 0) {
    $minFree = ($drives | Measure-Object -Property free_percent -Minimum).Minimum
    $s = if ($minFree -ge 25) { 100 } elseif ($minFree -le 5) { 0 } else { [math]::Round((($minFree - 5) / 20) * 100) }
    $components += [pscustomobject]@{ key = 'disk'; weight = 30; score = [int]$s; measured = "min drive free ${minFree}%" }
  }
  if ($null -ne $memory.used_percent) {
    $u = [double]$memory.used_percent
    $s = if ($u -le 60) { 100 } elseif ($u -ge 95) { 0 } else { [math]::Round(((95 - $u) / 35) * 100) }
    $components += [pscustomobject]@{ key = 'memory'; weight = 25; score = [int]$s; measured = "memory used ${u}%" }
  }
  $components += [pscustomobject]@{
    key = 'stability'; weight = 15; score = [int][math]::Max(0, 100 - $events.Count * 8 - $problemDevices.Count * 10)
    measured = "$($events.Count) critical/error events in 3d; $($problemDevices.Count) problem devices"
  }
  if ($boot) {
    $avgS = [math]::Round((($boot | Measure-Object -Property total_ms -Average).Average) / 1000)
    $s = if ($avgS -le 30) { 100 } elseif ($avgS -ge 180) { 0 } else { [math]::Round(((180 - $avgS) / 150) * 100) }
    $components += [pscustomobject]@{ key = 'boot'; weight = 15; score = [int]$s; measured = "avg boot ${avgS}s over last $($boot.Count) boots" }
  }
  $s = if ($startupCount -le 8) { 100 } elseif ($startupCount -ge 28) { 0 } else { [math]::Round(((28 - $startupCount) / 20) * 100) }
  $components += [pscustomobject]@{ key = 'startup'; weight = 10; score = [int]$s; measured = "$startupCount startup items" }
  if ($null -ne $updateAgeDays) {
    $s = if ($updateAgeDays -le 30) { 100 } elseif ($updateAgeDays -ge 120) { 0 } else { [math]::Round(((120 - $updateAgeDays) / 90) * 100) }
    $components += [pscustomobject]@{ key = 'updates'; weight = 5; score = [int]$s; measured = "last hotfix ${updateAgeDays} days ago" }
  }

  $totalWeight = ($components | Measure-Object -Property weight -Sum).Sum
  $total = if ($totalWeight -gt 0) { [math]::Round((($components | ForEach-Object { $_.weight * $_.score } | Measure-Object -Sum).Sum) / $totalWeight) } else { $null }
  if ($pending -and ($null -ne $total)) { $total = [math]::Max(0, $total - 10) }
  [pscustomobject]@{
    total = $total
    pending_reboot = $pending
    components = @($components)
    note = 'Heuristic score from live measurements; unavailable components are excluded and the remaining weights renormalized. Not a benchmark.'
  }
}

function Get-WinfixStateDir {
  $dir = Join-Path $env:USERPROFILE '.winfix\baselines'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $dir
}

function Get-BaselineData {
  [pscustomobject]@{
    kind = 'winfix-baseline'
    version = 1
    created_at = (Get-Date).ToString('s')
    computer = $env:COMPUTERNAME
    drives = @(Get-DriveData)
    memory = Get-MemoryData
    startup = @(Get-StartupInventory)
    auto_stopped_services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
      Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' } |
      Select-Object -ExpandProperty Name | Sort-Object)
    pending_reboot = Get-PendingReboot
    last_boot = ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToString('s')
  }
}

function Save-Baseline {
  $data = Get-BaselineData
  $dir = Get-WinfixStateDir
  $path = Join-Path $dir ("baseline-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + ".json")
  $data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
  $all = @(Get-ChildItem $dir -Filter 'baseline-*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  if ($all.Count -gt 20) { $all | Select-Object -Skip 20 | Remove-Item -Force -ErrorAction SilentlyContinue }
  [pscustomobject]@{
    saved_path = $path
    created_at = $data.created_at
    summary = [pscustomobject]@{
      drives = @($data.drives | Select-Object device, free_percent, status)
      startup_items = @($data.startup).Count
      auto_stopped_services = @($data.auto_stopped_services).Count
      pending_reboot = $data.pending_reboot
    }
  }
}

function Compare-WithBaseline([string]$Path) {
  $dir = Get-WinfixStateDir
  if ($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $baselineFile = $Path
  } else {
    $files = @(Get-ChildItem $dir -Filter 'baseline-*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($files.Count -eq 0) { return $null }
    $baselineFile = $files[0].FullName
  }
  $base = Get-Content -LiteralPath $baselineFile -Raw | ConvertFrom-Json
  $now = Get-BaselineData

  $driveDeltas = @(
    foreach ($d in $now.drives) {
      $b = $base.drives | Where-Object { $_.device -eq $d.device }
      if ($b) {
        [pscustomobject]@{
          device = $d.device
          free_before_bytes = [int64]$b.free_bytes
          free_now_bytes = [int64]$d.free_bytes
          delta_bytes = ([int64]$d.free_bytes - [int64]$b.free_bytes)
        }
      }
    }
  )
  $baseIds = @($base.startup | ForEach-Object { "$($_.location)|$($_.name)" })
  $nowIds = @($now.startup | ForEach-Object { "$($_.location)|$($_.name)" })
  $added = @($nowIds | Where-Object { $baseIds -notcontains $_ })
  $removed = @($baseIds | Where-Object { $nowIds -notcontains $_ })

  [pscustomobject]@{
    baseline_path = $baselineFile
    baseline_at = $base.created_at
    now_at = $now.created_at
    drive_deltas = $driveDeltas
    startup_added = $added
    startup_removed = $removed
    auto_stopped_services_before = @($base.auto_stopped_services).Count
    auto_stopped_services_now = @($now.auto_stopped_services).Count
    pending_reboot = $now.pending_reboot
  }
}

function Write-JsonPayload([object]$Payload) {
  $Payload | ConvertTo-Json -Depth 8
}

function Show-Health {
  $score = Get-HealthScore
  '=== Health score ==='
  [pscustomobject]@{ Version = $WinfixVersion; Score = $score.total; PendingReboot = $score.pending_reboot } | Format-List
  $score.components | ForEach-Object {
    [pscustomobject]@{ Component = $_.key; Score = $_.score; Weight = $_.weight; Measured = $_.measured }
  } | Format-Table -AutoSize
  $worst = $score.components | Sort-Object score | Select-Object -First 1
  if ($worst) { "Weakest component: $($worst.key) ($($worst.measured))" }

  '=== Health summary ==='
  $drives = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3'
  $os = Get-CimInstance Win32_OperatingSystem
  $memTotal = [double]$os.TotalVisibleMemorySize * 1KB
  $memFree = [double]$os.FreePhysicalMemory * 1KB
  $memUsedPct = if ($memTotal -gt 0) { [math]::Round((1 - ($memFree / $memTotal)) * 100, 1) } else { $null }
  $criticalEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1,2; StartTime = (Get-Date).AddDays(-3) } -MaxEvents 20)
  $problemDevices = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
  $defender = Get-MpComputerStatus

  [pscustomobject]@{
    Computer = $env:COMPUTERNAME
    UptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2)
    MemoryUsedPercent = $memUsedPct
    CriticalOrErrorEventsLast3Days = $criticalEvents.Count
    ProblemDevices = $problemDevices.Count
    DefenderRealtime = $defender.RealTimeProtectionEnabled
  } | Format-List

  '=== Drive pressure ==='
  $drives |
    Select-Object DeviceID,
      @{Name='Free';Expression={Format-Bytes $_.FreeSpace}},
      @{Name='FreePercent';Expression={[math]::Round(($_.FreeSpace / $_.Size) * 100, 1)}},
      @{Name='Status';Expression={ if (($_.FreeSpace / $_.Size) -lt 0.10) { 'low' } elseif (($_.FreeSpace / $_.Size) -lt 0.20) { 'watch' } else { 'ok' } }} |
    Format-Table -AutoSize

  '=== Top memory processes ==='
  Show-Memory | Select-Object -First 8 | Format-Table -AutoSize
}

function Show-DiskCandidates {
  $paths = @(
    $env:TEMP,
    'C:\Windows\Temp',
    (Join-Local $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache'),
    (Join-Local $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Cache'),
    (Join-Local $env:APPDATA 'Code\Cache'),
    (Join-Local $env:APPDATA 'Code\CachedData'),
    (Join-Local $env:APPDATA 'Code\Code Cache'),
    (Join-Local $env:APPDATA 'npm-cache'),
    (Join-Local $env:LOCALAPPDATA 'pip\Cache'),
    (Join-Local $env:LOCALAPPDATA 'pnpm\store'),
    (Join-Local $env:USERPROFILE '.gradle\caches'),
    (Join-Local $env:USERPROFILE '.m2\repository'),
    (Join-Local $env:USERPROFILE '.android\avd'),
    (Join-Local $env:LOCALAPPDATA 'Docker'),
    (Join-Local $env:LOCALAPPDATA 'Temp')
  ) | Where-Object { $_ } | Sort-Object -Unique

  $paths | ForEach-Object { Get-FolderSize $_ } | Sort-Object Bytes -Descending | Select-Object -First $Top
}

function Show-Memory {
  Get-Process |
    Sort-Object WorkingSet64 -Descending |
    Select-Object -First $Top ProcessName, Id,
      @{Name='Memory';Expression={Format-Bytes $_.WorkingSet64}},
      @{Name='CPU';Expression={[math]::Round($_.CPU, 1)}}
}

function Show-System {
  '=== Computer ==='
  Get-ComputerInfo |
    Select-Object CsName, WindowsProductName, WindowsVersion, OsBuildNumber, OsArchitecture,
      CsManufacturer, CsModel, CsProcessors, CsTotalPhysicalMemory |
    Format-List
  '=== BIOS ==='
  Get-CimInstance Win32_BIOS | Select-Object Manufacturer, SMBIOSBIOSVersion, ReleaseDate | Format-List
  '=== Uptime ==='
  $os = Get-CimInstance Win32_OperatingSystem
  [pscustomobject]@{
    LastBoot = $os.LastBootUpTime
    UptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2)
  } | Format-List
}

function Show-Events {
  '=== Recent critical/error system events ==='
  Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1,2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 30 |
    Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message |
    Format-List
}

function Show-Startup {
  '=== Startup commands ==='
  Get-CimInstance Win32_StartupCommand |
    Select-Object Name, Command, Location, User |
    Sort-Object Name |
    Format-List
}

function Show-Services {
  '=== Non-running automatic services ==='
  Get-CimInstance Win32_Service |
    Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' } |
    Select-Object Name, DisplayName, State, StartMode, StartName |
    Sort-Object Name |
    Format-Table -AutoSize
}

function Show-Drivers {
  '=== Problem devices ==='
  Get-CimInstance Win32_PnPEntity |
    Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
    Select-Object Name, Manufacturer, PNPDeviceID, ConfigManagerErrorCode |
    Format-List
  '=== Signed drivers sample ==='
  Get-CimInstance Win32_PnPSignedDriver |
    Sort-Object DriverDate -Descending |
    Select-Object -First $Top DeviceName, Manufacturer, DriverVersion, DriverDate |
    Format-Table -AutoSize
}

function Show-Updates {
  '=== Recent hotfixes ==='
  Get-HotFix |
    Sort-Object InstalledOn -Descending |
    Select-Object -First $Top HotFixID, Description, InstalledOn, InstalledBy |
    Format-Table -AutoSize
  '=== Windows Update services ==='
  Get-Service -Name wuauserv,bits,cryptsvc,msiserver |
    Select-Object Name, Status, StartType |
    Format-Table -AutoSize
}

function Show-Devices {
  '=== Problem devices ==='
  Get-CimInstance Win32_PnPEntity |
    Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
    Select-Object Name, Manufacturer, Service, ConfigManagerErrorCode |
    Format-Table -AutoSize
  '=== USB devices ==='
  Get-CimInstance Win32_PnPEntity |
    Where-Object { $_.PNPDeviceID -like 'USB*' } |
    Select-Object -First $Top Name, Status, Manufacturer |
    Format-Table -AutoSize
}

function Show-Power {
  '=== Battery ==='
  Get-CimInstance Win32_Battery | Select-Object Name, BatteryStatus, EstimatedChargeRemaining, EstimatedRunTime | Format-List
  '=== Power plan ==='
  powercfg /getactivescheme 2>&1
  '=== Sleep states ==='
  powercfg /a 2>&1
}

function Show-Audio {
  '=== Audio devices ==='
  Get-CimInstance Win32_SoundDevice | Select-Object Name, Manufacturer, Status | Format-Table -AutoSize
  '=== Audio services ==='
  Get-Service -Name Audiosrv,AudioEndpointBuilder | Select-Object Name, Status, StartType | Format-Table -AutoSize
}

function Show-Display {
  '=== Video controller ==='
  Get-CimInstance Win32_VideoController |
    Select-Object Name, DriverVersion, AdapterRAM, VideoModeDescription |
    Format-List
  '=== Monitors ==='
  Get-CimInstance Win32_DesktopMonitor | Select-Object Name, ScreenWidth, ScreenHeight, Status | Format-Table -AutoSize
}

function Show-Printer {
  '=== Printers ==='
  Get-Printer | Select-Object Name, PrinterStatus, Default, DriverName, PortName | Format-Table -AutoSize
  '=== Print spooler ==='
  Get-Service Spooler | Select-Object Name, Status, StartType | Format-Table -AutoSize
}

function Show-Security {
  '=== Defender status ==='
  Get-MpComputerStatus |
    Select-Object AMServiceEnabled, AntivirusEnabled, RealTimeProtectionEnabled, AntispywareEnabled,
      QuickScanAge, FullScanAge, NISEnabled |
    Format-List
  '=== Firewall profiles ==='
  Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction | Format-Table -AutoSize
}

function Show-RepairCheck {
  '=== Repair check commands (read-only unless user approves repair) ==='
  'Run in elevated PowerShell for deeper checks:'
  'sfc /verifyonly'
  'DISM /Online /Cleanup-Image /CheckHealth'
  'DISM /Online /Cleanup-Image /ScanHealth'
  'Use /RestoreHealth only after explaining that it modifies component store state.'
}

function Show-ProcessGroup([string]$Pattern) {
  Get-Process |
    Where-Object { $_.ProcessName -match $Pattern } |
    Sort-Object WorkingSet64 -Descending |
    Select-Object ProcessName, Id,
      @{Name='Memory';Expression={Format-Bytes $_.WorkingSet64}},
      @{Name='CPU';Expression={[math]::Round($_.CPU, 1)}},
      Path
}

function Show-Chrome {
  '=== Chrome/Edge processes ==='
  Show-ProcessGroup 'chrome|msedge' | Format-Table -AutoSize
  '=== Chrome/Edge cache candidates ==='
  @(
    (Join-Local $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache'),
    (Join-Local $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Code Cache'),
    (Join-Local $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\GPUCache'),
    (Join-Local $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Cache'),
    (Join-Local $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Code Cache'),
    (Join-Local $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\GPUCache')
  ) | ForEach-Object { Get-FolderSize $_ } | Sort-Object Bytes -Descending | Format-Table -AutoSize
}

function Show-VSCode {
  '=== VS Code processes ==='
  Show-ProcessGroup 'Code' | Format-Table -AutoSize
  '=== VS Code cache and extension candidates ==='
  @(
    (Join-Local $env:APPDATA 'Code\Service Worker'),
    (Join-Local $env:APPDATA 'Code\Cache'),
    (Join-Local $env:APPDATA 'Code\CachedData'),
    (Join-Local $env:APPDATA 'Code\Code Cache'),
    (Join-Local $env:APPDATA 'Code\GPUCache'),
    (Join-Local $env:USERPROFILE '.vscode\extensions')
  ) | ForEach-Object { Get-FolderSize $_ } | Sort-Object Bytes -Descending | Format-Table -AutoSize

  $ext = Join-Local $env:USERPROFILE '.vscode\extensions'
  if (Test-Path -LiteralPath $ext) {
    '=== Largest VS Code extension folders ==='
    Get-ChildFolderSizes $ext $Top | Format-Table -AutoSize
  }
}

function Invoke-Tool([string]$Label, [string]$Exe, [string[]]$Args) {
  try {
    $out = & $Exe @Args 2>&1 | Select-Object -First 2
  } catch {
    $out = $_.Exception.Message
  }
  [pscustomobject]@{ Command = $Label; Output = ($out -join ' ') }
}

function Show-DevTools {
  Invoke-Tool 'node --version' 'node' @('--version')
  Invoke-Tool 'npm --version' 'npm' @('--version')
  Invoke-Tool 'python --version' 'python' @('--version')
  Invoke-Tool 'pip --version' 'pip' @('--version')
  Invoke-Tool 'git --version' 'git' @('--version')
  Invoke-Tool 'java -version' 'java' @('-version')
  Invoke-Tool 'adb version' 'adb' @('version')
  Invoke-Tool 'flutter --version' 'flutter' @('--version')
  Invoke-Tool 'docker --version' 'docker' @('--version')
  [pscustomobject]@{ Command = 'ANDROID_HOME'; Output = $env:ANDROID_HOME }
  [pscustomobject]@{ Command = 'ANDROID_SDK_ROOT'; Output = $env:ANDROID_SDK_ROOT }
}

function Show-Android {
  Show-DevTools | Where-Object { $_.Command -match 'java|adb|flutter|ANDROID' } | Format-List
  '=== Android disk candidates ==='
  @(
    $env:ANDROID_HOME,
    $env:ANDROID_SDK_ROOT,
    (Join-Local $env:USERPROFILE '.android\avd'),
    (Join-Local $env:LOCALAPPDATA 'Android\Sdk')
  ) | Where-Object { $_ } | Sort-Object -Unique | ForEach-Object { Get-FolderSize $_ } |
    Sort-Object Bytes -Descending | Format-Table -AutoSize
}

function Show-Network {
  [pscustomobject]@{ Item = 'HTTP_PROXY'; Value = (Redact-SensitiveText $env:HTTP_PROXY) }
  [pscustomobject]@{ Item = 'HTTPS_PROXY'; Value = (Redact-SensitiveText $env:HTTPS_PROXY) }
  [pscustomobject]@{ Item = 'ALL_PROXY'; Value = (Redact-SensitiveText $env:ALL_PROXY) }
  netsh winhttp show proxy | ForEach-Object { Redact-SensitiveText $_ }
}

function Test-NetworkTarget([string]$TargetValue) {
  if ([string]::IsNullOrWhiteSpace($TargetValue)) {
    $TargetValue = 'https://www.microsoft.com'
  }
  '=== Proxy state ==='
  Show-Network
  '=== DNS and HTTP test ==='
  try {
    $uri = [Uri]$TargetValue
  } catch {
    $uri = [Uri]("https://" + $TargetValue)
  }
  $hostName = $uri.Host
  "Target: $(Redact-SensitiveText $uri.AbsoluteUri)"
  Resolve-DnsName $hostName -ErrorAction SilentlyContinue | Select-Object -First 3 Name, Type, IPAddress | Format-Table -AutoSize
  curl.exe -I --connect-timeout 10 --max-time 20 $uri.AbsoluteUri 2>&1 | Select-Object -First 20
}

function Show-WeChat {
  '=== WeChat candidate folders ==='
  @(
    (Join-Local $env:USERPROFILE 'Documents\WeChat Files'),
    (Join-Local $env:USERPROFILE 'Documents\xwechat_files'),
    (Join-Local $env:APPDATA 'Tencent\WeChat'),
    (Join-Local $env:APPDATA 'Tencent\WeChatApp')
  ) | ForEach-Object { Get-FolderSize $_ } | Sort-Object Bytes -Descending | Format-Table -AutoSize
}

function Show-App([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name)) {
    'ProcessName is required for -Mode app. Example: -Mode app -ProcessName chrome'
    return
  }
  $safeName = [regex]::Escape($Name)
  '=== Matching processes ==='
  Show-ProcessGroup $safeName | Format-Table -AutoSize
  '=== Recent application errors ==='
  Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1,2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 50 |
    Where-Object { $_.ProviderName -match $safeName -or $_.Message -match $safeName } |
    Select-Object -First 15 TimeCreated, ProviderName, Id, LevelDisplayName, Message |
    Format-List
}

function Invoke-WslOutput([string[]]$WslArgs) {
  # wsl.exe writes UTF-16LE regardless of the console codepage, which garbles
  # when PowerShell decodes it with a non-Unicode encoding (e.g. cp936).
  # Redirect raw bytes to files and decode as UTF-16 explicitly.
  $stdoutPath = [System.IO.Path]::GetTempFileName()
  $stderrPath = [System.IO.Path]::GetTempFileName()
  try {
    $null = Start-Process -FilePath 'wsl.exe' -ArgumentList $WslArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction SilentlyContinue
    $out = [System.IO.File]::ReadAllText($stdoutPath, [System.Text.Encoding]::Unicode)
    $err = [System.IO.File]::ReadAllText($stderrPath, [System.Text.Encoding]::Unicode)
    $text = ($out.Trim() + ' ' + $err.Trim()).Trim()
    if ($text) { $text } else { 'wsl.exe returned no output.' }
  } catch {
    'wsl.exe is not available.'
  } finally {
    Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

function Show-WSL {
  '=== WSL status ==='
  Invoke-WslOutput @('--status')
  '=== WSL distros ==='
  Invoke-WslOutput @('-l', '-v')
  '=== WSL vhdx virtual disks ==='
  $vhdx = @()
  $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
  if (Test-Path $packagesRoot) {
    Get-ChildItem $packagesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $candidate = Join-Path $_.FullName 'LocalState\ext4.vhdx'
      if (Test-Path $candidate) { $vhdx += (Get-Item $candidate) }
    }
  }
  @(
    (Join-Path $env:LOCALAPPDATA 'Docker\wsl\data\ext4.vhdx'),
    (Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx'),
    (Join-Path $env:LOCALAPPDATA 'DockerDesktopWSL\data\ext4.vhdx'),
    (Join-Path $env:LOCALAPPDATA 'DockerDesktopWSL\disk\docker_data.vhdx')
  ) | Where-Object { $_ -and (Test-Path $_) } | ForEach-Object { $vhdx += (Get-Item $_) }
  if ($vhdx.Count -gt 0) {
    $vhdx | Sort-Object Length -Descending | ForEach-Object {
      [pscustomobject]@{ File = $_.FullName.Replace($env:USERPROFILE, '~'); Size = (Format-Bytes $_.Length); Modified = $_.LastWriteTime.ToString('yyyy-MM-dd') }
    } | Format-Table -AutoSize
    'Note: vhdx files never shrink on their own. To reclaim space: wsl --shutdown, then'
    'Optimize-VHD -Path <file> -Mode Full  (admin PowerShell, Hyper-V module)'
    'or diskpart: select vdisk file="<file>" + attach vdisk readonly + compact vdisk. Back up first.'
  } else {
    'No WSL/Docker vhdx files found.'
  }
  '=== WSL/Docker local candidates ==='
  @(
    (Join-Local $env:LOCALAPPDATA 'Packages'),
    (Join-Local $env:LOCALAPPDATA 'Docker'),
    (Join-Path $env:APPDATA 'Docker'),
    (Join-Local $env:USERPROFILE '.wslconfig')
  ) | ForEach-Object { Get-FolderSize $_ } | Sort-Object Bytes -Descending | Format-Table -AutoSize
}

function Show-Docker {
  '=== Docker command ==='
  docker --version 2>&1
  docker system df 2>&1
  '=== Docker local candidates ==='
  @(
    (Join-Local $env:LOCALAPPDATA 'Docker'),
    (Join-Local $env:APPDATA 'Docker'),
    (Join-Local $env:PROGRAMDATA 'Docker')
  ) | ForEach-Object { Get-FolderSize $_ } | Sort-Object Bytes -Descending | Format-Table -AutoSize
}

function Show-LargeUserFolders {
  '=== Top user profile folders ==='
  Get-ChildFolderSizes $env:USERPROFILE $Top | Format-Table -AutoSize
  '=== Top LocalAppData folders ==='
  Get-ChildFolderSizes $env:LOCALAPPDATA $Top | Format-Table -AutoSize
}

function Contains-CodePoint([string]$Text, [int[]]$Codes) {
  foreach ($code in $Codes) {
    if ($Text.IndexOf([char]$code) -ge 0) { return $true }
  }
  return $false
}

function Invoke-IssueRoute([string]$Text) {
  $t = $Text.ToLowerInvariant()
  $hasMemory = Contains-CodePoint $Text @(0x5185, 0x5B58)
  $hasBrowser = Contains-CodePoint $Text @(0x6D4F, 0x89C8, 0x5668)
  $hasWechat = Contains-CodePoint $Text @(0x5FAE, 0x4FE1)
  $hasAndroid = Contains-CodePoint $Text @(0x5B89, 0x5353)
  $hasContainer = Contains-CodePoint $Text @(0x5BB9, 0x5668, 0x955C, 0x50CF)
  $hasProxy = Contains-CodePoint $Text @(0x4EE3, 0x7406, 0x7F51, 0x7EDC)
  $hasDisk = Contains-CodePoint $Text @(0x76D8, 0x78C1, 0x7A7A, 0x95F4, 0x6E05, 0x7406, 0x7F13, 0x5B58, 0x5927, 0x6587, 0x4EF6)
  $hasAudio = Contains-CodePoint $Text @(0x58F0, 0x97F3, 0x97F3, 0x9891)
  $hasDisplay = Contains-CodePoint $Text @(0x663E, 0x793A, 0x5C4F, 0x5E55)
  $hasPrinter = Contains-CodePoint $Text @(0x6253, 0x5370)
  $hasUpdate = Contains-CodePoint $Text @(0x66F4, 0x65B0)
  $hasDriver = Contains-CodePoint $Text @(0x9A71, 0x52A8)
  $hasSecurity = Contains-CodePoint $Text @(0x75C5, 0x6BD2, 0x9632, 0x706B, 0x5899, 0x5B89, 0x5168)
  $hasPower = Contains-CodePoint $Text @(0x7535, 0x6C60, 0x7761, 0x7720, 0x8017)
  $hasCrash = Contains-CodePoint $Text @(0x84DD, 0x5C4F, 0x5D29, 0x6E83, 0x95EA, 0x9000)
  $hasStartup = Contains-CodePoint $Text @(0x5F00, 0x673A, 0x542F, 0x52A8)
  $hasService = Contains-CodePoint $Text @(0x670D, 0x52A1)

  if (($t -match 'chrome|browser|edge|memory') -or $hasMemory -or $hasBrowser) { Show-Chrome; return }
  if ($t -match 'vscode|vs code|code.exe|webview|service worker') { Show-VSCode; return }
  if (($t -match 'wechat|xwechat') -or $hasWechat) { Show-WeChat; return }
  if (($t -match 'android|adb|flutter|java|jdk') -or $hasAndroid) { Show-Android; return }
  if ($t -match 'wsl|ubuntu|linux') { Show-WSL; return }
  if (($t -match 'docker|container|image') -or $hasContainer) { Show-Docker; return }
  if (($t -match 'proxy|vpn|network') -or $hasProxy) { Show-Network; return }
  if (($t -match 'blue screen|bsod|crash|freeze|reboot|event|log') -or $hasCrash) { Show-Events; return }
  if (($t -match 'startup|boot') -or $hasStartup) { Show-Startup; return }
  if (($t -match 'service') -or $hasService) { Show-Services; return }
  if (($t -match 'driver|device') -or $hasDriver) { Show-Drivers; return }
  if (($t -match 'update|windows update') -or $hasUpdate) { Show-Updates; return }
  if (($t -match 'audio|sound|speaker|microphone') -or $hasAudio) { Show-Audio; return }
  if (($t -match 'display|screen|monitor|gpu') -or $hasDisplay) { Show-Display; return }
  if (($t -match 'printer|print|spooler') -or $hasPrinter) { Show-Printer; return }
  if (($t -match 'defender|firewall|virus|security') -or $hasSecurity) { Show-Security; return }
  if (($t -match 'battery|power|sleep') -or $hasPower) { Show-Power; return }
  if (($t -match 'disk|space|clean|cache|large') -or $hasDisk) {
    Show-Drives | Format-Table -AutoSize
    Show-DiskCandidates | Format-Table -AutoSize
    Show-LargeUserFolders
    return
  }
  Show-Drives | Format-Table -AutoSize
  Show-Memory | Format-Table -AutoSize
  Show-DiskCandidates | Format-Table -AutoSize
}

function Get-TempCleanupPlan {
  # Deletion targets are restricted to two exact roots and to entries not
  # modified within the last 24h (so a running installer is never disturbed).
  $targets = @($env:TEMP, 'C:\Windows\Temp') | Where-Object { $_ } | Sort-Object -Unique
  $cutoff = (Get-Date).AddHours(-24)
  $plan = @()
  foreach ($target in $targets) {
    $resolved = Resolve-Path -LiteralPath $target -ErrorAction SilentlyContinue
    if (-not $resolved) { continue }
    if (-not (Test-SafeTempRoot $resolved.Path)) {
      $plan += [pscustomobject]@{ Root = $resolved.Path; Allowed = $false; Entries = @(); Bytes = 0; RecentSkipped = 0 }
      continue
    }
    $items = @(Get-ChildItem -LiteralPath $resolved.Path -Force -ErrorAction SilentlyContinue)
    $recent = @($items | Where-Object { $_.LastWriteTime -ge $cutoff })
    $stale = @($items | Where-Object { $_.LastWriteTime -lt $cutoff })
    $bytes = 0L
    foreach ($item in $stale) {
      if ($item.PSIsContainer) {
        $sum = (Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($null -ne $sum) { $bytes += [long]$sum }
      } else {
        $bytes += [long]$item.Length
      }
    }
    $plan += [pscustomobject]@{ Root = $resolved.Path; Allowed = $true; Entries = $stale; Bytes = $bytes; RecentSkipped = $recent.Count }
  }
  return $plan
}

function Show-TempPreview {
  $plan = Get-TempCleanupPlan
  '=== Temp cleanup preview ==='
  'Nothing has been deleted. Add -Apply to execute the plan below.'
  $plan | ForEach-Object {
    [pscustomobject]@{
      Root = $_.Root
      Allowed = $_.Allowed
      WouldDeleteEntries = @($_.Entries).Count
      WouldFree = (Format-Bytes $_.Bytes)
      SkippedRecent24h = $_.RecentSkipped
    }
  } | Format-Table -AutoSize
}

function Invoke-TempCleanup {
  $plan = Get-TempCleanupPlan
  $report = @()
  foreach ($entry in $plan) {
    if (-not $entry.Allowed) { Write-Host "Skipped unsafe temp path: $($entry.Root)"; continue }
    foreach ($item in $entry.Entries) {
      Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $remaining = @(Get-ChildItem -LiteralPath $entry.Root -Force -ErrorAction SilentlyContinue).Count
    $report += [pscustomobject]@{
      Root = $entry.Root
      TargetedEntries = @($entry.Entries).Count
      FreedBytes = $entry.Bytes
      RecentSkipped = $entry.RecentSkipped
      RemainingEntries = $remaining
    }
  }
  return $report
}

switch ($Mode) {
  'health' {
    if ($Format -eq 'json') { Write-JsonPayload (Get-HealthData); break }
    Show-Health
  }
  'baseline' {
    $result = Save-Baseline
    if ($Format -eq 'json') { Write-JsonPayload $result; break }
    "Baseline saved: $($result.saved_path)"
    $result.summary.drives | Format-Table -AutoSize
    [pscustomobject]@{
      StartupItems = $result.summary.startup_items
      AutoStoppedServices = $result.summary.auto_stopped_services
      PendingReboot = $result.summary.pending_reboot
    } | Format-List
  }
  'compare' {
    $diff = Compare-WithBaseline $BaselinePath
    if ($null -eq $diff) {
      if ($BaselinePath) { "Baseline file not found: $BaselinePath" }
      else { 'No baseline found yet. Run -Mode baseline to snapshot the current state first.' }
      break
    }
    if ($Format -eq 'json') { Write-JsonPayload $diff; break }
    "Baseline: $($diff.baseline_at)   Now: $($diff.now_at)"
    '=== Drive free-space change ==='
    $diff.drive_deltas | ForEach-Object {
      [pscustomobject]@{
        Drive = $_.device
        Before = (Format-Bytes $_.free_before_bytes)
        Now = (Format-Bytes $_.free_now_bytes)
        Change = (Format-Bytes $_.delta_bytes)
      }
    } | Format-Table -AutoSize
    '=== Startup items ==='
    "added: $(@($diff.startup_added).Count)   removed: $(@($diff.startup_removed).Count)"
    foreach ($item in $diff.startup_added) { "  + $item" }
    foreach ($item in $diff.startup_removed) { "  - $item" }
    "Auto-start-but-stopped services: $($diff.auto_stopped_services_before) -> $($diff.auto_stopped_services_now)"
    "Pending reboot: $($diff.pending_reboot)"
  }
  'overview' {
    if ($Format -eq 'json') {
      Write-JsonPayload ([pscustomobject]@{
        mode = 'overview'
        generated_at = (Get-Date).ToString('s')
        drives = @(Get-DriveData)
        memory = Get-MemoryData
        top_processes = @(Get-TopProcessData)
        disk_candidates = @(Get-DiskCandidateData)
      })
      break
    }
    '=== Drives ==='; Show-Drives | Format-Table -AutoSize
    '=== Top memory processes ==='; Show-Memory | Format-Table -AutoSize
    '=== Disk candidates ==='; Show-DiskCandidates | Format-Table -AutoSize
  }
  'disk' {
    if ($Format -eq 'json') {
      Write-JsonPayload ([pscustomobject]@{
        mode = 'disk'
        generated_at = (Get-Date).ToString('s')
        drives = @(Get-DriveData)
        candidates = @(Get-DiskCandidateData)
      })
      break
    }
    Show-Drives | Format-Table -AutoSize; Show-DiskCandidates | Format-Table -AutoSize
  }
  'memory' {
    if ($Format -eq 'json') {
      Write-JsonPayload ([pscustomobject]@{
        mode = 'memory'
        generated_at = (Get-Date).ToString('s')
        memory = Get-MemoryData
        top_processes = @(Get-TopProcessData)
      })
      break
    }
    Show-Memory | Format-Table -AutoSize
  }
  'dev' {
    if ($Format -eq 'json') {
      Write-JsonPayload ([pscustomobject]@{
        mode = 'dev'
        generated_at = (Get-Date).ToString('s')
        tools = @(Show-DevTools)
      })
      break
    }
    Show-DevTools | Format-List
  }
  'network' {
    if ($Format -eq 'json') {
      Write-JsonPayload ([pscustomobject]@{
        mode = 'network'
        generated_at = (Get-Date).ToString('s')
        env_proxy = [pscustomobject]@{
          http_proxy = (Redact-SensitiveText $env:HTTP_PROXY)
          https_proxy = (Redact-SensitiveText $env:HTTPS_PROXY)
          all_proxy = (Redact-SensitiveText $env:ALL_PROXY)
        }
        note = 'WinHTTP proxy is text-only in this version; run text mode for netsh output.'
      })
      break
    }
    Show-Network
  }
  'net-test' { Test-NetworkTarget $Target }
  'app' { Show-App $ProcessName }
  'system' { Show-System }
  'events' { Show-Events }
  'startup' { Show-Startup }
  'services' { Show-Services }
  'drivers' { Show-Drivers }
  'updates' { Show-Updates }
  'devices' { Show-Devices }
  'power' { Show-Power }
  'audio' { Show-Audio }
  'display' { Show-Display }
  'printer' { Show-Printer }
  'security' { Show-Security }
  'repair-check' { Show-RepairCheck }
  'chrome' { Show-Chrome }
  'vscode' { Show-VSCode }
  'wechat' { Show-WeChat }
  'android' { Show-Android }
  'wsl' { Show-WSL }
  'docker' { Show-Docker }
  'large' { Show-LargeUserFolders }
  'issue' { Invoke-IssueRoute $Issue }
  'cleanup-temp' {
    if ($Apply) {
      $report = Invoke-TempCleanup
      if ($Format -eq 'json') { Write-JsonPayload ([pscustomobject]@{ mode = 'cleanup-temp'; applied = $true; roots = @($report) }); break }
      $report | ForEach-Object {
        [pscustomobject]@{ Root = $_.Root; DeletedTargeted = $_.TargetedEntries; Freed = (Format-Bytes $_.FreedBytes); SkippedRecent24h = $_.RecentSkipped; RemainingEntries = $_.RemainingEntries }
      } | Format-Table -AutoSize
      'Done. Rerun -Mode disk to verify.'
    } else {
      if ($Format -eq 'json') {
        $plan = @(Get-TempCleanupPlan)
        Write-JsonPayload ([pscustomobject]@{
          mode = 'cleanup-temp'
          applied = $false
          note = 'Preview only. Re-run with -Apply to delete.'
          roots = @($plan | ForEach-Object { [pscustomobject]@{ root = $_.Root; allowed = $_.Allowed; would_delete_entries = @($_.Entries).Count; would_free_bytes = $_.Bytes; skipped_recent_24h = $_.RecentSkipped } })
        })
        break
      }
      Show-TempPreview
    }
  }
}

