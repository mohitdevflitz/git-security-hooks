<#
  windows/Menu.ps1
  The interactive menu. Launched by RUN-WINDOWS.bat in the root folder.
  Elevates itself to Administrator automatically if needed.
#>

# --- Auto-elevate ----------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Requesting Administrator access..." -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`""
    )
    exit
}

$ErrorActionPreference = 'Continue'
$win   = $PSScriptRoot
$root  = Split-Path -Parent $win
$hooks = Join-Path $root "hooks"

# ---------------------------------------------------------------------------
function Show-Status {
    Write-Host ""
    Write-Host "--- Current status ---" -ForegroundColor Cyan

    $hp = git config --global core.hooksPath 2>$null
    if ($hp) { Write-Host "  core.hooksPath : $hp" -ForegroundColor Green }
    else      { Write-Host "  core.hooksPath : NOT SET" -ForegroundColor Yellow }

    if (Test-Path (Join-Path $root "hooks\scanner.exe")) {
        Write-Host "  scanner.exe    : present" -ForegroundColor Green
    } else {
        Write-Host "  scanner.exe    : MISSING (not installed yet)" -ForegroundColor Yellow
    }

    $task = Get-ScheduledTask -TaskName "GitSecurityHooksGuard" -ErrorAction SilentlyContinue
    if ($task) { Write-Host "  guard task     : $($task.State)" -ForegroundColor Green }
    else       { Write-Host "  guard task     : NOT INSTALLED" -ForegroundColor Yellow }

    $hooks = @("pre-commit","pre-merge-commit","pre-push","post-merge","post-checkout","post-rewrite")
    $missing = $hooks | Where-Object { -not (Test-Path (Join-Path $root "hooks\$_")) }
    if ($missing) { Write-Host "  hooks          : MISSING -> $($missing -join ', ')" -ForegroundColor Red }
    else          { Write-Host "  hooks          : all 6 present" -ForegroundColor Green }
    Write-Host ""
}

function Remove-OldInstall {
    $currentPath = git config --global core.hooksPath 2>$null
    $thisHooks   = (Join-Path $root "hooks") -replace '\\', '/'

    if ($currentPath -and ($currentPath -ne $thisHooks)) {
        Write-Host "Found a previous install at: $currentPath" -ForegroundColor Yellow
        $oldDir  = $currentPath -replace '/', '\'
        $oldRoot = if ((Split-Path -Leaf $oldDir) -eq "hooks") { Split-Path -Parent $oldDir } else { $oldDir }

        if (Test-Path $oldRoot) {
            icacls $oldRoot /reset /T /C 2>&1 | Out-Null
            Remove-Item -Recurse -Force $oldRoot -ErrorAction SilentlyContinue
            if (Test-Path $oldRoot) {
                Write-Host "  Could not fully remove $oldRoot - delete it manually later." -ForegroundColor Yellow
            } else {
                Write-Host "  Removed old install." -ForegroundColor Green
            }
        }
    }
    Unregister-ScheduledTask -TaskName "GitSecurityHooksGuard" -Confirm:$false -ErrorAction SilentlyContinue
}

function Invoke-Scan {
    Write-Host ""
    Write-Host "=== SCAN ===" -ForegroundColor Cyan
    Write-Host "  1) All drives"
    Write-Host "  2) One drive"
    Write-Host "  3) A specific folder"
    Write-Host "  4) Current git repo only"
    Write-Host "  5) Back"
    Write-Host ""

    switch (Read-Host "Choose 1-5") {
        "1" { & (Join-Path $win "Scan.ps1") -All }
        "2" {
            $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null } | Sort-Object Name
            Write-Host "Available: $([string]::Join(', ', ($drives | ForEach-Object { $_.Name + ':' })))"
            $l = (Read-Host "Drive letter").TrimEnd(':', '\')
            & (Join-Path $win "Scan.ps1") -Path "$l`:\"
        }
        "3" { & (Join-Path $win "Scan.ps1") -Path (Read-Host "Folder path") }
        "4" {
            $cur = (Get-Location).Path
            if (Test-Path (Join-Path $cur ".git")) { & (Join-Path $win "Scan.ps1") -Path $cur }
            else { Write-Host "Not a git repo: $cur" -ForegroundColor Yellow }
        }
        "5" { return }
        default { Write-Host "Invalid choice." -ForegroundColor Yellow }
    }
}

