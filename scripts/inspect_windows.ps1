param(
  [ValidateSet('overview', 'health', 'baseline', 'compare', 'disk', 'memory', 'dev', 'network', 'net-test', 'app', 'chrome', 'vscode', 'wechat', 'android', 'wsl', 'docker', 'large', 'files', 'smart', 'system', 'events', 'startup', 'services', 'drivers', 'updates', 'devices', 'power', 'audio', 'display', 'printer', 'security', 'repair-check', 'issue', 'cleanup-temp', 'self-test')]
  [string]$Mode = 'overview',
  [int]$Top = 15,
  [string]$Issue = '',
  [string]$Target = '',
  [string]$ProcessName = '',
  [string]$BaselinePath = '',
  [string]$Path = '',
  [int]$MinSizeMB = 50,
  [switch]$Deep,
  [switch]$Apply,
  [switch]$Force,
  [ValidateSet('text', 'json')]
  [string]$Format = 'text'
)

$WinfixVersion = '0.3.5'
$ErrorActionPreference = 'SilentlyContinue'

# Captured so the self-test can re-run this script in a child process and prove
# the end-to-end deletion contract instead of only asserting the plan.
$WinfixScriptPath = $PSCommandPath

# Emit UTF-8. Windows PowerShell 5.1 otherwise writes the OEM codepage (cp936 on
# Chinese Windows), so Chinese paths and messages turn into mojibake as soon as
# an agent captures stdout instead of rendering it in a console.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$MaxFilesPerFolder = 20000   # hard cap of files counted per folder
$FolderBudgetSeconds = 6     # per-folder wall-clock budget
$SectionBudgetSeconds = 45   # per-section global wall-clock budget
$NativeTimeoutSeconds = 20   # default timeout for external commands
$EventQueryCap = 50          # events pulled for the health score (a floor, not a total)
$EventSummaryCap = 20        # events pulled for the health summary

# Baseline anti-churn: a snapshot taken minutes ago with the same drives, the
# same startup set and the same reboot state is worthless, but it still pushes
# real history out of the newest-20 window. Save it only when something moved.
$BaselineMinIntervalMinutes = 15
$BaselineFreeSpaceToleranceBytes = 200MB

$script:Deadline = $null
$script:Cache = @{}
$script:SelfTestFailures = 0
$script:CandidateSkipped = 0

function Join-Local([string]$Base, [string]$Child) {
  if ([string]::IsNullOrWhiteSpace($Base)) { return $null }
  return (Join-Path $Base $Child)
}

function Start-SectionBudget([int]$Seconds) { $script:Deadline = (Get-Date).AddSeconds($Seconds) }
function Clear-SectionBudget { $script:Deadline = $null }
function Test-BudgetExpired {
  if ($null -eq $script:Deadline) { return $false }
  return ((Get-Date) -gt $script:Deadline)
}

function Write-Diag([string]$Text) {
  # Progress goes to stderr for humans, but never in JSON mode: an agent that
  # runs the script with 2>&1 would otherwise get progress lines glued onto the
  # JSON payload and fail to parse it.
  if ($Format -ne 'json') { [Console]::Error.WriteLine($Text) }
}

function Get-Cached([string]$Key, [scriptblock]$Factory) {
  # Live measurements are collected once per run: health used to hit the event
  # log and PnP three times in a row, which alone cost ~20s.
  if (-not $script:Cache.ContainsKey($Key)) { $script:Cache[$Key] = & $Factory }
  return $script:Cache[$Key]
}

function Quote-NativeArg([string]$Value) {
  if ($null -eq $Value) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  $escaped = $Value -replace '(\\*)"', '$1$1\"'
  $escaped = $escaped -replace '(\\+)$', '$1$1'
  return '"' + $escaped + '"'
}

function Convert-RawOutput([byte[]]$Bytes) {
  # External Windows tools disagree on encoding: wsl.exe writes UTF-16LE,
  # netsh/powercfg write the OEM codepage, curl writes UTF-8. Sniff the bytes
  # instead of assuming one of them.
  if ($null -eq $Bytes -or $Bytes.Count -eq 0) { return '' }
  $nul = 0
  foreach ($b in $Bytes) { if ($b -eq 0) { $nul++ } }
  if ($nul -gt ($Bytes.Count / 8)) { return [System.Text.Encoding]::Unicode.GetString($Bytes) }
  try {
    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    return $strict.GetString($Bytes)
  } catch {
    $oem = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
    return [System.Text.Encoding]::GetEncoding($oem).GetString($Bytes)
  }
}

function Invoke-NativeText([string]$Exe, [string[]]$ArgList, [int]$TimeoutSeconds = 0) {
  # Runs an external command with a hard timeout and an explicit encoding path.
  # No shell interpretation, no dynamic code evaluation, no network access: the
  # executable and its arguments are passed directly to the process API.
  $res = [pscustomobject]@{
    exe = $Exe; args = @($ArgList); exit_code = $null
    stdout = ''; stderr = ''; timed_out = $false; missing = $false
    resolved_path = $null; script_only = $false
  }
  # Prefer a real executable. `npm` resolves to npm.ps1 first on a stock Node
  # install, and a .ps1 cannot be launched through the process API at all.
  $candidates = @(Get-Command -Name $Exe -All -ErrorAction SilentlyContinue)
  if ($candidates.Count -eq 0) { $res.missing = $true; return $res }
  $command = $candidates |
    Where-Object { $_.CommandType -eq 'Application' -and $_.Source -match '\.(exe|com|cmd|bat)$' } |
    Select-Object -First 1
  if (-not $command) { $command = $candidates | Where-Object { $_.CommandType -eq 'Application' } | Select-Object -First 1 }
  if (-not $command) {
    $res.script_only = $true
    $res.stderr = "only a script is on PATH for '$Exe' ($($candidates[0].Source)); it cannot be probed without a shell"
    return $res
  }
  $res.resolved_path = $command.Source
  if ($TimeoutSeconds -le 0) { $TimeoutSeconds = $NativeTimeoutSeconds }
  $latin1 = [System.Text.Encoding]::GetEncoding(28591)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $command.Source
  $psi.Arguments = (@($ArgList) | ForEach-Object { Quote-NativeArg $_ }) -join ' '
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $latin1
  $psi.StandardErrorEncoding = $latin1
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  try {
    if (-not $proc.Start()) { $res.missing = $true; return $res }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
      $res.timed_out = $true
      try { $proc.Kill() } catch { }
      try { $proc.WaitForExit(3000) | Out-Null } catch { }
    }
    try { $res.exit_code = $proc.ExitCode } catch { }
    $res.stdout = Convert-RawOutput $latin1.GetBytes($outTask.Result)
    $res.stderr = Convert-RawOutput $latin1.GetBytes($errTask.Result)
  } catch {
    $res.stderr = $_.Exception.Message
  } finally {
    try { $proc.Dispose() } catch { }
  }
  return $res
}

function Get-NativeLines([string]$Exe, [string[]]$ArgList, [int]$TimeoutSeconds = 0, [int]$Max = 4) {
  $effective = if ($TimeoutSeconds -le 0) { $NativeTimeoutSeconds } else { $TimeoutSeconds }
  $r = Invoke-NativeText $Exe $ArgList $effective
  if ($r.missing) { return @("not found on PATH: $Exe") }
  if ($r.script_only) { return @($r.stderr) }
  if ($r.timed_out) { return @("timed out after ${effective}s") }
  $lines = @(($r.stdout + "`n" + $r.stderr) -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First $Max)
  if ($lines.Count -eq 0) { return @("(no output, exit code $($r.exit_code))") }
  return $lines
}

function Format-Bytes([double]$Bytes) {
  if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
  if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
  return "$Bytes B"
}

function Format-ScanAge([object]$Value) {
  # Get-MpComputerStatus reports "never scanned" as 0xFFFFFFFF. Printed raw it
  # reads like a real age of 4294967295 days.
  if ($null -eq $Value) { return 'unknown' }
  $n = [int64]$Value
  if ($n -ge 4294967295) { return 'never' }
  return "$n d"
}

function Redact-SensitiveText([object]$Value) {
  if ($null -eq $Value) { return $null }
  $text = [string]$Value
  $text = $text -replace '([a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s:@]+:[^@\s/]+@', '$1***:***@'
  $text = $text -replace '(?i)(password|passwd|pwd|token|apikey|api_key|secret)=([^&\s]+)', '$1=***'
  return $text
}

function Get-TempRootAllowlist {
  # Deletion roots are an allowlist, never "whatever %TEMP% happens to say".
  $list = New-Object System.Collections.ArrayList
  foreach ($p in @((Join-Path $env:LOCALAPPDATA 'Temp'), 'C:\Windows\Temp')) {
    if ($p) { [void]$list.Add($p) }
  }
  # A redirected %TEMP%/%TMP% (common when C: is kept small) is accepted only
  # when its leaf name is temp/tmp, so a broken TEMP=C:\ can never become a
  # delete root.
  foreach ($p in @($env:TEMP, $env:TMP)) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    $leaf = Split-Path -Leaf $p.TrimEnd('\')
    if ($leaf -match '^(temp|tmp)$') { [void]$list.Add($p) }
  }
  return @($list | Sort-Object -Unique)
}

function Test-SafeTempRoot([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
  if (-not $resolved) { return $false }
  $full = [System.IO.Path]::GetFullPath($resolved.Path).TrimEnd('\')
  if ($full -match '^[A-Za-z]:$') { return $false }
  $allowed = @(Get-TempRootAllowlist | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') }) | Sort-Object -Unique
  if ($allowed -contains $full) { return $true }
  $leaf = Split-Path -Leaf $full
  if ($leaf -notmatch '^(temp|tmp)$') { return $false }
  $forbidden = @($env:SystemRoot, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { $_ } | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') }
  return -not ($forbidden -contains $full)
}

function Get-FolderSize([string]$Path, [int]$BudgetSeconds = 0) {
  $result = [pscustomobject]@{ Path = $Path; Exists = $false; Bytes = [int64]0; Files = 0; Size = 'missing'; Scan = 'missing' }
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $result }
  if ($BudgetSeconds -le 0) { $BudgetSeconds = $FolderBudgetSeconds }
  $result.Exists = $true
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $stack = New-Object System.Collections.Stack
  $stack.Push($Path)
  $files = 0
  $bytes = [int64]0
  $scan = 'full'
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    $entries = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue
    foreach ($entry in $entries) {
      if ($entry.PSIsContainer) {
        # Never walk through a junction or symlink: it double counts and can loop.
        if (-not ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($entry.FullName) }
      } else {
        $files++
        $bytes += [int64]$entry.Length
      }
    }
    if ($files -ge $MaxFilesPerFolder) { $scan = 'sampled'; break }
    if ($watch.Elapsed.TotalSeconds -gt $BudgetSeconds -or (Test-BudgetExpired)) { $scan = 'partial'; break }
  }
  $result.Bytes = $bytes
  $result.Files = $files
  $result.Size = (Format-Bytes $bytes)
  $result.Scan = $scan
  return $result
}

function Get-ChildFolderSizes([string]$Path, [int]$Limit = 15, [int]$PerChildBudget = 4) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{ Path = $Path; Exists = $false; Bytes = [int64]0; Files = 0; Size = 'missing'; Scan = 'missing' }
  }
  $sizes = New-Object System.Collections.ArrayList
  foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -Directory -ErrorAction SilentlyContinue)) {
    if (Test-BudgetExpired) { break }
    Write-Diag "  scanning $($child.Name)"
    [void]$sizes.Add((Get-FolderSize $child.FullName $PerChildBudget))
  }
  return @($sizes | Sort-Object Bytes -Descending | Select-Object -First $Limit)
}

function Show-Drives {
  Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
    Select-Object DeviceID,
      @{Name='Size';Expression={Format-Bytes $_.Size}},
      @{Name='Free';Expression={Format-Bytes $_.FreeSpace}},
      @{Name='FreePercent';Expression={[math]::Round(($_.FreeSpace / $_.Size) * 100, 1)}}
}

function Get-DriveData {
  return Get-Cached 'drives' {
    @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
      ForEach-Object {
        [pscustomobject]@{
          device = $_.DeviceID
          size_bytes = [int64]$_.Size
          free_bytes = [int64]$_.FreeSpace
          free_percent = if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { 0 }
          status = if ($_.Size -le 0) { 'unknown' } elseif (($_.FreeSpace / $_.Size) -lt 0.10) { 'low' } elseif (($_.FreeSpace / $_.Size) -lt 0.20) { 'watch' } else { 'ok' }
        }
      })
  }
}

function Get-MemoryData {
  return Get-Cached 'memory' {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $total = [double]$os.TotalVisibleMemorySize * 1KB
    $free = [double]$os.FreePhysicalMemory * 1KB
    [pscustomobject]@{
      total_bytes = [int64]$total
      free_bytes = [int64]$free
      used_percent = if ($total -gt 0) { [math]::Round((1 - ($free / $total)) * 100, 1) } else { $null }
    }
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
  Measure-DiskCandidates | ForEach-Object {
    [pscustomobject]@{
      path = $_.Path
      exists = $_.Exists
      bytes = [int64]$_.Bytes
      size = $_.Size
      files = $_.Files
      scan = $_.Scan
      risk = $_.Risk
      kind = $_.Kind
    }
  }
}

function Get-RecentEvents([int]$Days = 3, [int]$Max = 50) {
  return Get-Cached "events-$Days-$Max" {
    @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1,2; StartTime = (Get-Date).AddDays(-$Days) } -MaxEvents $Max -ErrorAction SilentlyContinue)
  }
}

function Get-TopEventSources([object[]]$Events, [int]$Limit = 3) {
  # The stability component is driven by a capped count, and ordinary Windows
  # logs contain error-level entries from providers that are not faults
  # (BitLocker 24641 and Ntfs 98 both dominate on the machine this was found
  # on). Naming the sources keeps "0 stability" from reading as "your machine
  # is unstable" without inventing a different scoring formula.
  if (-not $Events -or $Events.Count -eq 0) { return @() }
  return @($Events | Group-Object ProviderName | Sort-Object Count -Descending |
    Select-Object -First $Limit | ForEach-Object { "$($_.Name) $($_.Count)" })
}

function Get-ProblemDevices {
  return Get-Cached 'problem-devices' {
    @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
  }
}

function Get-DefenderStatus {
  return Get-Cached 'defender' {
    try { Get-MpComputerStatus -ErrorAction Stop } catch { $null }
  }
}

function Get-AntivirusProducts {
  # SecurityCenter2 is the authoritative list of what Windows treats as the
  # active AV. Defender reporting "real-time off" is *normal* when a third-party
  # AV is registered, so the Defender flag alone is not a verdict.
  return Get-Cached 'av-products' {
    try {
      @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop |
        ForEach-Object { [pscustomobject]@{ name = [string]$_.displayName; state = [int]$_.productState } })
    } catch { @() }
  }
}

