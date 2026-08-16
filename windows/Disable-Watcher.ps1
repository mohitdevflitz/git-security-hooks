#Requires -RunAsAdministrator
<#
  windows/Disable-Watcher.ps1

  Turns the real-time watcher OFF on this machine, and leaves the git side
  (hooks + the GitSecurityHooksGuard self-healing task) running at boot.

  What it touches:
    GitSecurityWatcher        Windows service   -> stopped + start type Disabled
    GitSecurityHooksWatcher   scheduled task    -> stopped + disabled
    GitSecurityAlerts         scheduled task    -> LEFT ALONE (still toasts
                                                   when a git hook blocks)
    GitSecurityHooksGuard     scheduled task    -> LEFT ALONE / re-enabled
    core.hooksPath            git config        -> re-applied if missing

  Nothing is uninstalled or deleted. Re-enable with:
      .\Disable-Watcher.ps1 -Enable

  Run as Administrator:
      .\Disable-Watcher.ps1
#>

param([switch]$Enable)

$ErrorActionPreference = 'Continue'

$root  = Split-Path -Parent $PSScriptRoot
$hooks = Join-Path $root "hooks"

function Say($msg, $colour = 'Gray') { Write-Host "  $msg" -ForegroundColor $colour }

Write-Host ""
Write-Host "=== Git Security Hooks - watcher $(if ($Enable) { 'ENABLE' } else { 'DISABLE' }) ===" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. The watcher Windows service
# ---------------------------------------------------------------------------
$svc = Get-Service -Name GitSecurityWatcher -ErrorAction SilentlyContinue
if (-not $svc) {
    Say "watcher service : not installed - nothing to do" DarkGray
} elseif ($Enable) {
    Set-Service -Name GitSecurityWatcher -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name GitSecurityWatcher -ErrorAction SilentlyContinue
    Say "watcher service : started, starts automatically at boot" Green
} else {
    Stop-Service -Name GitSecurityWatcher -Force -ErrorAction SilentlyContinue
    Set-Service  -Name GitSecurityWatcher -StartupType Disabled -ErrorAction SilentlyContinue
    Say "watcher service : stopped, will NOT start at boot" Yellow
}

# ---------------------------------------------------------------------------
# 2. The older PowerShell watcher scheduled task (Install-Watcher.ps1)
# ---------------------------------------------------------------------------
$wtask = Get-ScheduledTask -TaskName GitSecurityHooksWatcher -ErrorAction SilentlyContinue
if (-not $wtask) {
    Say "watcher task    : not registered - nothing to do" DarkGray
} elseif ($Enable) {
    Enable-ScheduledTask -TaskName GitSecurityHooksWatcher -ErrorAction SilentlyContinue | Out-Null
    Say "watcher task    : enabled" Green
} else {
    Stop-ScheduledTask    -TaskName GitSecurityHooksWatcher -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName GitSecurityHooksWatcher -ErrorAction SilentlyContinue | Out-Null
    Say "watcher task    : stopped and disabled" Yellow
}

# Any Watch.ps1 process still tailing from a previous boot.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*Watch.ps1*' } |
    ForEach-Object {
        if (-not $Enable) { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }

# ---------------------------------------------------------------------------
# 3. The git side - this is what must keep working at startup
# ---------------------------------------------------------------------------
$guard = Get-ScheduledTask -TaskName GitSecurityHooksGuard -ErrorAction SilentlyContinue
if ($guard) {
    Enable-ScheduledTask -TaskName GitSecurityHooksGuard -ErrorAction SilentlyContinue | Out-Null
    Say "guard task      : enabled (boot + logon + every 15 min)" Green
} else {
    Say "guard task      : NOT INSTALLED - run windows\Harden.ps1 as Admin" Red
}

if (Test-Path (Join-Path $hooks 'pre-commit')) {
    git config --global core.hooksPath ($hooks -replace '\\', '/') 2>&1 | Out-Null
    Say "core.hooksPath  : $(git config --global core.hooksPath)" Green
} else {
    Say "core.hooksPath  : hooks folder missing at $hooks - NOT set" Red
}

Write-Host ""
if ($Enable) {
    Write-Host "  Watcher re-enabled. Git hooks untouched." -ForegroundColor Green
} else {
    Write-Host "  Watcher off. Git hooks + guard task still active at startup." -ForegroundColor Green
    Write-Host "  Re-enable any time with:  .\Disable-Watcher.ps1 -Enable" -ForegroundColor DarkGray
}
Write-Host ""
