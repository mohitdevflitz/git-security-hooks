# windows/Alerts.ps1
#
# Tails the watcher log and raises a Windows toast for each detection.
# No tray icon, no window, no dashboard - notifications only.
#
# Why this is a separate process: the watcher service runs as LOCAL SYSTEM in
# session 0 and cannot draw UI on the interactive desktop. This runs as the
# logged-in user, so its toasts actually appear.
#
# Usage:
#   .\Alerts.ps1              start tailing (blocks)
#   .\Alerts.ps1 -Test        fire one sample toast and exit
#   .\Alerts.ps1 -Install     register logon task + start now
#   .\Alerts.ps1 -Remove      unregister and stop
#   .\Alerts.ps1 -EnsureRunning   start only if not already running
#
# Read-only. Never touches scanned files.

param(
    [switch]$Test,
    [switch]$Install,
    [switch]$Remove,
    [switch]$EnsureRunning,
    [switch]$Status,
    [string]$Log,
    [string]$Marker   # accepted so the scheduled task's own tag does not error
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not $Log) { $Log = Join-Path $root "logs\watch-log.txt" }

$TaskName = 'GitSecurityAlerts'
$Self     = $MyInvocation.MyCommand.Path
$Marker   = 'GSH_ALERTS_TAIL'   # lets us find our own running instance

# ---------------------------------------------------------------------------
# Toast
# ---------------------------------------------------------------------------
# Borrow PowerShell's registered AppID - a toast from an unregistered AppID is
# silently discarded by Windows.
$AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

function Show-Toast {
    param([string]$Title, [string]$Line1, [string]$Line2 = '')

    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

        $e = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }

        $xml = @"
<toast scenario="reminder">
  <visual>
    <binding template="ToastGeneric">
      <text>$(& $e $Title)</text>
      <text>$(& $e $Line1)</text>
      <text>$(& $e $Line2)</text>
    </binding>
  </visual>
</toast>
"@
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
        return $true
    } catch {
        # Toast unavailable (older Windows, policy, etc). Fall back to console
        # so a detection is never silently lost.
        Write-Host ""
        Write-Host "  !! $Title" -ForegroundColor Red
        Write-Host "     $Line1" -ForegroundColor Yellow
        if ($Line2) { Write-Host "     $Line2" -ForegroundColor DarkGray }
        return $false
    }
}

# ---------------------------------------------------------------------------
# Is a tail already running?
# ---------------------------------------------------------------------------
function Get-RunningAlerts {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$Marker*" }
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
if ($Test) {
    if (Show-Toast -Title 'Malware detected (TEST)' `
                   -Line1 'F:\example\project\admin.routes.js' `
                   -Line2 'Original NOT modified - copy saved to quarantine.') {
        Write-Host "Toast sent. If nothing appeared, enable notifications for Windows PowerShell" -ForegroundColor Yellow
        Write-Host "in Settings > System > Notifications." -ForegroundColor Yellow
    }
    return
}

if ($Remove) {
    Get-RunningAlerts | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -EA SilentlyContinue
    Write-Host "Alerts removed." -ForegroundColor Green
    return
}

if ($Install -or $EnsureRunning) {

    if ($Install) {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Self`" -Marker $Marker"

        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                        -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                        -DontStopIfGoingOnBatteries -StartWhenAvailable `
                        -ExecutionTimeLimit ([TimeSpan]::Zero)

        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -EA SilentlyContinue
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings `
            -Description 'Desktop notifications for Git Security Hooks detections.' | Out-Null

        Write-Host "Alerts registered - they will start at every logon." -ForegroundColor Green
    }

    # Start now if nothing is already tailing.
    if (Get-RunningAlerts) {
        Write-Host "Alerts already running." -ForegroundColor DarkGray
        return
    }

    # Prefer starting via Task Scheduler. A process launched with Start-Process
    # from this console is a child of it; closing the terminal (or the menu
    # exiting) can take it down with them. Task Scheduler owns its own process,
    # so the alerts keep running exactly like the watcher service does.
    $task = Get-ScheduledTask -TaskName $TaskName -EA SilentlyContinue
    if ($task) {
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep 2
        if (Get-RunningAlerts) {
            Write-Host "Alerts started (independent of this window)." -ForegroundColor Green
            return
        }
    }

    # Fallback if the task is missing or did not come up.
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass',
        '-File', "`"$Self`"", '-Marker', $Marker
    )
    Write-Host "Alerts started." -ForegroundColor Green
    return
}

if ($Status) {
    $task    = Get-ScheduledTask -TaskName $TaskName -EA SilentlyContinue
    $running = @(Get-RunningAlerts)

    Write-Host ""
    Write-Host "  logon task : $(if ($task) { $task.State } else { 'not registered' })"
    Write-Host "  running    : $(if ($running.Count) { "yes (pid $($running[0].ProcessId))" } else { 'no' })"
    Write-Host "  log        : $Log"
    Write-Host ""
    return
}

# ---------------------------------------------------------------------------
# Default: tail the log
# ---------------------------------------------------------------------------
if (-not (Test-Path $Log)) {
    # The service may not have written its log yet - wait rather than dying,
    # otherwise a logon race leaves alerts permanently off.
    $waited = 0
    while (-not (Test-Path $Log) -and $waited -lt 300) {
        Start-Sleep 5; $waited += 5
    }
}
if (-not (Test-Path $Log)) { return }

# --- startup summary -------------------------------------------------------
# One toast at logon confirming what is actually protecting the machine.
# Silence is ambiguous - it looks the same whether protection is running or
# was never installed - so say so explicitly, either way.
# At logon the service may still be starting, so give it a moment rather than
# reporting a false alarm on every boot.
$svc = $null
for ($i = 0; $i -lt 12; $i++) {
    $svc = Get-Service GitSecurityWatcher -EA SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { break }
    Start-Sleep 5
}

$svcOK     = $svc -and $svc.Status -eq 'Running'
$hooksPath = (git config --global core.hooksPath 2>$null)
$hooksOK   = $hooksPath -and (Test-Path (Join-Path $hooksPath 'pre-commit'))

if ($svcOK -and $hooksOK) {
    Show-Toast -Title 'Git Security: protection active' `
               -Line1 'Real-time watcher running. Commit/push blocking enabled.' `
               -Line2 'Detections appear here and in logs\watch-log.txt' | Out-Null
} else {
    $problems = @()
    if (-not $svcOK)   { $problems += "watcher service $(if ($svc) { $svc.Status } else { 'NOT INSTALLED' })" }
    if (-not $hooksOK) { $problems += 'git hooks not wired up' }

    Show-Toast -Title 'Git Security: NOT fully protected' `
               -Line1 ($problems -join ' | ') `
               -Line2 'Run RUN-WINDOWS.bat to fix.' | Out-Null
}

# --- detections ------------------------------------------------------------
Get-Content -LiteralPath $Log -Wait -Tail 0 | ForEach-Object {
    if ($_ -match 'DETECTED:\s(.+)$') {
        $file = $Matches[1].Trim()
        Show-Toast -Title "Malware detected: $(Split-Path $file -Leaf)" `
                   -Line1 $file `
                   -Line2 'Original NOT modified - see logs\watch-log.txt' | Out-Null
    }
}