function Get-SecurityPosture([object]$DefenderStatus, [object[]]$AvProducts, [switch]$Injected) {
  # One verdict from both sources, so a caller never has to guess whether
  # RealTimeProtectionEnabled=False means "unprotected" or "a third-party AV
  # took over on purpose". score = $null means "exclude from the health score".
  # -Injected lets the self-test assert the third-party branch, which cannot be
  # reproduced on a machine that has no third-party AV installed.
  $defender = if ($Injected) { $DefenderStatus } else { Get-DefenderStatus }
  $products = if ($Injected) { @($AvProducts) } else { @(Get-AntivirusProducts) }
  $thirdParty = @($products | Where-Object { $_.name -and $_.name -notmatch 'Defender' } | ForEach-Object { $_.name })
  $thirdPartyText = $thirdParty -join ', '
  $mode = if ($defender) { [string]$defender.AMRunningMode } else { '' }
  $realtime = if ($defender) { [bool]$defender.RealTimeProtectionEnabled } else { $false }
  if (-not $defender) {
    $verdict = if ($thirdParty.Count -gt 0) {
      "Defender status is unavailable (blocked by policy, or replaced); registered AV: $thirdPartyText."
    } else {
      'Defender status is unavailable (no Defender, or the cmdlet is blocked by policy).'
    }
    return [pscustomobject]@{ state = 'unavailable'; mode = $mode; third_party = @($thirdParty); score = $null; measured = 'unavailable'; verdict = $verdict }
  }
  if ($realtime) {
    $verdict = if ($thirdParty.Count -gt 0) {
      "Defender real-time protection is on; also registered: $thirdPartyText."
    } else {
      'Defender real-time protection is on.'
    }
    return [pscustomobject]@{ state = 'protected'; mode = $mode; third_party = @($thirdParty); score = 100; measured = 'Defender real-time on'; verdict = $verdict }
  }
  if ($thirdParty.Count -gt 0) {
    return [pscustomobject]@{
      state = 'third-party'; mode = $mode; third_party = @($thirdParty); score = 100
      measured = "third-party AV: $thirdPartyText"
      verdict = "Defender real-time is off because a third-party AV is registered ($thirdPartyText); Windows hands protection to it on purpose. This is not a gap."
    }
  }
  $passive = [bool]($mode -match 'Passive')
  return [pscustomobject]@{
    state = $(if ($passive) { 'passive' } else { 'unprotected' }); mode = $mode; third_party = @()
    score = $(if ($passive) { 40 } else { 0 })
    measured = $(if ($passive) { 'Defender passive, no third-party AV registered' } else { 'no active real-time protection' })
    verdict = $(if ($passive) {
        'Defender is in passive mode and no third-party AV is registered: real-time protection is not active.'
      } else {
        'No third-party AV is registered and Defender real-time protection is off: this machine currently has no active real-time protection.'
      })
  }
}

function Get-DiskHealthData {
  return Get-Cached 'disk-health' {
    $disks = @()
    $physical = @()
    try { $physical = @(Get-PhysicalDisk -ErrorAction Stop) } catch { $physical = @() }
    if ($physical.Count -gt 0) {
      foreach ($d in $physical) {
        $disks += [pscustomobject]@{
          name = $d.FriendlyName
          media = [string]$d.MediaType
          bus = [string]$d.BusType
          health = [string]$d.HealthStatus
          operational = [string]$d.OperationalStatus
          size_bytes = [int64]$d.Size
        }
      }
    } else {
      foreach ($d in @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)) {
        $disks += [pscustomobject]@{
          name = $d.Model
          media = 'unknown'
          bus = [string]$d.InterfaceType
          health = if ([string]$d.Status -eq 'OK') { 'Healthy' } else { [string]$d.Status }
          operational = [string]$d.Status
          size_bytes = [int64]$d.Size
        }
      }
    }
    $unhealthy = @($disks | Where-Object { $_.health -ne 'Healthy' -or ($_.operational -and $_.operational -ne 'OK') })
    [pscustomobject]@{ disks = @($disks); unhealthy = $unhealthy; unavailable = ($disks.Count -eq 0) }
  }
}

function Get-HealthData {
  $score = Get-HealthScore
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
  $events = Get-RecentEvents 3 $EventSummaryCap
  $problemDevices = Get-ProblemDevices
  $defender = Get-DefenderStatus
  $security = Get-SecurityPosture
  $memory = Get-MemoryData
  $drives = @(Get-DriveData)
  $diskHealth = Get-DiskHealthData
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
      critical_or_error_events_capped = [bool]($events.Count -ge $EventSummaryCap)
      problem_devices = $problemDevices.Count
      defender_realtime = if ($defender) { $defender.RealTimeProtectionEnabled } else { $null }
      security_state = $security.state
      security_verdict = $security.verdict
      drive_status = @($drives | Select-Object device, free_percent, status)
      physical_disks = @($diskHealth.disks | Select-Object name, media, health, operational, size_bytes)
    }
    findings = @(
      if (($drives | Where-Object { $_.status -eq 'low' }).Count -gt 0) { 'At least one drive is below 10% free; cleanup has the highest payoff.' }
      elseif (($drives | Where-Object { $_.status -eq 'watch' }).Count -gt 0) { 'At least one drive is below 20% free; worth watching.' }
      if ($memory.used_percent -ge 80) { 'Memory usage is high.' }
      if ($events.Count -gt 0) { 'Recent critical/error system events exist.' }
      if ($problemDevices.Count -gt 0) { 'Windows reports problem devices.' }
      if ($diskHealth.unhealthy.Count -gt 0) { 'A physical disk reports a non-Healthy state; back up before repairing anything.' }
      if ($security.state -eq 'unprotected') { 'No active real-time protection: no third-party AV is registered and Defender real-time is off.' }
      if ($security.state -eq 'passive') { 'Defender is in passive mode and no third-party AV is registered; real-time protection is not active.' }
      if ($score.pending_reboot) { 'A reboot is pending; some fixes stay incomplete until then.' }
    )
    recommended_actions = @(
      'Use the route matching the strongest finding: disk, memory, events, smart, devices, or security.'
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
  return Get-Cached 'startup' {
    @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object name, location)
  }
}

function Get-ScheduledTaskInventory {
  # Auto-start vectors that the classic startup list misses. Read-only; the
  # Microsoft\* tree is skipped because it is Windows' own plumbing.
  return Get-Cached 'scheduled' {
    $out = @()
    try {
      foreach ($t in @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' })) {
        $out += [pscustomobject]@{ name = $t.TaskName; path = [string]$t.TaskPath; state = [string]$t.State }
      }
    } catch { }
    return @($out | Sort-Object path, name)
  }
}