function Invoke-SelfTest {
    Write-Host ""
    Write-Host "Testing... creating a throwaway repo with a fake payload." -ForegroundColor Cyan
    $t = Join-Path $env:TEMP "hookselftest"
    Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $t | Out-Null
    Push-Location $t
    git init 2>&1 | Out-Null
    'global.i="A10-*10610";fake payload for testing' | Out-File -Encoding utf8 test.js
    git add test.js 2>&1 | Out-Null
    $out = git commit -m "self test" 2>&1
    Pop-Location
    Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue

    if ($out -match "BLOCKED") {
        Write-Host "`n  PASS - the commit was blocked as expected." -ForegroundColor Green
    } else {
        Write-Host "`n  FAIL - not blocked. Run option 1 to install." -ForegroundColor Red
        Write-Host $out -ForegroundColor DarkGray
    }
}

function Invoke-ServiceMenu {
    $svcExe = Join-Path $root "hooks\watcher-service.exe"

    while ($true) {
        Write-Host ""
        Write-Host "=== REAL-TIME WATCHER SERVICE ===" -ForegroundColor Cyan

        $svc = Get-Service -Name "GitSecurityWatcher" -ErrorAction SilentlyContinue
        if ($svc) {
            $colour = if ($svc.Status -eq "Running") { "Green" } else { "Yellow" }
            Write-Host "  Current state: $($svc.Status)" -ForegroundColor $colour
        } else {
            Write-Host "  Current state: NOT INSTALLED" -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "  1) Install - WHOLE PC, report-only   [recommended]" -ForegroundColor Green
        Write-Host "  2) Install - WHOLE PC, alert only"
        Write-Host "  3) Install - one folder only"
        Write-Host "  4) Start"
        Write-Host "  5) Stop"
        Write-Host "  6) Remove"
        Write-Host "  7) View recent log"
        Write-Host "  8) Back"
        Write-Host ""

        $c = Read-Host "Choose 1-8"

        if (-not (Test-Path $svcExe) -and $c -in @("1","2","3","4","5","6")) {
            Write-Host "watcher-service.exe not built yet. Building..." -ForegroundColor Yellow
            Push-Location (Join-Path $root "src\service")
            & go mod tidy
            & go build -o $svcExe .
            Pop-Location
            if (-not (Test-Path $svcExe)) {
                Write-Host "Build failed - is Go installed?" -ForegroundColor Red
                continue
            }
            Write-Host "Built." -ForegroundColor Green
        }

        switch ($c) {
            "1" {
                Write-Host "Installing whole-PC watcher (report-only)..." -ForegroundColor Cyan
                & $svcExe remove 2>&1 | Out-Null
                & $svcExe install -all -quarantine
                & $svcExe start
                & $alerts -Install   # detections are useless if nobody is told
                Write-Host "Note: it registers watches across all drives - this can take up to a minute." -ForegroundColor DarkGray
            }
            "2" {
                Write-Host "Installing whole-PC watcher (alert only)..." -ForegroundColor Cyan
                & $svcExe remove 2>&1 | Out-Null
                & $svcExe install -all
                & $svcExe start
                & $alerts -Install
                Write-Host "Note: it registers watches across all drives - this can take up to a minute." -ForegroundColor DarkGray
            }
            "3" {
                $default = Split-Path -Parent $root
                Write-Host ""
                Write-Host "  Press ENTER to use: $default" -ForegroundColor DarkGray
                Write-Host "  Or type a full path, or 'c' to cancel." -ForegroundColor DarkGray
                $p = Read-Host "Folder"
                if ($p -eq 'c') { continue }
                if ([string]::IsNullOrWhiteSpace($p)) { $p = $default }
                if (-not (Test-Path $p -PathType Container)) {
                    Write-Host "Not a folder: $p" -ForegroundColor Red
                    continue
                }
                & $svcExe remove 2>&1 | Out-Null
                & $svcExe install -path $p -quarantine
                & $svcExe start
                & $alerts -Install
            }
            "4" { & $svcExe start; & $alerts -EnsureRunning }
            "5" { & $svcExe stop }
            "6" { & $svcExe remove; & $alerts -Remove }
            "7" {
                $log = Join-Path $root "logs\watch-log.txt"
                if (Test-Path $log) {
                    Write-Host ""
                    Get-Content $log -Tail 25
                } else {
                    Write-Host "No log yet at $log" -ForegroundColor Yellow
                }
            }
            "8" { return }
            default { Write-Host "Pick 1-8." -ForegroundColor Yellow }
        }
    }
}

# ===========================================================================
# Make sure desktop notifications are running. The logon task normally handles
# this; -EnsureRunning is a no-op if a tail is already alive, so launching the
# menu can never end up with two of them.
$alerts = Join-Path $win "Alerts.ps1"
if (Test-Path $alerts) { & $alerts -EnsureRunning | Out-Null }

while ($true) {
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "     GIT SECURITY HOOKS - MALWARE GUARD" -ForegroundColor Cyan
    Write-Host "     (running as Administrator)" -ForegroundColor DarkGray
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1) INSTALL EVERYTHING  [start here]" -ForegroundColor Green
    Write-Host "     hooks + service + self-test" -ForegroundColor DarkGray
    Write-Host "  2) Scan for malware"
    Write-Host "  3) Real-time watcher service (install/start/stop/remove)"
    Write-Host "  4) Desktop notifications (start/stop/test)"
    Write-Host "  5) Check status"
    Write-Host "  6) Test that blocking works"
    Write-Host "  7) STOP / START all protection" -ForegroundColor Yellow
    Write-Host "  8) Advanced (install without lockdown / re-harden)"
    Write-Host "  9) Exit"
    Write-Host ""

    switch (Read-Host "Choose 1-9") {
        "1" {
            Remove-OldInstall
            & (Join-Path $win "Install-Everything.ps1")
        }
        "2" { Invoke-Scan }
        "3" { Invoke-ServiceMenu }
        "4" {
            Write-Host ""
            Write-Host "  a) Start / enable at logon"
            Write-Host "  b) Send a test toast"
            Write-Host "  c) Status"
            Write-Host "  d) Stop and disable"
            Write-Host "  e) Back"
            switch ((Read-Host "Choose a-e").ToLower()) {
                "a" { & $alerts -Install }
                "b" { & $alerts -Test }
                "c" { & $alerts -Status }
                "d" { & $alerts -Remove }
                default { }
            }
        }
        "5" { Show-Status }
        "6" { Invoke-SelfTest }
        "7" {
            Write-Host ""
            Write-Host "  a) STOP everything   (pause protection - keeps it installed)" -ForegroundColor Yellow
            Write-Host "  b) START everything  (resume)" -ForegroundColor Green
            Write-Host "  c) Back"
            switch ((Read-Host "Choose a-c").ToLower()) {
                "a" {
                    Write-Host ""
                    Write-Host "Stopping watcher service..." -ForegroundColor Cyan
                    Stop-Service GitSecurityWatcher -Force -EA SilentlyContinue

                    Write-Host "Stopping desktop notifications..." -ForegroundColor Cyan
                    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
                        Where-Object { $_.CommandLine -like '*GSH_ALERTS_TAIL*' } |
                        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }

                    Write-Host "Disabling git commit/push blocking..." -ForegroundColor Cyan
                    git config --global --unset core.hooksPath 2>&1 | Out-Null

                    Write-Host "Pausing the self-healing guard task..." -ForegroundColor Cyan
                    Disable-ScheduledTask -TaskName GitSecurityHooksGuard -EA SilentlyContinue | Out-Null

                    Write-Host ""
                    Write-Host "  ALL PROTECTION STOPPED." -ForegroundColor Red
                    Write-Host "  Nothing was uninstalled - choose (b) to resume." -ForegroundColor DarkGray
                    Show-Status
                }
                "b" {
                    Write-Host ""
                    Write-Host "Starting watcher service..." -ForegroundColor Cyan
                    Start-Service GitSecurityWatcher -EA SilentlyContinue

                    Write-Host "Re-enabling git commit/push blocking..." -ForegroundColor Cyan
                    # Guard against writing an empty value - that silently
                    # disables hooks while looking like it succeeded.
                    if ((Test-Path (Join-Path $hooks 'pre-commit'))) {
                        git config --global core.hooksPath ($hooks -replace '\\','/') 2>&1 | Out-Null
                    } else {
                        Write-Host "  hooks folder not found at $hooks - NOT setting hooksPath" -ForegroundColor Red
                    }

                    Write-Host "Resuming the self-healing guard task..." -ForegroundColor Cyan
                    Enable-ScheduledTask -TaskName GitSecurityHooksGuard -EA SilentlyContinue | Out-Null

                    Write-Host "Starting desktop notifications..." -ForegroundColor Cyan
                    & $alerts -EnsureRunning

                    Write-Host ""
                    Write-Host "  ALL PROTECTION RUNNING." -ForegroundColor Green
                    Show-Status
                }
                default { }
            }
        }
        "8" {
            Write-Host ""
            Write-Host "  a) Install only (no lockdown)"
            Write-Host "  b) Harden only (lock down existing install)"
            Write-Host "  c) Back"
            switch ((Read-Host "Choose a-c").ToLower()) {
                "a" { & (Join-Path $win "Install.ps1"); Show-Status }
                "b" { & (Join-Path $win "Harden.ps1");  Show-Status }
                default { }
            }
        }
        "9" { Write-Host "Done." -ForegroundColor Cyan; exit 0 }
        default { Write-Host "Pick 1-9." -ForegroundColor Yellow }
    }
}
