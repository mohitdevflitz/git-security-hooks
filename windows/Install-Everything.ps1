#Requires -RunAsAdministrator
<#
  windows/Install-Everything.ps1

  One-shot full install. Does the lot, in order, and reports what worked:

    1. Go (via winget if missing)
    2. scanner.exe            - the detection engine
    3. Git hooks              - blocks commit / merge / push
    4. Hardening              - locks files, self-healing task
    5. watcher-service.exe    - real-time whole-PC detection (report-only)
                              + desktop notifications at logon
    6. Self-test              - proves blocking actually works

  Run:
    .\Install-Everything.ps1
    .\Install-Everything.ps1 -NoHarden      (skip the file lockdown)
    .\Install-Everything.ps1 -Uninstall
#>

param(
    [switch]$NoHarden,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Continue'

$win   = $PSScriptRoot
$root  = Split-Path -Parent $win
$hooks = Join-Path $root "hooks"

$results = [ordered]@{}

function Step($name, $block) {
    Write-Host ""
    Write-Host "----------------------------------------------" -ForegroundColor DarkGray
    Write-Host " $name" -ForegroundColor Cyan
    Write-Host "----------------------------------------------" -ForegroundColor DarkGray
    try {
        & $block
        $results[$name] = "OK"
    } catch {
        Write-Host "  FAILED: $_" -ForegroundColor Red
        $results[$name] = "FAILED - $_"
    }
}

# ===========================================================================
# UNINSTALL
# ===========================================================================
if ($Uninstall) {
    Write-Host "Removing everything..." -ForegroundColor Yellow

    & (Join-Path $hooks "watcher-service.exe") remove 2>&1 | Out-Null
    & (Join-Path $win "Alerts.ps1") -Remove 2>&1 | Out-Null
    Unregister-ScheduledTask -TaskName "GitSecurityHooksGuard"   -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "GitSecurityHooksWatcher" -Confirm:$false -ErrorAction SilentlyContinue
    git config --global --unset core.hooksPath 2>&1 | Out-Null
    icacls $root /reset /T /C 2>&1 | Out-Null

    Write-Host ""
    Write-Host "Uninstalled. The folder itself was left in place." -ForegroundColor Green
    exit 0
}

# ===========================================================================
# INSTALL
# ===========================================================================
Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "   GIT SECURITY HOOKS - FULL INSTALL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " Installing to: $root"

# --- 1. Go -----------------------------------------------------------------
Step "1/6  Go toolchain" {
    if (Get-Command go -ErrorAction SilentlyContinue) {
        Write-Host "  Already installed: $(go version)" -ForegroundColor Green
    } else {
        Write-Host "  Installing via winget..." -ForegroundColor Yellow
        winget install --id GoLang.Go -e --accept-source-agreements --accept-package-agreements
        $env:Path += ";C:\Program Files\Go\bin"
        if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
            throw "Go installed but not on PATH. Close PowerShell, reopen as Admin, re-run."
        }
        Write-Host "  Installed." -ForegroundColor Green
    }
}

# --- 2. Scanner ------------------------------------------------------------
Step "2/6  Detection engine (scanner.exe)" {
    Push-Location (Join-Path $root "src")
    & go build -o (Join-Path $hooks "scanner.exe") scanner.go
    Pop-Location
    if (-not (Test-Path (Join-Path $hooks "scanner.exe"))) { throw "build produced no binary" }
    Write-Host "  Built." -ForegroundColor Green
}

# --- 3. Git hooks ----------------------------------------------------------
Step "3/6  Git hooks" {
    $hooksGit = $hooks -replace '\\', '/'
    git config --global core.hooksPath $hooksGit
    Write-Host "  core.hooksPath -> $hooksGit" -ForegroundColor Green
}

# --- 4. Hardening ----------------------------------------------------------
if ($NoHarden) {
    Write-Host ""
    Write-Host " 4/6  Hardening - SKIPPED (-NoHarden)" -ForegroundColor DarkGray
    $results["4/6  Hardening"] = "skipped"
} else {
    Step "4/6  Hardening (lockdown + self-healing)" {
        & (Join-Path $win "Harden.ps1")
    }
}

# --- 5. Watcher service ----------------------------------------------------
Step "5/6  Real-time watcher service" {
    Push-Location (Join-Path $root "src\service")
    & go mod tidy
    & go build -o (Join-Path $hooks "watcher-service.exe") .
    Pop-Location

    $svc = Join-Path $hooks "watcher-service.exe"
    if (-not (Test-Path $svc)) { throw "build produced no binary" }

    & $svc remove 2>&1 | Out-Null
    & $svc install -all -quarantine
    & $svc start
    Write-Host "  Installed and started (whole PC, report-only)." -ForegroundColor Green

    # Desktop notifications. Registered for the logged-in user, not SYSTEM -
    # a service in session 0 cannot show a toast on the interactive desktop.
    & (Join-Path $win "Alerts.ps1") -Install
}

# --- 6. Self-test ----------------------------------------------------------
Step "6/6  Self-test" {
    $t = Join-Path $env:TEMP "gsh-selftest"
    Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $t | Out-Null
    Push-Location $t
    git init 2>&1 | Out-Null
    'global.i="A10-*10610";self test payload' | Out-File -Encoding utf8 t.js
    git add t.js 2>&1 | Out-Null
    $out = git commit -m "self test" 2>&1
    Pop-Location
    Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue

    if ($out -match "BLOCKED") {
        Write-Host "  PASS - malicious commit was blocked." -ForegroundColor Green
    } else {
        throw "commit was NOT blocked - hooks are not working"
    }
}

# ===========================================================================
# SUMMARY
# ===========================================================================
Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "   SUMMARY" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

$failed = 0
foreach ($k in $results.Keys) {
    $v = $results[$k]
    if ($v -eq "OK") {
        Write-Host ("  {0,-40} OK" -f $k) -ForegroundColor Green
    } elseif ($v -eq "skipped") {
        Write-Host ("  {0,-40} skipped" -f $k) -ForegroundColor DarkGray
    } else {
        Write-Host ("  {0,-40} {1}" -f $k, $v) -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "  Everything installed and verified." -ForegroundColor Green
    Write-Host "  Detections are written to logs\watch-log.txt" -ForegroundColor DarkGray
} else {
    Write-Host "  $failed step(s) failed - see the errors above." -ForegroundColor Red
}
Write-Host ""