function Get-HealthScore {
  $drives = @(Get-DriveData)
  $memory = Get-MemoryData
  $events = Get-RecentEvents 3 $EventQueryCap
  $problemDevices = Get-ProblemDevices
  $boot = Get-BootDurations
  $startupCount = @(Get-StartupInventory).Count
  $lastHotfix = Get-Cached 'last-hotfix' { Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1 }
  $updateAgeDays = if ($lastHotfix -and $lastHotfix.InstalledOn) { [int][math]::Round(((Get-Date) - $lastHotfix.InstalledOn).TotalDays) } else { $null }
  $pending = Get-PendingReboot
  $diskHealth = Get-DiskHealthData
  $security = Get-SecurityPosture

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
  $stabilityPenalty = $events.Count * 8 + $problemDevices.Count * 10
  if ($diskHealth.unhealthy.Count -gt 0) { $stabilityPenalty += 25 }
  # The query is capped, so never print a capped count as an exact total.
  $eventLabel = if ($events.Count -ge $EventQueryCap) { "$EventQueryCap+ (capped)" } else { [string]$events.Count }
  $components += [pscustomobject]@{
    key = 'stability'; weight = 15; score = [int][math]::Max(0, 100 - $stabilityPenalty)
    measured = "$eventLabel critical/error events in 3d; $($problemDevices.Count) problem devices; $($diskHealth.unhealthy.Count) unhealthy disks"
    sources = @(Get-TopEventSources $events)
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
  if ($null -ne $security.score) {
    $components += [pscustomobject]@{ key = 'security'; weight = 5; score = [int]$security.score; measured = $security.measured }
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

function Get-NewestBaselineFile {
  $dir = Get-WinfixStateDir
  $files = @(Get-ChildItem $dir -Filter 'baseline-*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  if ($files.Count -eq 0) { return $null }
  return $files[0]
}

function Test-BaselineRedundant([object]$Previous, [object]$Current) {
  # A snapshot taken minutes ago with the same drives, the same startup set and
  # the same reboot state adds nothing but churn: it pushes real history out of
  # the newest-20 window. Saving is still allowed whenever something actually
  # changed — for example right after a cleanup that freed several GB.
  if (-not $Previous -or -not $Previous.created_at) { return $false }
  try { $previousAt = [datetime]::Parse($Previous.created_at) } catch { return $false }
  if (((Get-Date) - $previousAt).TotalMinutes -ge $BaselineMinIntervalMinutes) { return $false }
  foreach ($drive in @($Current.drives)) {
    $before = $Previous.drives | Where-Object { $_.device -eq $drive.device } | Select-Object -First 1
    if (-not $before) { return $false }
    if ([math]::Abs([int64]$drive.free_bytes - [int64]$before.free_bytes) -gt $BaselineFreeSpaceToleranceBytes) { return $false }
  }
  $beforeIds = @($Previous.startup | ForEach-Object { "$($_.location)|$($_.name)" } | Sort-Object)
  $nowIds = @($Current.startup | ForEach-Object { "$($_.location)|$($_.name)" } | Sort-Object)
  if (($beforeIds -join "`n") -ne ($nowIds -join "`n")) { return $false }
  if ([bool]$Previous.pending_reboot -ne [bool]$Current.pending_reboot) { return $false }
  return $true
}

function Get-BaselineData {
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
  [pscustomobject]@{
    kind = 'winfix-baseline'
    version = 2
    created_at = (Get-Date).ToString('s')
    computer = $env:COMPUTERNAME
    drives = @(Get-DriveData)
    memory = Get-MemoryData
    startup = @(Get-StartupInventory)
    scheduled = @(Get-ScheduledTaskInventory)
    auto_stopped_services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
      Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' } |
      Select-Object -ExpandProperty Name | Sort-Object)
    pending_reboot = Get-PendingReboot
    last_boot = if ($os) { $os.LastBootUpTime.ToString('s') } else { $null }
  }
}

function Save-Baseline([switch]$Force) {
  $data = Get-BaselineData
  $newest = Get-NewestBaselineFile
  if (-not $Force -and $newest) {
    $previous = $null
    try { $previous = Get-Content -LiteralPath $newest.FullName -Raw | ConvertFrom-Json } catch { $previous = $null }
    if ($previous -and (Test-BaselineRedundant $previous $data)) {
      $ageMinutes = [math]::Round(((Get-Date) - [datetime]::Parse($previous.created_at)).TotalMinutes, 1)
      return [pscustomobject]@{
        mode = 'baseline'
        version = $WinfixVersion
        saved = $false
        skipped_reason = "an equivalent baseline was saved $ageMinutes minute(s) ago (within the ${BaselineMinIntervalMinutes}-minute window) and nothing material changed"
        existing_path = $newest.FullName
        existing_created_at = $previous.created_at
        hint = 'Use -Force to save anyway, or re-run after a change that moved the numbers.'
      }
    }
  }
  $dir = Get-WinfixStateDir
  $path = Join-Path $dir ("baseline-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + ".json")
  $data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
  $all = @(Get-ChildItem $dir -Filter 'baseline-*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  if ($all.Count -gt 20) { $all | Select-Object -Skip 20 | Remove-Item -Force -ErrorAction SilentlyContinue }
  [pscustomobject]@{
    mode = 'baseline'
    version = $WinfixVersion
    saved = $true
    saved_path = $path
    created_at = $data.created_at
    summary = [pscustomobject]@{
      drives = @($data.drives | Select-Object device, free_percent, status)
      startup_items = @($data.startup).Count
      scheduled_tasks = @($data.scheduled).Count
      auto_stopped_services = @($data.auto_stopped_services).Count
      pending_reboot = $data.pending_reboot
    }
  }
}

function Compare-WithBaseline([string]$Path) {
  if ($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $baselineFile = $Path
  } else {
    $newest = Get-NewestBaselineFile
    if (-not $newest) { return $null }
    $baselineFile = $newest.FullName
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

  # Scheduled tasks are a classic "the machine got slower" vector. Baselines
  # written by 0.2.x have no `scheduled` field; say so instead of inventing a
  # comparison.
  $scheduledTracked = ($base.PSObject.Properties.Name -contains 'scheduled') -and ($null -ne $base.scheduled)
  $scheduledAdded = @()
  $scheduledRemoved = @()
  if ($scheduledTracked) {
    $baseSched = @($base.scheduled | ForEach-Object { "$($_.path)|$($_.name)" })
    $nowSched = @($now.scheduled | ForEach-Object { "$($_.path)|$($_.name)" })
    $scheduledAdded = @($nowSched | Where-Object { $baseSched -notcontains $_ })
    $scheduledRemoved = @($baseSched | Where-Object { $nowSched -notcontains $_ })
  }

  [pscustomobject]@{
    mode = 'compare'
    version = $WinfixVersion
    baseline_path = $baselineFile
    baseline_version = $base.version
    baseline_at = $base.created_at
    now_at = $now.created_at
    drive_deltas = $driveDeltas
    startup_added = $added
    startup_removed = $removed
    scheduled_tracked = $scheduledTracked
    scheduled_added = $scheduledAdded
    scheduled_removed = $scheduledRemoved
    auto_stopped_services_before = @($base.auto_stopped_services).Count
    auto_stopped_services_now = @($now.auto_stopped_services).Count
    pending_reboot = $now.pending_reboot
  }
}

function ConvertTo-AsciiJsonString([object]$Payload) {
  # JSON is emitted ASCII-only: non-ASCII characters become \uXXXX escapes. A
  # parent PowerShell process decodes a child's stdout with its own codepage
  # (cp936 on Chinese Windows), which would otherwise corrupt every Chinese path
  # in the payload. JSON parsers handle the escapes transparently.
  $json = $Payload | ConvertTo-Json -Depth 8
  $builder = New-Object System.Text.StringBuilder
  foreach ($ch in $json.ToCharArray()) {
    if ([int]$ch -lt 128) { [void]$builder.Append($ch) }
    else { [void]$builder.AppendFormat('\u{0:x4}', [int]$ch) }
  }
  return $builder.ToString()
}

function Write-JsonPayload([object]$Payload) {
  return ConvertTo-AsciiJsonString $Payload
}

function Show-Health {
  $score = Get-HealthScore
  $data = Get-HealthData
  '=== Health score ==='
  [pscustomobject]@{ Version = $WinfixVersion; Score = $score.total; PendingReboot = $score.pending_reboot } | Format-List
  $score.components | ForEach-Object {
    [pscustomobject]@{ Component = $_.key; Score = $_.score; Weight = $_.weight; Measured = $_.measured }
  } | Format-Table -AutoSize
  $stability = $score.components | Where-Object { $_.key -eq 'stability' } | Select-Object -First 1
  if ($stability -and @($stability.sources).Count -gt 0) {
    "Top error sources: $(@($stability.sources) -join ', ') (counts inside the capped query, so floors; run -Mode events for the full list)."
  }
  $worst = $score.components | Sort-Object { -($_.weight * (100 - $_.score)) } | Select-Object -First 1
  if ($worst) { "Biggest lever: $($worst.key) ($($worst.measured))" }

  '=== Health summary ==='
  $summary = $data.summary
  [pscustomobject]@{
    Computer = $summary.computer
    UptimeDays = $summary.uptime_days
    MemoryUsedPercent = $summary.memory_used_percent
    CriticalOrErrorEventsLast3Days = $(if ($summary.critical_or_error_events_capped) { "$($summary.critical_or_error_events_last_3_days)+ (capped)" } else { [string]$summary.critical_or_error_events_last_3_days })
    ProblemDevices = $summary.problem_devices
    DefenderRealtime = $summary.defender_realtime
    SecurityState = $summary.security_state
  } | Format-List

  '=== Drive pressure ==='
  Get-DriveData | ForEach-Object {
    [pscustomobject]@{ Drive = $_.device; Free = (Format-Bytes $_.free_bytes); FreePercent = $_.free_percent; Status = $_.status }
  } | Format-Table -AutoSize

  '=== Physical disks ==='
  if (@($summary.physical_disks).Count -gt 0) {
    $summary.physical_disks | ForEach-Object {
      [pscustomobject]@{ Disk = $_.name; Media = $_.media; Health = $_.health; Status = $_.operational; Size = (Format-Bytes $_.size_bytes) }
    } | Format-Table -AutoSize
  } else {
    'Storage module unavailable on this system; run -Mode smart for the fallback view.'
  }

  '=== Findings ==='
  if (@($data.findings).Count -eq 0) { 'No blocking findings.' } else { $data.findings | ForEach-Object { "- $_" } }

  '=== Top memory processes ==='
  Show-Memory | Select-Object -First 8 | Format-Table -AutoSize
}

function New-CandidateSpec([string]$Path, [string]$Risk, [string]$Kind) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  return [pscustomobject]@{ Path = $Path; Risk = $Risk; Kind = $Kind }
}

function Show-CandidateTable([object[]]$Items) {
  # Tables truncate long paths with "...", which makes the output useless for
  # acting on. Print the full path on its own line instead.
  foreach ($item in @($Items)) {
    "$($item.Size)  [$($item.Risk)]  $($item.Kind)"
    "    $($item.Path)"
  }
}

function Show-FolderSizeTable([object[]]$Items) {
  foreach ($item in @($Items)) {
    "$($item.Size)`t$($item.Scan)`t$($item.Path)"
  }
}

function Get-DiskCandidateSpecs {
  # Tier 1: cheap, common, high-yield. Every entry says what it is and how risky
  # it is; the cleaning method lives in references/known-folders.md.
  $specs = @()
  $specs += New-CandidateSpec $env:TEMP 'low' '当前用户临时目录 (%TEMP%)'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Temp') 'low' '用户临时目录 (LocalAppData\Temp)'
  $specs += New-CandidateSpec 'C:\Windows\Temp' 'low' '系统临时目录'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'CrashDumps') 'low' '程序崩溃转储（经常累积到 GB）'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Microsoft\Windows\WER') 'low' 'Windows 错误报告（用户）'
  $specs += New-CandidateSpec 'C:\ProgramData\Microsoft\Windows\WER' 'low' 'Windows 错误报告（全局）'
  $specs += New-CandidateSpec 'C:\$Recycle.Bin' 'low' '回收站'
  $specs += New-CandidateSpec 'C:\Windows\SoftwareDistribution\Download' 'low' 'Windows 更新下载缓存'
  $specs += New-CandidateSpec 'C:\ProgramData\Microsoft\Windows\DeliveryOptimization' 'low' '传递优化缓存'
  $specs += New-CandidateSpec 'C:\Windows.old' 'medium' '旧 Windows 安装备份（10 天后自动清）'
  $specs += New-CandidateSpec 'C:\Windows\Logs' 'low' '系统日志'
  $specs += New-CandidateSpec 'C:\PerfLogs' 'low' '性能计数器日志'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Microsoft\Windows\INetCache') 'low' '系统/IE 网络缓存'
  $specs += New-CandidateSpec (Join-Local $env:APPDATA 'npm-cache') 'low' 'npm 包缓存'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'npm-cache') 'low' 'npm 包缓存'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'pip\Cache') 'low' 'pip 包缓存'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'pnpm\store') 'low' 'pnpm 内容仓库'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Yarn\Cache') 'low' 'Yarn 包缓存'
  $specs += New-CandidateSpec (Join-Local $env:APPDATA 'Code\Cache') 'low' 'VS Code 缓存'
  $specs += New-CandidateSpec (Join-Local $env:APPDATA 'Code\CachedData') 'low' 'VS Code 编译缓存'
  $specs += New-CandidateSpec (Join-Local $env:APPDATA 'Code\Code Cache') 'low' 'VS Code Code Cache'
  $specs += New-CandidateSpec (Join-Local $env:APPDATA 'Code\GPUCache') 'low' 'VS Code GPU 缓存'
  $specs += New-CandidateSpec (Join-Local $env:APPDATA 'Code\logs') 'low' 'VS Code 日志'
  $specs += New-CandidateSpec (Join-Local $env:APPDATA 'Code\User\workspaceStorage') 'medium' 'VS Code 工作区状态（丢了会重置窗口布局）'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Discord\Cache') 'low' 'Discord 缓存'
  $specs += New-CandidateSpec (Join-Local $env:APPDATA 'discord\Cache') 'low' 'Discord 缓存'
  foreach ($browser in @(
      @{ Root = (Join-Local $env:LOCALAPPDATA 'Google\Chrome\User Data'); Name = 'Chrome' },
      @{ Root = (Join-Local $env:LOCALAPPDATA 'Microsoft\Edge\User Data'); Name = 'Edge' },
      @{ Root = (Join-Local $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'); Name = 'Brave' }
    )) {
    if (-not $browser.Root -or -not (Test-Path -LiteralPath $browser.Root)) { continue }
    $profiles = @(Get-ChildItem -LiteralPath $browser.Root -Force -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
    foreach ($profile in $profiles) {
      foreach ($sub in @('Cache', 'Code Cache', 'GPUCache', 'Service Worker')) {
        $specs += New-CandidateSpec (Join-Path $profile.FullName $sub) 'low' "$($browser.Name) 缓存 ($($profile.Name))"
      }
    }
  }
  return @($specs | Where-Object { $_ })
}

function Get-DeepDiskCandidateSpecs {
  # Tier 2: heavier or rarer. Enable with -Deep.
  $specs = @()
  $specs += New-CandidateSpec (Join-Local $env:USERPROFILE '.gradle\caches') 'medium' 'Gradle 依赖缓存'
  $specs += New-CandidateSpec (Join-Local $env:USERPROFILE '.m2\repository') 'medium' 'Maven 本地仓库'
  $specs += New-CandidateSpec (Join-Local $env:USERPROFILE '.nuget\packages') 'medium' 'NuGet 全局包目录'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'NuGet\v3-cache') 'low' 'NuGet HTTP 缓存'
  $specs += New-CandidateSpec (Join-Local $env:USERPROFILE '.cache') 'medium' '通用缓存（可能含模型权重/数据集）'
  $specs += New-CandidateSpec (Join-Local $env:USERPROFILE '.ollama\models') 'medium' 'Ollama 模型（删后需重新下载）'
  $specs += New-CandidateSpec (Join-Local $env:USERPROFILE '.android\avd') 'medium' 'Android 模拟器镜像'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Android\Sdk') 'medium' 'Android SDK'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Docker') 'medium' 'Docker 本地数据'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Packages') 'medium' 'Store 应用数据（含 LocalCache）'
  $specs += New-CandidateSpec 'C:\ProgramData\Package Cache' 'medium' 'Visual Studio / VC++ 安装缓存'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'ms-playwright') 'medium' 'Playwright 浏览器二进制'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'JetBrains') 'medium' 'JetBrains 索引/旧版本缓存'
  $specs += New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Microsoft\VisualStudio') 'medium' 'Visual Studio 组件缓存'
  $specs += New-CandidateSpec (Join-Local $env:USERPROFILE '.cursor\extensions') 'medium' 'Cursor 扩展'
  return @($specs | Where-Object { $_ })
}

function Measure-CandidateSpecs([object[]]$Specs) {
  $out = New-Object System.Collections.ArrayList
  $seen = @{}
  foreach ($spec in @($Specs)) {
    if (-not $spec -or [string]::IsNullOrWhiteSpace($spec.Path)) { continue }
    $key = $spec.Path.TrimEnd('\').ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    if (Test-BudgetExpired) { $script:CandidateSkipped++; continue }
    $size = Get-FolderSize $spec.Path
    if (-not $size.Exists -or $size.Bytes -le 0) { continue }
    [void]$out.Add([pscustomobject]@{
        Path = $size.Path; Exists = $true; Bytes = $size.Bytes; Files = $size.Files
        Size = $size.Size; Scan = $size.Scan; Risk = $spec.Risk; Kind = $spec.Kind
      })
  }
  return @($out | Sort-Object Bytes -Descending)
}

function Measure-DiskCandidates {
  Start-SectionBudget $SectionBudgetSeconds
  $specs = @(Get-DiskCandidateSpecs)
  if ($Deep) { $specs = @($specs) + @(Get-DeepDiskCandidateSpecs) }
  $script:CandidateSkipped = 0
  $measured = @(Measure-CandidateSpecs $specs)
  Clear-SectionBudget
  return @($measured | Select-Object -First $Top)
}

function Show-DiskCandidates {
  $items = @(Measure-DiskCandidates)
  if ($items.Count -eq 0) {
    'No measurable temp/cache candidates found (or every candidate was empty).'
    return
  }
  Show-CandidateTable $items
  if ($script:CandidateSkipped -gt 0) {
    "Note: $($script:CandidateSkipped) candidate(s) were not measured within the ${SectionBudgetSeconds}s budget; rerun with -Deep or later."
  }
}

function Show-Memory {
  Get-Process |
    Sort-Object WorkingSet64 -Descending |
    Select-Object -First $Top ProcessName, Id,
      @{Name='Memory';Expression={Format-Bytes $_.WorkingSet64}},
      @{Name='CPU';Expression={[math]::Round($_.CPU, 1)}}
}

function Show-System {
  # Targeted CIM reads instead of Get-ComputerInfo, which alone cost ~8s.
  '=== Computer ==='
  $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
  $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
  $build = if ($cv.CurrentBuild -and $cv.UBR) { "$($cv.CurrentBuild).$($cv.UBR)" } else { [string]$os.BuildNumber }
  [pscustomobject]@{
    Name = $cs.Name
    Manufacturer = $cs.Manufacturer
    Model = $cs.Model
    OS = $os.Caption
    DisplayVersion = $cv.DisplayVersion
    Build = $build
    Architecture = $os.OSArchitecture
    CPU = $cpu.Name
    Cores = $cpu.NumberOfCores
    LogicalProcessors = $cpu.NumberOfLogicalProcessors
    TotalMemory = (Format-Bytes ([double]$cs.TotalPhysicalMemory))
  } | Format-List
  '=== BIOS ==='
  Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object Manufacturer, SMBIOSBIOSVersion, ReleaseDate | Format-List
  '=== Uptime ==='
  [pscustomobject]@{
    LastBoot = $os.LastBootUpTime
    UptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2)
  } | Format-List
}

function Get-SystemEventData([int]$Days = 7, [int]$Max = 30) {
  $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1,2; StartTime = (Get-Date).AddDays(-$Days) } -MaxEvents $Max -ErrorAction SilentlyContinue)
  $items = @()
  foreach ($event in $events) {
    $message = ([string]$event.Message -replace '\s+', ' ').Trim()
    if ($message.Length -gt 200) { $message = $message.Substring(0, 200) + '...' }
    $items += [pscustomobject]@{
      time = $event.TimeCreated.ToString('s')
      provider = $event.ProviderName
      id = $event.Id
      level = [string]$event.LevelDisplayName
      message = $message
    }
  }
  $groups = @($items | Group-Object { "$($_.provider) ($($_.id))" } |
    Sort-Object Count -Descending | Select-Object -First 8 |
    ForEach-Object { [pscustomobject]@{ group = $_.Name; count = $_.Count } })
  [pscustomobject]@{ days = $Days; count = $items.Count; events = $items; by_provider = $groups }
}

function Show-Events {
  # Full event messages used to produce 200+ lines and blow up the agent's
  # context; messages are collapsed to one line and capped.
  $data = Get-SystemEventData 7 30
  $capNote = if ($data.count -ge 30) { '+, capped - more may exist' } else { '' }
  "=== System critical/error events, last $($data.days) days (showing $($data.count)$capNote) ==="
  if ($data.count -eq 0) { 'None.'; return }
  foreach ($event in $data.events) {
    "$($event.time) | $($event.level) | $($event.provider) $($event.id)"
    "    $($event.message)"
  }
  '=== Most frequent (provider + event id) ==='
  $data.by_provider | ForEach-Object { [pscustomobject]@{ Group = $_.group; Count = $_.count } } | Format-Table -AutoSize
}

function Show-Startup {
  '=== Startup commands (Run keys / Startup folder) ==='
  $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue |
    Select-Object Name, Command, Location, User | Sort-Object Name)
  if ($startup.Count -eq 0) { 'None found.' } else { $startup | Format-List }
  '=== Enabled scheduled tasks (non-Microsoft) ==='
  $tasks = @(Get-ScheduledTaskInventory)
  if ($tasks.Count -eq 0) {
    'None found (or the ScheduledTasks module is unavailable).'
  } else {
    $tasks | ForEach-Object { [pscustomobject]@{ Name = $_.name; Path = $_.path; State = $_.state } } | Format-Table -AutoSize
  }
}

