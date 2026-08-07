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
$win  = $PSScriptRoot
$root = Split-Path -Parent $win

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

# ===========================================================================
while ($true) {
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "     GIT SECURITY HOOKS - MALWARE GUARD" -ForegroundColor Cyan
    Write-Host "     (running as Administrator)" -ForegroundColor DarkGray
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1) INSTALL - set everything up  [start here]" -ForegroundColor Green
    Write-Host "  2) Scan for malware"
    Write-Host "  3) Check status"
    Write-Host "  4) Test that blocking works"
    Write-Host "  5) Advanced (install without lockdown / re-harden)"
    Write-Host "  6) Exit"
    Write-Host ""

    switch (Read-Host "Choose 1-6") {
        "1" {
            Remove-OldInstall
            & (Join-Path $win "Install.ps1")
            & (Join-Path $win "Harden.ps1")
            Show-Status
            Invoke-SelfTest
        }
        "2" { Invoke-Scan }
        "3" { Show-Status }
        "4" { Invoke-SelfTest }
        "5" {
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
        "6" { Write-Host "Done." -ForegroundColor Cyan; exit 0 }
        default { Write-Host "Pick 1-6." -ForegroundColor Yellow }
    }
}
