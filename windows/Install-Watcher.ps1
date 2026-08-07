#Requires -RunAsAdministrator
<#
  windows/Install-Watcher.ps1
  Installs the real-time watcher as a hidden scheduled task that starts with
  Windows and keeps running in the background.

    .\Install-Watcher.ps1 -Path "F:\FI"
    .\Install-Watcher.ps1 -Path "F:\FI" -Quarantine
    .\Install-Watcher.ps1 -Remove
#>

param(
    [string]$Path,
    [switch]$Quarantine,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$root      = Split-Path -Parent $PSScriptRoot
$watchPs1  = Join-Path $PSScriptRoot "Watch.ps1"
$taskName  = "GitSecurityHooksWatcher"

if ($Remove) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Watcher removed." -ForegroundColor Green
    exit 0
}

if (-not $Path) {
    Write-Host "Specify what to watch, e.g.  .\Install-Watcher.ps1 -Path `"F:\FI`"" -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path $Path)) {
    Write-Host "Path not found: $Path" -ForegroundColor Red
    exit 1
}

$args = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchPs1`" -Path `"$Path`""
if ($Quarantine) { $args += " -Quarantine" }

$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $args
$tBoot     = New-ScheduledTaskTrigger -AtStartup
$tLogon    = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -Hidden -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($tBoot, $tLogon) `
    -Principal $principal -Settings $settings `
    -Description "Real-time malware watcher for git projects. Detects the payload the moment a file is written." | Out-Null

Start-ScheduledTask -TaskName $taskName

Write-Host ""
Write-Host "Real-time watcher installed and started." -ForegroundColor Green
Write-Host "  Watching   : $Path"
Write-Host "  Quarantine : $Quarantine"
Write-Host "  Log        : $root\watch-log.txt"
Write-Host "  Runs as    : SYSTEM, starts at boot, restarts if it crashes"
Write-Host ""
Write-Host "To remove:  .\Install-Watcher.ps1 -Remove" -ForegroundColor DarkGray