function Show-Services {
  '=== Non-running automatic services ==='
  $services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
    Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' } |
    Select-Object Name, DisplayName, State, StartMode, StartName | Sort-Object Name)
  if ($services.Count -eq 0) { 'None: every automatic service is running.' }
  else { $services | Format-Table -AutoSize }
}

function Show-Drivers {
  '=== Problem devices ==='
  $problems = @(Get-ProblemDevices)
  if ($problems.Count -eq 0) { 'None: Windows reports no problem devices.' }
  else { $problems | Select-Object Name, Manufacturer, PNPDeviceID, ConfigManagerErrorCode | Format-List }
  '=== Recently dated signed drivers (sample) ==='
  Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DriverDate } |
    Sort-Object DriverDate -Descending |
    Select-Object -First $Top DeviceName, Manufacturer, DriverVersion, DriverDate |
    Format-Table -AutoSize
}

function Show-Updates {
  '=== Recent hotfixes ==='
  $hotfixes = @(Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First $Top)
  if ($hotfixes.Count -eq 0) { 'None reported by Get-HotFix.' }
  else { $hotfixes | Select-Object HotFixID, Description, InstalledOn, InstalledBy | Format-Table -AutoSize }
  '=== Windows Update services ==='
  Get-Service -Name wuauserv, bits, cryptsvc, msiserver, TrustedInstaller -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType | Format-Table -AutoSize
  '=== Update state ==='
  [pscustomobject]@{
    PendingReboot = (Get-PendingReboot)
    LastHotfixAgeDays = $(if ($hotfixes.Count -gt 0 -and $hotfixes[0].InstalledOn) { [int][math]::Round(((Get-Date) - $hotfixes[0].InstalledOn).TotalDays) } else { $null })
    SoftwareDistributionDownloadBytes = (Get-FolderSize 'C:\Windows\SoftwareDistribution\Download').Bytes
  } | Format-List
}

function Show-Devices {
  '=== Problem devices ==='
  $problems = @(Get-ProblemDevices)
  if ($problems.Count -eq 0) { 'None: Windows reports no problem devices.' }
  else { $problems | Select-Object Name, Manufacturer, Service, ConfigManagerErrorCode | Format-Table -AutoSize }
  '=== USB devices ==='
  Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
    Where-Object { $_.PNPDeviceID -like 'USB*' } |
    Select-Object -First $Top Name, Status, Manufacturer |
    Format-Table -AutoSize
}

function Show-Power {
  '=== Battery ==='
  $battery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
  if ($battery.Count -eq 0) { 'No battery (desktop or battery not reported).' }
  else { $battery | Select-Object Name, BatteryStatus, EstimatedChargeRemaining, EstimatedRunTime | Format-List }
  '=== Power plan ==='
  $plan = (Get-NativeLines 'powercfg' @('/getactivescheme') 15 2) -join ' '
  $planNames = @{
    '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Balanced'
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'High performance'
    'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Power saver'
  }
  $guid = if ($plan -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $Matches[1].ToLowerInvariant() } else { $null }
  $planName = if ($guid -and $planNames.ContainsKey($guid)) { $planNames[$guid] } else { 'custom or unknown' }
  "Active plan: $planName ($guid)"
  '=== Sleep states ==='
  Get-NativeLines 'powercfg' @('/a') 20 12
}

function Show-Audio {
  '=== Audio devices ==='
  Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue | Select-Object Name, Manufacturer, Status | Format-Table -AutoSize
  '=== Audio services ==='
  Get-Service -Name Audiosrv, AudioEndpointBuilder -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType | Format-Table -AutoSize
}

function Show-Display {
  '=== Video controller ==='
  Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    Select-Object Name, DriverVersion, @{Name = 'AdapterRAM'; Expression = { Format-Bytes $_.AdapterRAM } }, VideoModeDescription |
    Format-List
  '=== Monitors ==='
  Get-CimInstance Win32_DesktopMonitor -ErrorAction SilentlyContinue | Select-Object Name, ScreenWidth, ScreenHeight, Status | Format-Table -AutoSize
}

function Show-Printer {
  '=== Printers ==='
  try {
    $printers = @(Get-Printer -ErrorAction Stop)
    if ($printers.Count -eq 0) { 'No printers installed.' }
    else { $printers | Select-Object Name, PrinterStatus, Default, DriverName, PortName | Format-Table -AutoSize }
  } catch { 'PrintManagement module unavailable; falling back to WMI.'
    Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Select-Object Name, PrinterStatus, Default, PortName | Format-Table -AutoSize
  }
  '=== Print spooler ==='
  Get-Service Spooler -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType | Format-Table -AutoSize
}

function Show-Security {
  $posture = Get-SecurityPosture
  $defender = Get-DefenderStatus
  '=== Defender status ==='
  if ($defender) {
    $defender | Select-Object AMRunningMode, AMServiceEnabled, AntivirusEnabled, RealTimeProtectionEnabled,
      AntispywareEnabled, NISEnabled, IsTamperProtected,
      @{ Name = 'QuickScanAge'; Expression = { Format-ScanAge $_.QuickScanAge } },
      @{ Name = 'FullScanAge'; Expression = { Format-ScanAge $_.FullScanAge } } | Format-List
  } else {
    'Defender status unavailable (no Defender, or the cmdlet is blocked by policy).'
  }
  '=== Registered antivirus products (SecurityCenter2) ==='
  $products = @(Get-AntivirusProducts)
  if ($products.Count -eq 0) {
    'None reported (SecurityCenter2 returned no AV product).'
  } else {
    $products | Select-Object name, state | Format-Table -AutoSize
  }
  "Verdict: $($posture.verdict)"
  '=== Firewall profiles ==='
  try {
    Get-NetFirewallProfile -ErrorAction Stop | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction | Format-Table -AutoSize
  } catch { 'Get-NetFirewallProfile unavailable.' }
}

function Show-RepairCheck {
  '=== Repair check commands (all read-only; nothing below is executed) ==='
  'Run in an elevated PowerShell for deeper checks:'
  'sfc /verifyonly'
  'DISM /Online /Cleanup-Image /CheckHealth'
  'DISM /Online /Cleanup-Image /ScanHealth'
  'DISM /Online /Cleanup-Image /AnalyzeComponentStore   (read-only; reports WinSxS reclaimable space)'
  'Use /RestoreHealth or StartComponentCleanup only after explaining that they modify component store state.'
  '=== Component store size (needs admin; shown as unavailable otherwise) ==='
  $winsxs = Get-FolderSize (Join-Path $env:SystemRoot 'WinSxS') 8
  [pscustomobject]@{ Path = $winsxs.Path; Size = $winsxs.Size; Files = $winsxs.Files; Scan = $winsxs.Scan } | Format-List
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
  '=== Chromium browser processes (Chrome/Edge/Brave) ==='
  $processes = @(Show-ProcessGroup 'chrome|msedge|brave')
  if ($processes.Count -eq 0) { 'No Chromium browser process is running.' }
  else { $processes | Format-Table -AutoSize }
  '=== Chromium cache candidates (every profile, not just Default) ==='
  $specs = @(Get-DiskCandidateSpecs | Where-Object { $_.Kind -match 'Chrome|Edge|Brave' })
  if ($specs.Count -eq 0) { 'No Chrome/Edge/Brave profile directories found.'; return }
  Start-SectionBudget $SectionBudgetSeconds
  $measured = @(Measure-CandidateSpecs $specs)
  Clear-SectionBudget
  if ($measured.Count -eq 0) { 'Every Chromium cache folder is empty.' }
  else { Show-CandidateTable $measured }
  'Note: close the browser before clearing caches; never delete Cookies, Login Data, or History unless the user explicitly asks.'
}

function Show-VSCode {
  '=== VS Code processes ==='
  $processes = @(Show-ProcessGroup 'Code')
  if ($processes.Count -eq 0) { 'VS Code is not running.' } else { $processes | Format-Table -AutoSize }
  '=== VS Code cache candidates ==='
  $specs = @(Get-DiskCandidateSpecs | Where-Object { $_.Kind -like 'VS Code*' })
  Start-SectionBudget $SectionBudgetSeconds
  $measured = @(Measure-CandidateSpecs $specs)
  Clear-SectionBudget
  if ($measured.Count -eq 0) { 'No VS Code cache folders found.' }
  else { Show-CandidateTable $measured }
  $ext = Join-Local $env:USERPROFILE '.vscode\extensions'
  if (Test-Path -LiteralPath $ext) {
    '=== VS Code extensions ==='
    $extSize = Get-FolderSize $ext 8
    "extensions total: $($extSize.Size) across $($extSize.Files) files ($($extSize.Scan))"
    Show-FolderSizeTable (Get-ChildFolderSizes $ext $Top 3)
  }
  'Note: stop VS Code before clearing caches; never touch User settings, keybindings, snippets, or the extension list.'
}

function Get-ToolProbe([string]$Label, [string]$Exe, [string[]]$ArgList, [int]$TimeoutSeconds = 0) {
  # The parameter must not be named $Args: that is a PowerShell automatic
  # variable, and binding it silently dropped every argument (the 0.2.3 bug that
  # made `git` print its usage text instead of its version).
  $r = Invoke-NativeText $Exe $ArgList $TimeoutSeconds
  if ($r.missing) {
    return [pscustomobject]@{ Tool = $Label; Command = $Exe; Status = 'missing'; Detail = 'not found on PATH'; Path = $null }
  }
  if ($r.script_only) {
    return [pscustomobject]@{ Tool = $Label; Command = $Exe; Status = 'script-only'; Detail = $r.stderr; Path = $null }
  }
  $detail = @(($r.stdout + "`n" + $r.stderr) -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 2) -join ' | '
  if (-not $detail) { $detail = "exited with code $($r.exit_code) and no output" }
  if ($detail.Length -gt 110) { $detail = $detail.Substring(0, 110) + '...' }
  $status = if ($r.timed_out) { 'timeout' } elseif ($r.exit_code -ne 0) { 'error' } else { 'ok' }
  return [pscustomobject]@{ Tool = $Label; Command = "$Exe $($ArgList -join ' ')"; Status = $status; Detail = $detail; Path = $r.resolved_path }
}

function Get-DevToolProbes {
  return @(
    Get-ToolProbe 'node' 'node' @('--version')
    Get-ToolProbe 'npm' 'npm' @('--version')
    Get-ToolProbe 'python' 'python' @('--version')
    Get-ToolProbe 'pip' 'pip' @('--version')
    Get-ToolProbe 'git' 'git' @('--version')
    Get-ToolProbe 'java' 'java' @('-version')
    Get-ToolProbe 'adb' 'adb' @('version')
    Get-ToolProbe 'flutter' 'flutter' @('--version') 90
    Get-ToolProbe 'docker' 'docker' @('--version')
    Get-ToolProbe 'wsl' 'wsl' @('--version') 30
    [pscustomobject]@{ Tool = 'ANDROID_HOME'; Command = '$env:ANDROID_HOME'; Status = $(if ($env:ANDROID_HOME) { 'ok' } else { 'missing' }); Detail = [string]$env:ANDROID_HOME; Path = $null }
    [pscustomobject]@{ Tool = 'ANDROID_SDK_ROOT'; Command = '$env:ANDROID_SDK_ROOT'; Status = $(if ($env:ANDROID_SDK_ROOT) { 'ok' } else { 'missing' }); Detail = [string]$env:ANDROID_SDK_ROOT; Path = $null }
  )
}

function Get-ReadinessVerdict([object[]]$Probes) {
  $missing = @($Probes | Where-Object { $_.Status -eq 'missing' } | ForEach-Object { $_.Tool })
  $broken = @($Probes | Where-Object { $_.Status -in @('error', 'timeout', 'script-only') } | ForEach-Object { $_.Tool })
  $total = @($Probes).Count
  $verdict = if ($missing.Count -eq 0 -and $broken.Count -eq 0) { 'ready' }
    elseif (($missing.Count + $broken.Count) -eq $total) { 'blocked' }
    else { 'partial' }
  [pscustomobject]@{ verdict = $verdict; missing = $missing; broken = $broken; total = $total }
}

function Show-DevTools {
  $probes = @(Get-DevToolProbes)
  $probes | ForEach-Object { [pscustomobject]@{ Tool = $_.Tool; Status = $_.Status; Detail = $_.Detail } } | Format-Table -AutoSize
  $readiness = Get-ReadinessVerdict $probes
  "Readiness: $($readiness.verdict)"
  if ($readiness.missing.Count -gt 0) { "Missing: $($readiness.missing -join ', ')" }
  if ($readiness.broken.Count -gt 0) { "Present but not working: $($readiness.broken -join ', ') (see Detail)" }
}

function Show-Android {
  $probes = @(Get-DevToolProbes | Where-Object { $_.Tool -match 'java|adb|flutter|ANDROID|wsl' })
  $probes | ForEach-Object { [pscustomobject]@{ Tool = $_.Tool; Status = $_.Status; Detail = $_.Detail; Path = $_.Path } } | Format-List
  $readiness = Get-ReadinessVerdict $probes
  "Readiness: $($readiness.verdict)"
  if ($readiness.missing.Count -gt 0) { "Missing: $($readiness.missing -join ', ')" }
  if ($readiness.broken.Count -gt 0) { "Present but not working: $($readiness.broken -join ', ') (see Detail)" }
  if (Get-Command adb -ErrorAction SilentlyContinue) {
    '=== adb devices ==='
    Get-NativeLines 'adb' @('devices') 20 6
  }
  '=== Android disk candidates ==='
  $specs = @(
    (New-CandidateSpec $env:ANDROID_HOME 'medium' 'Android SDK (ANDROID_HOME)')
    (New-CandidateSpec $env:ANDROID_SDK_ROOT 'medium' 'Android SDK (ANDROID_SDK_ROOT)')
    (New-CandidateSpec (Join-Local $env:USERPROFILE '.android\avd') 'medium' 'Android 模拟器镜像')
    (New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Android\Sdk') 'medium' 'Android SDK')
  ) | Where-Object { $_ }
  Start-SectionBudget $SectionBudgetSeconds
  $measured = @(Measure-CandidateSpecs $specs)
  Clear-SectionBudget
  if ($measured.Count -eq 0) { 'No Android SDK/AVD folders found.' }
  else { Show-CandidateTable $measured }
}

function Get-ProxyData {
  $inet = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
  $winhttp = (Get-NativeLines 'netsh' @('winhttp', 'show', 'proxy') 15 8) -join ' | '
  [pscustomobject]@{
    env_http = Redact-SensitiveText $env:HTTP_PROXY
    env_https = Redact-SensitiveText $env:HTTPS_PROXY
    env_all = Redact-SensitiveText $env:ALL_PROXY
    env_no_proxy = Redact-SensitiveText $env:NO_PROXY
    wininet_enabled = if ($null -ne $inet.ProxyEnable) { [bool]$inet.ProxyEnable } else { $null }
    wininet_server = Redact-SensitiveText $inet.ProxyServer
    wininet_override = Redact-SensitiveText $inet.ProxyOverride
    wininet_pac = Redact-SensitiveText $inet.AutoConfigURL
    winhttp = $winhttp
  }
}

function Show-Network {
  # WinHTTP (netsh) and WinINET (what browsers/apps actually use) are different
  # proxies; reporting only netsh hid the system proxy users normally set.
  $p = Get-ProxyData
  [pscustomobject]@{
    'env HTTP_PROXY' = $p.env_http
    'env HTTPS_PROXY' = $p.env_https
    'env ALL_PROXY' = $p.env_all
    'env NO_PROXY' = $p.env_no_proxy
    'WinINET ProxyEnable' = $p.wininet_enabled
    'WinINET ProxyServer' = $p.wininet_server
    'WinINET ProxyOverride' = $p.wininet_override
    'WinINET AutoConfigURL' = $p.wininet_pac
  } | Format-List
  '=== WinHTTP proxy (netsh) ==='
  $p.winhttp
  '=== DNS servers ==='
  try {
    Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
      Where-Object { $_.ServerAddresses } |
      Select-Object InterfaceAlias, @{Name = 'Servers'; Expression = { $_.ServerAddresses -join ', ' } } |
      Format-Table -AutoSize
  } catch { 'Get-DnsClientServerAddress unavailable.' }
}

function Test-NetworkTarget([string]$TargetValue) {
  if ([string]::IsNullOrWhiteSpace($TargetValue)) { $TargetValue = 'https://www.microsoft.com' }
  $uri = $null
  try { $uri = [Uri]$TargetValue } catch { $uri = $null }
  if (-not $uri -or -not $uri.IsAbsoluteUri -or -not $uri.Host) { $uri = [Uri]("https://" + $TargetValue) }
  $hostName = $uri.Host
  '=== Proxy state ==='
  Show-Network
  '=== DNS ==='
  $dns = @(Resolve-DnsName $hostName -ErrorAction SilentlyContinue | Select-Object -First 4)
  if ($dns.Count -eq 0) { "No DNS record resolved for $hostName." }
  else { $dns | Select-Object Name, Type, IPAddress | Format-Table -AutoSize }
  '=== HTTP test ==='
  "Target: $(Redact-SensitiveText $uri.AbsoluteUri)"
  $head = Invoke-NativeText 'curl.exe' @('-sS', '-I', '--connect-timeout', '10', '--max-time', '20', $uri.AbsoluteUri) 25
  $raw = ($head.stdout + "`n" + $head.stderr)
  $statusLine = @($raw -split "`r?`n" | Where-Object { $_ -match '^HTTP/' } | Select-Object -First 1)
  $code = $null
  if ($statusLine.Count -gt 0 -and $statusLine[0] -match 'HTTP/\S+\s+(\d{3})') { $code = [int]$Matches[1] }
  $classification = 'unknown'
  if ($head.missing) { $classification = 'curl-missing' }
  elseif ($head.timed_out) { $classification = 'timeout' }
  elseif ($dns.Count -eq 0) { $classification = 'dns-failure' }
  elseif ($null -ne $code -and $code -ge 500) { $classification = 'remote-5xx' }
  elseif ($null -ne $code -and $code -ge 400) { $classification = 'client-4xx' }
  elseif ($null -ne $code -and $code -ge 200) { $classification = 'ok' }
  elseif ($raw -match '(?i)could not resolve|name or service not known|getaddrinfo') { $classification = 'dns-failure' }
  elseif ($raw -match '(?i)ssl|certificate|schannel|tls') { $classification = 'tls-failure' }
  elseif ($raw -match '(?i)proxy|CONNECT') { $classification = 'proxy-issue' }
  elseif ($raw -match '(?i)connection refused|failed to connect') { $classification = 'connect-failure' }
  "Classification: $classification"
  if ($statusLine.Count -gt 0) { $statusLine[0] }
  @($raw -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 12)
  if ($null -ne $code -and $code -eq 405) {
    '=== Server rejected HEAD; retrying with a ranged GET ==='
    $get = Invoke-NativeText 'curl.exe' @('-sS', '-o', 'NUL', '-w', '%{http_code}', '--connect-timeout', '10', '--max-time', '20', $uri.AbsoluteUri) 25
    "GET status: $(($get.stdout).Trim())"
  }
}

function Show-WeChat {
  '=== WeChat candidate folders ==='
  $specs = @(
    (New-CandidateSpec (Join-Local $env:USERPROFILE 'Documents\WeChat Files') 'high' '微信旧版数据（含接收文件）')
    (New-CandidateSpec (Join-Local $env:USERPROFILE 'Documents\xwechat_files') 'high' '微信 4.x 数据（含接收文件）')
    (New-CandidateSpec (Join-Local $env:APPDATA 'Tencent\WeChat') 'medium' '微信配置/缓存')
    (New-CandidateSpec (Join-Local $env:APPDATA 'Tencent\xwechat') 'medium' '微信 4.x 配置/缓存')
    (New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Tencent\WeChat') 'medium' '微信本地缓存')
  ) | Where-Object { $_ }
  Start-SectionBudget $SectionBudgetSeconds
  $measured = @(Measure-CandidateSpecs $specs)
  Clear-SectionBudget
  if ($measured.Count -eq 0) { 'No WeChat folders found in the standard locations.' }
  else { Show-CandidateTable $measured }
  'Note: received files and chat history are user data. Never bulk-delete; split cache from received files and ask for path-level approval.'
}

function Show-App([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name)) {
    'ProcessName is required for -Mode app. Example: -Mode app -ProcessName chrome'
    return
  }
  $safeName = [regex]::Escape($Name)
  '=== Matching processes ==='
  $processes = @(Show-ProcessGroup $safeName)
  if ($processes.Count -eq 0) { "No running process matches '$Name'." }
  else { $processes | Format-Table -AutoSize }
  '=== Recent application errors (last 7 days) ==='
  $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1,2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 80 -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match $safeName -or $_.Message -match $safeName } |
    Select-Object -First 15)
  if ($events.Count -eq 0) { "No application events matched '$Name'." }
  else {
    foreach ($event in $events) {
      $message = ([string]$event.Message -replace '\s+', ' ').Trim()
      if ($message.Length -gt 200) { $message = $message.Substring(0, 200) + '...' }
      "$($event.TimeCreated.ToString('s')) | $($event.LevelDisplayName) | $($event.ProviderName) $($event.Id)"
      "    $message"
    }
  }
}

function Get-WslOutput([string[]]$WslArgs, [int]$TimeoutSeconds = 30) {
  # wsl.exe encoding differs by build (UTF-16LE for the inbox wsl.exe, UTF-8 for
  # the Store build); Invoke-NativeText sniffs it instead of guessing. This also
  # removes the old temp-file dance, so the script writes nothing outside
  # ~\.winfix\baselines\ plus its own self-test sandbox.
  $r = Invoke-NativeText 'wsl.exe' $WslArgs $TimeoutSeconds
  if ($r.missing) { return 'wsl.exe is not available.' }
  if ($r.timed_out) { return "wsl.exe timed out after ${TimeoutSeconds}s (WSL may be hung; try 'wsl --shutdown')." }
  $text = ($r.stdout.Trim() + "`n" + $r.stderr.Trim()).Trim()
  if (-not $text) { return 'wsl.exe returned no output.' }
  return $text
}

function Get-WslDistros {
  # The registry is authoritative: distros imported to a custom BasePath (e.g.
  # D:\WSL\Ubuntu) are invisible to a Packages-only filesystem scan, which made
  # 0.2.3 report "no vhdx found" on machines that had several GB of them.
  $distros = @()
  $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
  if (Test-Path $root) {
    foreach ($key in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
      $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
      if (-not $props.DistributionName) { continue }
      $basePath = [string]$props.BasePath
      $vhdPath = $null
      $bytes = [int64]0
      if ($basePath) {
        foreach ($relative in @('ext4.vhdx', 'disk\ext4.vhdx')) {
          $candidate = Join-Path $basePath $relative
          if (Test-Path -LiteralPath $candidate) {
            $vhdPath = $candidate
            $bytes = [int64](Get-Item -LiteralPath $candidate).Length
            break
          }
        }
      }
      $size = if ($bytes -gt 0) { Format-Bytes $bytes } else { 'not found' }
      $distros += [pscustomobject]@{
        name = [string]$props.DistributionName
        wsl_version = $props.Version
        base_path = $basePath
        vhdx = $vhdPath
        vhdx_bytes = $bytes
        vhdx_size = $size
        source = 'registry'
      }
    }
  }
  return @($distros)
}

function Get-VhdxFiles {
  # Bounded wildcard lookups (no deep recursion) for WSL and Docker virtual
  # disks that the registry does not mention.
  $patterns = @(
    (Join-Path $env:LOCALAPPDATA 'wsl\*\ext4.vhdx'),
    (Join-Path $env:LOCALAPPDATA 'wsl\*\disk\*.vhdx'),
    (Join-Path $env:LOCALAPPDATA 'Packages\*\LocalState\ext4.vhdx'),
    (Join-Path $env:LOCALAPPDATA 'Docker\wsl\data\ext4.vhdx'),
    (Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx'),
    (Join-Path $env:LOCALAPPDATA 'DockerDesktopWSL\data\ext4.vhdx'),
    (Join-Path $env:LOCALAPPDATA 'DockerDesktopWSL\disk\docker_data.vhdx')
  )
  $found = @()
  foreach ($pattern in $patterns) {
    foreach ($item in @(Get-Item -Path $pattern -Force -ErrorAction SilentlyContinue)) {
      $found += [pscustomobject]@{ path = $item.FullName; bytes = [int64]$item.Length; modified = $item.LastWriteTime.ToString('yyyy-MM-dd') }
    }
  }
  return @($found | Sort-Object bytes -Descending)
}

function Get-WslData {
  $distros = @(Get-WslDistros)
  $files = @(Get-VhdxFiles)
  $knownPaths = @($distros | Where-Object { $_.vhdx } | ForEach-Object { $_.vhdx.ToLowerInvariant() })
  $extra = @($files | Where-Object { $knownPaths -notcontains $_.path.ToLowerInvariant() })
  $totalBytes = [int64]0
  foreach ($d in $distros) { $totalBytes += [int64]$d.vhdx_bytes }
  foreach ($f in $extra) { $totalBytes += [int64]$f.bytes }
  [pscustomobject]@{
    distros = $distros
    extra_vhdx = $extra
    total_vhdx_bytes = $totalBytes
    total_vhdx_size = (Format-Bytes $totalBytes)
  }
}

function Show-WSL {
  '=== WSL status ==='
  Get-WslOutput @('--status')
  '=== WSL distros ==='
  Get-WslOutput @('-l', '-v')
  '=== WSL/Docker virtual disks (vhdx) ==='
  $data = Get-WslData
  $withVhd = @($data.distros | Where-Object { $_.vhdx })
  if ($withVhd.Count -eq 0 -and $data.extra_vhdx.Count -eq 0) {
    'No WSL/Docker vhdx virtual disks found.'
  } else {
    $withVhd | Sort-Object vhdx_bytes -Descending | ForEach-Object {
      [pscustomobject]@{ Distro = $_.name; Version = $_.wsl_version; Size = $_.vhdx_size; Path = $_.vhdx }
    } | Format-Table -AutoSize
    foreach ($extra in $data.extra_vhdx) {
      [pscustomobject]@{ File = $extra.path; Size = (Format-Bytes $extra.bytes); Modified = $extra.modified } | Format-List
    }
    "Total virtual disk size: $($data.total_vhdx_size)"
    'Note: vhdx files only grow. To reclaim space: wsl --shutdown, then either'
    '  wsl --manage <distro> --set-sparse true            (modern WSL; keeps it sparse)'
    '  diskpart: select vdisk file="<path>" + attach vdisk readonly + compact vdisk'
    '  Optimize-VHD -Path <path> -Mode Full               (admin PowerShell + Hyper-V module)'
    'Back up the distro first (wsl --export). Never delete a vhdx to "free space".'
  }
  $withoutVhd = @($data.distros | Where-Object { -not $_.vhdx })
  if ($withoutVhd.Count -gt 0) {
    '=== Distros whose vhdx was not found ==='
    $withoutVhd | ForEach-Object { [pscustomobject]@{ Distro = $_.name; BasePath = $_.base_path } } | Format-Table -AutoSize
  }
  '=== WSL/Docker local candidates ==='
  $specs = @(
    (New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Packages') 'medium' 'Store 应用数据（含 WSL 旧布局）')
    (New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'wsl') 'medium' '新版 WSL 发行版目录')
    (New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Docker') 'medium' 'Docker 本地数据')
    (New-CandidateSpec (Join-Path $env:APPDATA 'Docker') 'medium' 'Docker 配置')
  ) | Where-Object { $_ }
  Start-SectionBudget $SectionBudgetSeconds
  $measured = @(Measure-CandidateSpecs $specs)
  Clear-SectionBudget
  if ($measured.Count -eq 0) { 'None found.' }
  else { Show-CandidateTable $measured }
}

function Show-Docker {
  '=== Docker command ==='
  $version = Invoke-NativeText 'docker' @('--version') 20
  if ($version.missing) { 'docker is not installed or not on PATH.' }
  elseif ($version.script_only) { $version.stderr }
  else { @(($version.stdout + "`n" + $version.stderr) -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 2) }
  '=== Docker disk usage (needs the daemon) ==='
  $df = Invoke-NativeText 'docker' @('system', 'df') 45
  if ($df.missing) { 'docker is not installed or not on PATH.' }
  elseif ($df.timed_out) { 'docker system df timed out; the Docker daemon is probably not running.' }
  else { @(($df.stdout + "`n" + $df.stderr) -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 12) }
  '=== Docker local candidates ==='
  $specs = @(
    (New-CandidateSpec (Join-Local $env:LOCALAPPDATA 'Docker') 'medium' 'Docker 本地数据')
    (New-CandidateSpec (Join-Path $env:APPDATA 'Docker') 'medium' 'Docker 配置')
    (New-CandidateSpec (Join-Local $env:PROGRAMDATA 'Docker') 'medium' 'Docker 全局数据')
  ) | Where-Object { $_ }
  Start-SectionBudget $SectionBudgetSeconds
  $measured = @(Measure-CandidateSpecs $specs)
  Clear-SectionBudget
  if ($measured.Count -eq 0) { 'None found.' }
  else { Show-CandidateTable $measured }
  'Note: volumes can contain databases and project state; never prune volumes without explicit confirmation.'
}

function Show-SystemBreakdown {
  # The largest space consumers on a full drive are usually system-level
  # (Windows, Program Files, pagefile/hiberfil) and invisible to the
  # user-profile scans; this makes them visible with honest sampled sizes.
  $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
  $root = $sysDrive + [System.IO.Path]::DirectorySeparatorChar
  "=== System root breakdown ($root, time-budgeted) ==="
  Show-FolderSizeTable (Get-ChildFolderSizes $root $Top)
  '=== Memory-managed files ==='
  Get-ChildItem $root -Force -File -ErrorAction SilentlyContinue |
    Where-Object { @('pagefile.sys', 'hiberfil.sys', 'swapfile.sys') -contains $_.Name } |
    ForEach-Object { [pscustomobject]@{ File = $_.Name; Size = (Format-Bytes $_.Length) } } |
    Format-Table -AutoSize
  'Note: pagefile/hiberfil/swapfile are managed by Windows (virtual memory,'
  'fast startup, hibernation). Resize via system settings; never delete.'
  'Note: each folder is capped at 20000 files and 6s, so a row marked'
  'sampled/partial is a floor, not an exact total.'
}

function Show-LargeUserFolders {
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  Start-SectionBudget $SectionBudgetSeconds
  if ($Path) {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) { "Path not found: $Path"; Clear-SectionBudget; return }
    "=== Top folders under $($resolved.Path) ==="
    Show-FolderSizeTable (Get-ChildFolderSizes $resolved.Path $Top)
  } else {
    '=== Top user profile folders ==='
    Show-FolderSizeTable (Get-ChildFolderSizes $env:USERPROFILE $Top)
    '=== Top LocalAppData folders ==='
    Show-FolderSizeTable (Get-ChildFolderSizes $env:LOCALAPPDATA $Top)
    Show-SystemBreakdown
  }
  Clear-SectionBudget
  $watch.Stop()
  Write-Diag ("scan finished in {0:N1}s" -f $watch.Elapsed.TotalSeconds)
}

function Show-LargeFiles {
  $root = if ($Path) { (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path } else { $env:USERPROFILE }
  if (-not $root) { "Path not found: $Path"; return }
  $threshold = [int64]$MinSizeMB * 1MB
  "=== Largest files under $root (>= $MinSizeMB MB, time-budgeted) ==="
  Start-SectionBudget $SectionBudgetSeconds
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $found = New-Object System.Collections.ArrayList
  $stack = New-Object System.Collections.Stack
  $stack.Push($root)
  $scanned = 0
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    foreach ($entry in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
      if ($entry.PSIsContainer) {
        if (-not ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($entry.FullName) }
        continue
      }
      $scanned++
      if ($entry.Length -ge $threshold) {
        [void]$found.Add([pscustomobject]@{ Path = $entry.FullName; Bytes = [int64]$entry.Length; Modified = $entry.LastWriteTime.ToString('yyyy-MM-dd') })
      }
    }
    if (Test-BudgetExpired) { break }
  }
  $partial = Test-BudgetExpired
  Clear-SectionBudget
  $watch.Stop()
  if ($found.Count -eq 0) {
    if ($partial) {
      "No file >= $MinSizeMB MB found in the part that was scanned ($scanned files); the scan hit the $SectionBudgetSeconds s budget, so this is not a verdict on the whole tree."
    } else {
      "No file >= $MinSizeMB MB found (scanned $scanned files)."
    }
  } else {
    $found | Sort-Object Bytes -Descending | Select-Object -First $Top | ForEach-Object {
      [pscustomobject]@{ Size = (Format-Bytes $_.Bytes); Modified = $_.Modified; Path = $_.Path }
    } | Format-Table -AutoSize
  }
  if ($partial) {
    # Individual sizes are exact, but the *list* is a floor: the walk stopped
    # early, so larger files may exist further down. Same discipline as the
    # full/sampled/partial labels on folder sizes.
    "partial: the $SectionBudgetSeconds s budget stopped the scan after $scanned files, so this list is a floor. Narrow it with -Path <folder>, or raise -MinSizeMB."
  }
  Write-Diag ("scanned {0} files in {1:N1}s" -f $scanned, $watch.Elapsed.TotalSeconds)
}

function Show-Smart {
  '=== Physical disks ==='
  $health = Get-DiskHealthData
  if ($health.unavailable) { 'Storage module unavailable; see the Win32_DiskDrive fallback below.' }
  else {
    $health.disks | ForEach-Object {
      [pscustomobject]@{ Disk = $_.name; Media = $_.media; Bus = $_.bus; Health = $_.health; Status = $_.operational; Size = (Format-Bytes $_.size_bytes) }
    } | Format-Table -AutoSize
  }
  '=== Volumes ==='
  try {
    Get-Volume -ErrorAction Stop | Select-Object DriveLetter, FileSystemLabel, FileSystem, HealthStatus,
      @{Name = 'Free'; Expression = { Format-Bytes $_.SizeRemaining } }, @{Name = 'Size'; Expression = { Format-Bytes $_.Size } } |
      Format-Table -AutoSize
  } catch { 'Get-Volume unavailable.' }
  '=== Win32_DiskDrive (always available) ==='
  Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | Select-Object Model, Status, InterfaceType, Partitions,
    @{Name = 'Size'; Expression = { Format-Bytes $_.Size } } | Format-Table -AutoSize
  '=== SMART reliability counters ==='
  $counters = $null
  try { $counters = @(Get-PhysicalDisk -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop) } catch { $counters = $null }
  if ($null -eq $counters -or $counters.Count -eq 0) {
    'Not available without an elevated PowerShell (or this drive reports no counters).'
    'Admin PowerShell: Get-PhysicalDisk | Get-StorageReliabilityCounter | Select DeviceId,Temperature,Wear,ReadErrorsTotal,WriteErrorsTotal,PowerOnHours'
  } else {
    $counters | Select-Object DeviceId, Temperature, Wear, ReadErrorsTotal, WriteErrorsTotal, PowerOnHours | Format-Table -AutoSize
  }
  '=== Verdict ==='
  if ($health.unhealthy.Count -gt 0) {
    'At least one disk reports a non-Healthy state. Back up important data before attempting any repair.'
  } else {
    'No disk reports a non-Healthy state from the data Windows exposes without elevation.'
  }
  'Note: SMART counters need an elevated shell; a clean read-only verdict is not proof that the disk is fine.'
}

function Show-ResourcesRoute {
  # Covers both "内存占用高" and "笔记本发烫 / 风扇一直响": the first thing to
  # check in either case is which process is actually burning the machine.
  $memory = Get-MemoryData
  [pscustomobject]@{
    Total = (Format-Bytes $memory.total_bytes)
    Free = (Format-Bytes $memory.free_bytes)
    UsedPercent = $memory.used_percent
  } | Format-List
  '=== Top processes by memory ==='
  Show-Memory | Format-Table -AutoSize
  '=== Top processes by CPU time ==='
  Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CPU -gt 0 } |
    Sort-Object CPU -Descending |
    Select-Object -First 10 ProcessName, Id,
      @{Name = 'CPUSeconds'; Expression = { [math]::Round($_.CPU, 1) } },
      @{Name = 'Memory'; Expression = { Format-Bytes $_.WorkingSet64 } } |
    Format-Table -AutoSize
  'Note: CPU/GPU temperature and fan speed are not exposed by Windows without'
  'vendor tools; if one process above dominates, that is usually the cause.'
}

function Show-BaselineHint {
  $newest = Get-NewestBaselineFile
  if (-not $newest) {
    'No baseline exists yet. Run -Mode baseline now, then -Mode compare later.'
  } else {
    "Newest baseline: $($newest.FullName)"
    'Run -Mode compare to diff the current state against it.'
  }
}

function Show-DiskRoute {
  Show-Drives | Format-Table -AutoSize
  Show-DiskCandidates
  '=== Next step ==='
  'Run -Mode large (optionally -Mode large -Path <dir>) for big folders, or -Mode files for big files.'
}

function Show-CompareText([object]$diff) {
  "Baseline: $($diff.baseline_at)   Now: $($diff.now_at)   (baseline schema v$($diff.baseline_version))"
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
  if ($diff.scheduled_tracked) {
    '=== Scheduled tasks ==='
    "added: $(@($diff.scheduled_added).Count)   removed: $(@($diff.scheduled_removed).Count)"
    foreach ($item in $diff.scheduled_added) { "  + $item" }
    foreach ($item in $diff.scheduled_removed) { "  - $item" }
  } else {
    'Scheduled tasks: this baseline predates scheduled-task tracking; re-run -Mode baseline to include them.'
  }
  "Auto-start-but-stopped services: $($diff.auto_stopped_services_before) -> $($diff.auto_stopped_services_now)"
  "Pending reboot: $($diff.pending_reboot)"
}

function Show-CompareHint {
  $newest = Get-NewestBaselineFile
  if (-not $newest) {
    'No baseline exists, so a before/after comparison is impossible right now.'
    'Run -Mode baseline to snapshot the current state, then compare again in a few days.'
    Show-ResourcesRoute
    return
  }
  $diff = Compare-WithBaseline
  if ($null -eq $diff) { 'A baseline file exists but could not be read; run -Mode baseline again.'; return }
  Show-CompareText $diff
}

function Get-IssueRouteTable {
  # Ordered from most specific to most general. Every keyword must be a
  # multi-character phrase: single-character matching in 0.2.3 routed
  # "电脑最近变卡了" to the battery check because that text contains 电.
  @(
    [pscustomobject]@{ name = 'baseline'; keywords = @('baseline', '快照', '保存状态', '保存一下', '保存当前', '电脑状态', '存一份', '记录当前', '对比'); render = { Show-BaselineHint } }
    [pscustomobject]@{ name = 'vscode'; keywords = @('vscode', 'vs code', 'code.exe', 'webview', '插件', '扩展'); render = { Show-VSCode } }
    [pscustomobject]@{ name = 'chrome'; keywords = @('chrome', 'edge', 'browser', '浏览器', '标签页', '网页'); render = { Show-Chrome } }
    [pscustomobject]@{ name = 'resources'; keywords = @('内存', '占用高', '占用很高', '内存不足', '内存泄漏', '发烫', '风扇', '过热', '很热', '温度高'); render = { Show-ResourcesRoute } }
    [pscustomobject]@{ name = 'wechat'; keywords = @('wechat', '微信', '企业微信'); render = { Show-WeChat } }
    [pscustomobject]@{ name = 'android'; keywords = @('android', '安卓', 'adb', 'flutter', '模拟器', 'gradle', 'jdk'); render = { Show-Android } }
    [pscustomobject]@{ name = 'wsl'; keywords = @('wsl', 'ubuntu', 'linux', '子系统', '发行版'); render = { Show-WSL } }
    [pscustomobject]@{ name = 'docker'; keywords = @('docker', '容器', '镜像', 'volume'); render = { Show-Docker } }
    [pscustomobject]@{ name = 'smart'; keywords = @('硬盘健康', 'smart', '坏道', '硬盘坏', '磁盘坏', '要坏', '硬盘有问题', '硬盘异响', '健康度', '磁盘检测'); render = { Show-Smart } }
    [pscustomobject]@{ name = 'network'; keywords = @('proxy', '代理', 'vpn', '网络', '网址', '网站', '连不上网', '无法访问', '访问不了', 'dns', '网速', '超时'); render = { Show-Network } }
    [pscustomobject]@{ name = 'disk'; keywords = @('disk', '空间', '清理', '缓存', '大文件', '盘满', '满了', '回收站', '垃圾', 'c盘', 'd盘', '瘦身'); render = { Show-DiskRoute } }
    [pscustomobject]@{ name = 'crash'; keywords = @('bsod', '蓝屏', '崩溃', '闪退', '自动重启', '卡死', '死机', 'kernel-power', '事件日志'); render = { Show-Events } }
    [pscustomobject]@{ name = 'slow'; keywords = @('变卡', '卡顿', '很卡', '好卡', '变慢', '慢了', '不流畅', '掉帧', '性能下降'); render = { Show-CompareHint } }
    [pscustomobject]@{ name = 'driver'; keywords = @('driver', '驱动', '设备', 'usb', '鼠标', '键盘', '外设', '识别不了', '感叹号'); render = { Show-Drivers } }
    [pscustomobject]@{ name = 'display'; keywords = @('display', '屏幕', '黑屏', '分辨率', '外接屏', '显示器', '显卡', '花屏'); render = { Show-Display } }
    [pscustomobject]@{ name = 'audio'; keywords = @('audio', '声音', '没声音', '扬声器', '麦克风', '音频', '耳机'); render = { Show-Audio } }
    [pscustomobject]@{ name = 'printer'; keywords = @('printer', '打印机', '打印', 'spooler'); render = { Show-Printer } }
    [pscustomobject]@{ name = 'updates'; keywords = @('update', '更新', '补丁'); render = { Show-Updates } }
    [pscustomobject]@{ name = 'security'; keywords = @('defender', 'firewall', '病毒', '防火墙', '杀毒', '木马', '安全中心'); render = { Show-Security } }
    [pscustomobject]@{ name = 'power'; keywords = @('battery', '电池', '电源', '休眠', '睡眠', '耗电', '充电', '续航'); render = { Show-Power } }
    [pscustomobject]@{ name = 'startup'; keywords = @('startup', '开机', '启动项', '引导', 'boot'); render = { Show-Startup } }
    [pscustomobject]@{ name = 'services'; keywords = @('服务', 'service'); render = { Show-Services } }
    [pscustomobject]@{ name = 'repair'; keywords = @('损坏', '修复', 'sfc', 'dism', '组件存储'); render = { Show-RepairCheck } }
  )
}

function Resolve-IssueRoute([string]$Text) {
  $normalized = $Text.ToLowerInvariant()
  foreach ($route in @(Get-IssueRouteTable)) {
    foreach ($keyword in $route.keywords) {
      if ($normalized.Contains($keyword.ToLowerInvariant())) {
        return [pscustomobject]@{ name = $route.name; matched = $keyword; render = $route.render }
      }
    }
  }
  return [pscustomobject]@{ name = 'default'; matched = $null; render = { Show-DefaultRoute } }
}

function Show-DefaultRoute {
  Show-Drives | Format-Table -AutoSize
  $memory = Get-MemoryData
  "Memory used: $($memory.used_percent)%"
  Show-DiskCandidates
  'No route keyword matched the symptom text, so this is a generic triage.'
  "Router keywords: $(@(Get-IssueRouteTable | ForEach-Object { $_.keywords[0] }) -join ', ')"
}

function Invoke-IssueRoute([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) {
    'Issue text is empty. Example: -Mode issue -Issue "电脑最近变卡了"'
    return
  }
  $route = Resolve-IssueRoute $Text
  $matched = if ($route.matched) { $route.matched } else { 'none' }
  "[route] $($route.name) (matched: $matched)"
  & $route.render
}

function Get-TempCleanupPlan([string[]]$Roots) {
  # Deletion targets are an allowlist (never "whatever %TEMP% happens to say"),
  # limited to entries not modified in the last 24h so a running installer is
  # never disturbed. Junction/symlink entries are never planned for deletion.
  if (-not $Roots -or $Roots.Count -eq 0) {
    $Roots = @($env:TEMP, $env:TMP, (Join-Path $env:LOCALAPPDATA 'Temp'), 'C:\Windows\Temp')
  }
  $targets = @($Roots | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('\') } | Sort-Object -Unique)
  $cutoff = (Get-Date).AddHours(-24)
  $plan = @()
  foreach ($target in $targets) {
    $resolved = Resolve-Path -LiteralPath $target -ErrorAction SilentlyContinue
    if (-not $resolved) { continue }
    if (-not (Test-SafeTempRoot $resolved.Path)) {
      $plan += [pscustomobject]@{
        Root = $resolved.Path; Allowed = $false; Reason = 'not on the temp-root allowlist'
        Entries = @(); Bytes = [int64]0; RecentSkipped = 0; LinkSkipped = 0
      }
      continue
    }
    $items = @(Get-ChildItem -LiteralPath $resolved.Path -Force -ErrorAction SilentlyContinue)
    $links = @($items | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
    $plain = @($items | Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })
    $recent = @($plain | Where-Object { $_.LastWriteTime -ge $cutoff })
    $stale = @($plain | Where-Object { $_.LastWriteTime -lt $cutoff })
    $bytes = [int64]0
    foreach ($item in $stale) {
      if ($item.PSIsContainer) {
        $size = Get-FolderSize $item.FullName 5
        $bytes += [int64]$size.Bytes
      } else {
        $bytes += [int64]$item.Length
      }
    }
    $plan += [pscustomobject]@{
      Root = $resolved.Path; Allowed = $true; Reason = 'allowed temp root'
      Entries = $stale; Bytes = $bytes; RecentSkipped = $recent.Count; LinkSkipped = $links.Count
    }
  }
  return $plan
}

function Show-TempPreview {
  $plan = @(Get-TempCleanupPlan)
  '=== Temp cleanup preview ==='
  'Nothing has been deleted. Add -Apply to execute the plan below.'
  $plan | ForEach-Object {
    [pscustomobject]@{
      Root = $_.Root
      Allowed = $_.Allowed
      WouldDeleteEntries = @($_.Entries).Count
      WouldFree = (Format-Bytes $_.Bytes)
      SkippedRecent24h = $_.RecentSkipped
      SkippedLinks = $_.LinkSkipped
    }
  } | Format-Table -AutoSize
  foreach ($entry in $plan) {
    if (-not $entry.Allowed) { "Skipped: $($entry.Root) - $($entry.Reason)" }
  }
}

function Invoke-TempCleanup([string[]]$Roots) {
  # $Roots is only used by the self-test, which points the real delete path at
  # its own sandbox. The CLI calls this with no arguments, and the allowlist in
  # Test-SafeTempRoot still validates every root either way.
  $plan = @(Get-TempCleanupPlan $Roots)
  $report = @()
  foreach ($entry in $plan) {
    if (-not $entry.Allowed) { Write-Host "Skipped unsafe temp path: $($entry.Root)"; continue }
    foreach ($item in $entry.Entries) {
      # Re-check immediately before deleting: the parent must still be an
      # allowed temp root and the entry must not have become a reparse point.
      if (-not (Test-SafeTempRoot (Split-Path -Parent $item.FullName))) { continue }
      if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
      Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $remaining = @(Get-ChildItem -LiteralPath $entry.Root -Force -ErrorAction SilentlyContinue).Count
    $report += [pscustomobject]@{
      Root = $entry.Root
      TargetedEntries = @($entry.Entries).Count
      FreedBytes = $entry.Bytes
      RecentSkipped = $entry.RecentSkipped
      LinkSkipped = $entry.LinkSkipped
      RemainingEntries = $remaining
    }
  }
  return $report
}

function Write-SectionJson([string]$ModeName, [scriptblock]$Body) {
  # Modes without a native structured shape are still machine-readable: the
  # rendered text is split on "=== title ===" headers into sections. This
  # removes the old behaviour where -Format json was silently ignored.
  $lines = @(& $Body | Out-String -Stream -Width 200)
  $sections = New-Object System.Collections.ArrayList
  $current = $null
  foreach ($line in $lines) {
    $text = [string]$line
    if ($text -match '^===\s*(.+?)\s*===\s*$') {
      $current = [pscustomobject]@{ name = $Matches[1]; lines = New-Object System.Collections.ArrayList }
      [void]$sections.Add($current)
      continue
    }
    if ($text.Trim() -eq '') { continue }
    if (-not $current) {
      $current = [pscustomobject]@{ name = 'output'; lines = New-Object System.Collections.ArrayList }
      [void]$sections.Add($current)
    }
    [void]$current.lines.Add($text)
  }
  return ConvertTo-AsciiJsonString ([pscustomobject]@{
    mode = $ModeName
    version = $WinfixVersion
    generated_at = (Get-Date).ToString('s')
    format = 'sections'
    sections = @($sections | ForEach-Object { [pscustomobject]@{ name = $_.name; lines = @($_.lines) } })
  })
}

function New-SelfTestResult([string]$Name, [bool]$Passed, [string]$Detail) {
  [pscustomobject]@{ Test = $Name; Result = $(if ($Passed) { 'PASS' } else { 'FAIL' }); Detail = $Detail }
}

function Invoke-SelfTest {
  # Read-only assertions on the safety contract. The only thing deleted is this
  # function's own sandbox under %TEMP%.
  $results = New-Object System.Collections.ArrayList
  $localTemp = Join-Path $env:LOCALAPPDATA 'Temp'
  [void]$results.Add((New-SelfTestResult 'temp allowlist accepts %LOCALAPPDATA%\Temp' (Test-SafeTempRoot $localTemp) $localTemp))
  [void]$results.Add((New-SelfTestResult 'temp allowlist accepts C:\Windows\Temp' (Test-SafeTempRoot 'C:\Windows\Temp') 'C:\Windows\Temp'))
  [void]$results.Add((New-SelfTestResult 'temp allowlist rejects C:\Windows' (-not (Test-SafeTempRoot 'C:\Windows')) 'C:\Windows'))
  [void]$results.Add((New-SelfTestResult 'temp allowlist rejects the drive root' (-not (Test-SafeTempRoot ($env:SystemDrive + '\'))) ($env:SystemDrive + '\')))
  [void]$results.Add((New-SelfTestResult 'temp allowlist rejects the user profile' (-not (Test-SafeTempRoot $env:USERPROFILE)) $env:USERPROFILE))
  [void]$results.Add((New-SelfTestResult "redirected %TEMP% is accepted when its leaf is temp/tmp" (Test-SafeTempRoot $env:TEMP) $env:TEMP))

  $redacted = [string](Redact-SensitiveText 'http://user:s3cret@example.com/path?token=abc123')
  [void]$results.Add((New-SelfTestResult 'credentials in URLs are redacted' (($redacted -notmatch 's3cret') -and ($redacted -match '\*\*\*:\*\*\*@')) $redacted))
  $redacted2 = [string](Redact-SensitiveText 'password=hunter2')
  [void]$results.Add((New-SelfTestResult 'password= values are redacted' ($redacted2 -notmatch 'hunter2') $redacted2))

  $sandbox = Join-Path $env:TEMP ("winfix-selftest-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  $fakeTemp = Join-Path $sandbox 'tmp'
  $target = Join-Path $sandbox 'target'
  try {
    New-Item -ItemType Directory -Path $fakeTemp, $target -Force | Out-Null
    $oldFile = Join-Path $fakeTemp 'old.tmp'
    Set-Content -LiteralPath $oldFile -Value ('x' * 1024)
    (Get-Item -LiteralPath $oldFile).LastWriteTime = (Get-Date).AddDays(-3)
    $freshFile = Join-Path $fakeTemp 'fresh.tmp'
    Set-Content -LiteralPath $freshFile -Value 'x'
    $targetFile = Join-Path $target 'keep.txt'
    Set-Content -LiteralPath $targetFile -Value 'keep'
    $junction = Join-Path $fakeTemp 'link'
    $junctionMade = $false
    try { New-Item -ItemType Junction -Path $junction -Target $target -ErrorAction Stop | Out-Null; $junctionMade = $true } catch { $junctionMade = $false }
    $plan = @(Get-TempCleanupPlan @($fakeTemp))
    $entry = $plan | Select-Object -First 1
    $names = @($entry.Entries | ForEach-Object { $_.Name })
    [void]$results.Add((New-SelfTestResult 'a sandbox root with a temp/tmp leaf is allowed' ([bool]$entry.Allowed) "allowed=$($entry.Allowed)"))
    [void]$results.Add((New-SelfTestResult 'a 3-day-old file is planned for deletion' ($names -contains 'old.tmp') ($names -join ',')))
    [void]$results.Add((New-SelfTestResult 'a file modified now is skipped' (-not ($names -contains 'fresh.tmp')) ($names -join ',')))
    if ($junctionMade) {
      [void]$results.Add((New-SelfTestResult 'a junction is never planned for deletion' (-not ($names -contains 'link')) ($names -join ',')))
      [void]$results.Add((New-SelfTestResult 'the junction target file is untouched' (Test-Path -LiteralPath $targetFile) $targetFile))
    } else {
      [void]$results.Add((New-SelfTestResult 'junction test' $true 'skipped: could not create a junction here'))
    }
    $refused = @(Get-TempCleanupPlan @('C:\Windows')) | Select-Object -First 1
    [void]$results.Add((New-SelfTestResult 'C:\Windows is refused as a cleanup root' (-not [bool]$refused.Allowed) "allowed=$($refused.Allowed)"))

    # --- End-to-end deletion contract -------------------------------------
    # Everything above asserts the *plan*. Those assertions would still all pass
    # if the dispatcher called the delete function unconditionally, so the
    # user-facing promise ("without -Apply this cannot delete anything") is not
    # actually covered by them. These two checks drive the real code paths: a
    # child process running -Mode cleanup-temp with its temp roots pointed at
    # this sandbox, then the real apply function on the same sandbox.
    $e2eTemp = Join-Path $sandbox 'e2e\tmp'
    $e2eLocal = Join-Path $sandbox 'e2e\local'
    New-Item -ItemType Directory -Path $e2eTemp, $e2eLocal -Force | Out-Null
    $e2eOld = Join-Path $e2eTemp 'e2e-stale.tmp'
    Set-Content -LiteralPath $e2eOld -Value ('y' * 2048)
    (Get-Item -LiteralPath $e2eOld).LastWriteTime = (Get-Date).AddDays(-4)
    $e2eFresh = Join-Path $e2eTemp 'e2e-fresh.tmp'
    Set-Content -LiteralPath $e2eFresh -Value 'y'
    if ($WinfixScriptPath -and (Test-Path -LiteralPath $WinfixScriptPath)) {
      $savedTemp = $env:TEMP
      $savedTmp = $env:TMP
      $savedLocalAppData = $env:LOCALAPPDATA
      $childText = ''
      try {
        $env:TEMP = $e2eTemp
        $env:TMP = $e2eTemp
        $env:LOCALAPPDATA = $e2eLocal
        $childText = (& powershell -NoProfile -ExecutionPolicy Bypass -File $WinfixScriptPath -Mode cleanup-temp -Format json 2>$null | Out-String)
      } finally {
        $env:TEMP = $savedTemp
        $env:TMP = $savedTmp
        $env:LOCALAPPDATA = $savedLocalAppData
      }
      $previewKept = Test-Path -LiteralPath $e2eOld
      [void]$results.Add((New-SelfTestResult 'preview (no -Apply) deletes nothing, end to end' $previewKept "stale sandbox file still exists=$previewKept"))
      # Non-vacuity: the file surviving proves nothing if the child never looked
      # at this root, so require the preview output to name the sandbox.
      $sawSandbox = [bool]($childText -match [regex]::Escape((Split-Path $sandbox -Leaf)))
      [void]$results.Add((New-SelfTestResult 'that preview run really did read the redirected temp root' $sawSandbox 'guards against a vacuous pass'))
    } else {
      [void]$results.Add((New-SelfTestResult 'preview end-to-end test' $false "cannot re-run this script (path='$WinfixScriptPath')"))
    }
    [void](Invoke-TempCleanup -Roots @($fakeTemp, $e2eTemp))
    $staleGone = (-not (Test-Path -LiteralPath $oldFile)) -and (-not (Test-Path -LiteralPath $e2eOld))
    [void]$results.Add((New-SelfTestResult 'apply does delete stale entries, end to end' $staleGone 'old.tmp and e2e-stale.tmp removed'))
    $freshKept = (Test-Path -LiteralPath $freshFile) -and (Test-Path -LiteralPath $e2eFresh)
    [void]$results.Add((New-SelfTestResult 'apply keeps entries modified within 24h, end to end' $freshKept 'fresh.tmp and e2e-fresh.tmp kept'))
    if ($junctionMade) {
      [void]$results.Add((New-SelfTestResult 'apply never follows a junction into its target' (Test-Path -LiteralPath $targetFile) $targetFile))
    }

    # --- Security posture branches ---------------------------------------
    # The third-party-AV case cannot be reproduced on a machine that has none,
    # and getting it wrong is what made "Defender real-time off" read as a
    # problem when Windows had simply handed protection to another AV.
    $thirdPartyAv = Get-SecurityPosture -Injected -DefenderStatus ([pscustomobject]@{ AMRunningMode = 'Passive'; RealTimeProtectionEnabled = $false; AntivirusEnabled = $false }) -AvProducts @([pscustomobject]@{ name = 'Example AV'; state = 0 })
    [void]$results.Add((New-SelfTestResult 'a registered third-party AV is not scored as missing protection' (($thirdPartyAv.state -eq 'third-party') -and ($thirdPartyAv.score -eq 100)) "state=$($thirdPartyAv.state) score=$($thirdPartyAv.score)"))
    [void]$results.Add((New-SelfTestResult 'the third-party verdict names the AV' ([bool]($thirdPartyAv.verdict -match 'Example AV')) $thirdPartyAv.verdict))
    $unprotected = Get-SecurityPosture -Injected -DefenderStatus ([pscustomobject]@{ AMRunningMode = 'Not running'; RealTimeProtectionEnabled = $false; AntivirusEnabled = $false }) -AvProducts @()
    [void]$results.Add((New-SelfTestResult 'Defender off with no third-party AV is reported as unprotected' (($unprotected.state -eq 'unprotected') -and ($unprotected.score -eq 0)) "state=$($unprotected.state) score=$($unprotected.score)"))
    $protected = Get-SecurityPosture -Injected -DefenderStatus ([pscustomobject]@{ AMRunningMode = 'Normal'; RealTimeProtectionEnabled = $true; AntivirusEnabled = $true }) -AvProducts @()
    [void]$results.Add((New-SelfTestResult 'Defender real-time on is scored as protected' (($protected.state -eq 'protected') -and ($protected.score -eq 100)) "state=$($protected.state) score=$($protected.score)"))
    $unknown = Get-SecurityPosture -Injected -DefenderStatus $null -AvProducts @()
    [void]$results.Add((New-SelfTestResult 'an unavailable Defender is excluded from the score, not scored 0' (($unknown.state -eq 'unavailable') -and ($null -eq $unknown.score)) "state=$($unknown.state) score=$($unknown.score)"))

    # A file list cut off by the time budget is a floor, and must say so - the
    # folder-size path already labels full/sampled/partial, and the two used to
    # disagree. Budget forced to 0 so the truncation is deterministic.
    $savedBudget = $SectionBudgetSeconds
    $savedPath = $Path
    $filesOut = ''
    try {
      $script:SectionBudgetSeconds = 0
      $script:Path = $e2eTemp
      $filesOut = (Show-LargeFiles | Out-String)
    } finally {
      $script:SectionBudgetSeconds = $savedBudget
      $script:Path = $savedPath
    }
    [void]$results.Add((New-SelfTestResult 'a budget-truncated file list is labelled partial' ([bool]($filesOut -match 'partial')) 'floor, not a total'))
  } finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
  }

  $stateDir = Join-Path $env:USERPROFILE '.winfix\baselines'
  [void]$results.Add((New-SelfTestResult 'baseline directory is ~\.winfix\baselines' ($stateDir -like '*\.winfix\baselines') $stateDir))

  $slow = Resolve-IssueRoute '电脑最近变卡了'
  [void]$results.Add((New-SelfTestResult 'router sends the slow-PC phrase to the slow route' ($slow.name -eq 'slow') $slow.name))
  $printer = Resolve-IssueRoute '打印机不能用'
  [void]$results.Add((New-SelfTestResult 'router sends the printer phrase to the printer route' ($printer.name -eq 'printer') $printer.name))
  $state = Resolve-IssueRoute '保存一下现在电脑的状态'
  [void]$results.Add((New-SelfTestResult 'router sends the save-state phrase to the baseline route' ($state.name -eq 'baseline') $state.name))
  $dying = Resolve-IssueRoute '硬盘是不是要坏了'
  [void]$results.Add((New-SelfTestResult 'router sends the failing-disk phrase to the smart route' ($dying.name -eq 'smart') $dying.name))
  $space = Resolve-IssueRoute '硬盘空间不够'
  [void]$results.Add((New-SelfTestResult 'a disk-space phrase still goes to the disk route' ($space.name -eq 'disk') $space.name))
  $url = Resolve-IssueRoute '这个网址打不开'
  [void]$results.Add((New-SelfTestResult 'router sends the URL phrase to the network route' ($url.name -eq 'network') $url.name))
  $mouse = Resolve-IssueRoute '鼠标没反应'
  [void]$results.Add((New-SelfTestResult 'router sends the mouse phrase to the driver route' ($mouse.name -eq 'driver') $mouse.name))
  $heat = Resolve-IssueRoute '笔记本发烫'
  [void]$results.Add((New-SelfTestResult 'router sends the heat phrase to the resources route' ($heat.name -eq 'resources') $heat.name))
  $short = @(Get-IssueRouteTable | ForEach-Object { $_.keywords | Where-Object { $_.Length -lt 2 } })
  [void]$results.Add((New-SelfTestResult 'no single-character router keywords' ($short.Count -eq 0) ($short -join ',')))

  # Baseline anti-churn (pure function, no disk writes).
  $prevRecent = [pscustomobject]@{
    created_at = (Get-Date).AddMinutes(-2).ToString('s')
    drives = @([pscustomobject]@{ device = 'C:'; free_bytes = [int64]1000000000 })
    startup = @(); pending_reboot = $false
  }
  $prevOld = [pscustomobject]@{
    created_at = (Get-Date).AddMinutes(-60).ToString('s')
    drives = @([pscustomobject]@{ device = 'C:'; free_bytes = [int64]1000000000 })
    startup = @(); pending_reboot = $false
  }
  $nowSame = [pscustomobject]@{
    drives = @([pscustomobject]@{ device = 'C:'; free_bytes = [int64]1000000100 })
    startup = @(); pending_reboot = $false
  }
  $nowChanged = [pscustomobject]@{
    drives = @([pscustomobject]@{ device = 'C:'; free_bytes = [int64]6000000000 })
    startup = @(); pending_reboot = $false
  }
  [void]$results.Add((New-SelfTestResult 'an identical snapshot inside the window is redundant' (Test-BaselineRedundant $prevRecent $nowSame) '2 min ago, +100 B'))
  [void]$results.Add((New-SelfTestResult 'a recent snapshot with a 5 GB drive change is not redundant' (-not (Test-BaselineRedundant $prevRecent $nowChanged)) '2 min ago, +5 GB'))
  [void]$results.Add((New-SelfTestResult 'a snapshot older than the window is not redundant' (-not (Test-BaselineRedundant $prevOld $nowSame)) '60 min ago'))

  $changelog = Join-Path (Split-Path -Parent $PSScriptRoot) 'CHANGELOG.md'
  if (Test-Path -LiteralPath $changelog) {
    $top = (Get-Content -LiteralPath $changelog -TotalCount 4) -join ' '
    [void]$results.Add((New-SelfTestResult 'CHANGELOG top entry matches the script version' ($top -match [regex]::Escape("## $WinfixVersion")) $WinfixVersion))
  } else {
    [void]$results.Add((New-SelfTestResult 'CHANGELOG check' $true 'skipped: CHANGELOG.md not found next to the script'))
  }
  return @($results)
}

# Modes that render text but still answer -Format json through Write-SectionJson.
$TextModes = [ordered]@{
  'system' = { Show-System }
  'startup' = { Show-Startup }
  'services' = { Show-Services }
  'drivers' = { Show-Drivers }
  'updates' = { Show-Updates }
  'devices' = { Show-Devices }
  'power' = { Show-Power }
  'audio' = { Show-Audio }
  'display' = { Show-Display }
  'printer' = { Show-Printer }
  'security' = { Show-Security }
  'repair-check' = { Show-RepairCheck }
  'chrome' = { Show-Chrome }
  'vscode' = { Show-VSCode }
  'wechat' = { Show-WeChat }
  'android' = { Show-Android }
  'smart' = { Show-Smart }
  'files' = { Show-LargeFiles }
  'large' = { Show-LargeUserFolders }
}

switch ($Mode) {
  'health' {
    if ($Format -eq 'json') { Write-JsonPayload (Get-HealthData); break }
    Show-Health
  }
  'baseline' {
    $result = Save-Baseline -Force:$Force
    if ($Format -eq 'json') { Write-JsonPayload $result; break }
    if (-not $result.saved) {
      "Baseline NOT saved: $($result.skipped_reason)"
      "Existing baseline: $($result.existing_path)"
      $result.hint
      break
    }
    "Baseline saved: $($result.saved_path)"
    $result.summary.drives | Format-Table -AutoSize
    [pscustomobject]@{
      StartupItems = $result.summary.startup_items
      ScheduledTasks = $result.summary.scheduled_tasks
      AutoStoppedServices = $result.summary.auto_stopped_services
      PendingReboot = $result.summary.pending_reboot
    } | Format-List
  }
  'compare' {
    $diff = Compare-WithBaseline $BaselinePath
    if ($null -eq $diff) {
      $reason = if ($BaselinePath) { "Baseline file not found: $BaselinePath" } else { 'No baseline found yet. Run -Mode baseline to snapshot the current state first.' }
      if ($Format -eq 'json') {
        Write-JsonPayload ([pscustomobject]@{
          mode = 'compare'
          version = $WinfixVersion
          generated_at = (Get-Date).ToString('s')
          baseline_path = $(if ($BaselinePath) { $BaselinePath } else { $null })
          has_baseline = $false
          note = $reason
        })
        break
      }
      $reason
      break
    }
    if ($Format -eq 'json') { Write-JsonPayload $diff; break }
    Show-CompareText $diff
  }
  'overview' {
    if ($Format -eq 'json') {
      Write-JsonPayload ([pscustomobject]@{
        mode = 'overview'
        version = $WinfixVersion
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
    '=== Disk candidates ==='; Show-DiskCandidates
  }
  'disk' {
    if ($Format -eq 'json') {
      Write-JsonPayload ([pscustomobject]@{
        mode = 'disk'
        version = $WinfixVersion
        generated_at = (Get-Date).ToString('s')
        deep = [bool]$Deep
        drives = @(Get-DriveData)
        candidates = @(Get-DiskCandidateData)
      })
      break
    }
    Show-Drives | Format-Table -AutoSize; Show-DiskCandidates
  }
  'memory' {
    if ($Format -eq 'json') {
      Write-JsonPayload ([pscustomobject]@{
        mode = 'memory'
        version = $WinfixVersion
        generated_at = (Get-Date).ToString('s')
        memory = Get-MemoryData
        top_processes = @(Get-TopProcessData)
      })
      break
    }
    Show-Memory | Format-Table -AutoSize
  }
  'dev' {
    $probes = @(Get-DevToolProbes)
    if ($Format -eq 'json') {
      Write-JsonPayload ([pscustomobject]@{
        mode = 'dev'
        version = $WinfixVersion
        generated_at = (Get-Date).ToString('s')
        readiness = Get-ReadinessVerdict $probes
        tools = $probes
      })
      break
    }
    Show-DevTools
  }
  'network' {
    if ($Format -eq 'json') {
      Write-JsonPayload ([pscustomobject]@{
        mode = 'network'
        version = $WinfixVersion
        generated_at = (Get-Date).ToString('s')
        proxy = Get-ProxyData
        dns_servers = @(try { Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.ServerAddresses } | Select-Object InterfaceAlias, ServerAddresses } catch { @() })
      })
      break
    }
    Show-Network
  }
  'net-test' {
    if ($Format -eq 'json') { Write-SectionJson 'net-test' { Test-NetworkTarget $Target }; break }
    Test-NetworkTarget $Target
  }
  'events' {
    if ($Format -eq 'json') {
      Write-JsonPayload ([pscustomobject]@{
        mode = 'events'
        version = $WinfixVersion
        generated_at = (Get-Date).ToString('s')
        data = Get-SystemEventData 7 30
      })
      break
    }
    Show-Events
  }
  'wsl' {
    if ($Format -eq 'json') {
      Write-JsonPayload ([pscustomobject]@{
        mode = 'wsl'
        version = $WinfixVersion
        generated_at = (Get-Date).ToString('s')
        status = Get-WslOutput @('--status')
        list = Get-WslOutput @('-l', '-v')
        data = Get-WslData
      })
      break
    }
    Show-WSL
  }
  'docker' {
    if ($Format -eq 'json') { Write-SectionJson 'docker' { Show-Docker }; break }
    Show-Docker
  }
  'app' {
    if ($Format -eq 'json') { Write-SectionJson 'app' { Show-App $ProcessName }; break }
    Show-App $ProcessName
  }
  'issue' {
    if ($Format -eq 'json') {
      $route = Resolve-IssueRoute $Issue
      $body = Write-SectionJson 'issue' $route.render
      $payload = $body | ConvertFrom-Json
      $payload | Add-Member -NotePropertyName route -NotePropertyValue $route.name -Force
      $payload | Add-Member -NotePropertyName matched -NotePropertyValue $route.matched -Force
      ConvertTo-AsciiJsonString $payload
      break
    }
    Invoke-IssueRoute $Issue
  }
  'cleanup-temp' {
    if ($Apply) {
      $report = Invoke-TempCleanup
      if ($Format -eq 'json') { Write-JsonPayload ([pscustomobject]@{ mode = 'cleanup-temp'; version = $WinfixVersion; applied = $true; roots = @($report) }); break }
      $report | ForEach-Object {
        [pscustomobject]@{ Root = $_.Root; DeletedTargeted = $_.TargetedEntries; Freed = (Format-Bytes $_.FreedBytes); SkippedRecent24h = $_.RecentSkipped; SkippedLinks = $_.LinkSkipped; RemainingEntries = $_.RemainingEntries }
      } | Format-Table -AutoSize
      'Done. Rerun -Mode disk to verify.'
    } else {
      if ($Format -eq 'json') {
        $plan = @(Get-TempCleanupPlan)
        Write-JsonPayload ([pscustomobject]@{
          mode = 'cleanup-temp'
          version = $WinfixVersion
          applied = $false
          note = 'Preview only. Re-run with -Apply to delete.'
          allowlist = @(Get-TempRootAllowlist)
          roots = @($plan | ForEach-Object { [pscustomobject]@{ root = $_.Root; allowed = $_.Allowed; reason = $_.Reason; would_delete_entries = @($_.Entries).Count; would_free_bytes = $_.Bytes; skipped_recent_24h = $_.RecentSkipped; skipped_links = $_.LinkSkipped } })
        })
        break
      }
      Show-TempPreview
    }
  }
  'self-test' {
    $results = @(Invoke-SelfTest)
    $failures = @($results | Where-Object { $_.Result -eq 'FAIL' })
    $script:SelfTestFailures = $failures.Count
    if ($Format -eq 'json') {
      Write-JsonPayload ([pscustomobject]@{
        mode = 'self-test'
        version = $WinfixVersion
        passed = ($results.Count - $failures.Count)
        failed = $failures.Count
        results = $results
      })
      break
    }
    $results | Format-Table -AutoSize
    "Passed: $($results.Count - $failures.Count) / $($results.Count)"
    if ($failures.Count -gt 0) {
      'FAILURES:'
      $failures | ForEach-Object { "  - $($_.Test): $($_.Detail)" }
    } else {
      'All safety-contract checks passed. Nothing was deleted except the self-test sandbox.'
    }
  }
}

if ($TextModes.Contains($Mode)) {
  if ($Format -eq 'json') { Write-SectionJson $Mode $TextModes[$Mode] }
  else { & $TextModes[$Mode] }
}

if ($Mode -eq 'self-test' -and $script:SelfTestFailures -gt 0) { exit 1 }

