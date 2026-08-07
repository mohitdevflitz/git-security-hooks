#Requires -RunAsAdministrator
<#
  windows/Install.ps1
  Builds the scanner and wires the hooks into git for every repo on this PC.

  Run as Administrator:
    .\Install.ps1
#>

$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent $PSScriptRoot      # repo root (git-security-hooks)
$hooksDir = Join-Path $root "hooks"
$srcDir   = Join-Path $root "src"
$hooksDirGit = $hooksDir -replace '\\', '/'

Write-Host "=== Git Security Hooks - Windows Install ===" -ForegroundColor Cyan
Write-Host "Root:  $root"
Write-Host "Hooks: $hooksDir"
Write-Host ""

# --- 1. Go -----------------------------------------------------------------
if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    Write-Host "Go not found. Installing via winget..." -ForegroundColor Yellow
    winget install --id GoLang.Go -e --accept-source-agreements --accept-package-agreements
    $env:Path += ";C:\Program Files\Go\bin"
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        Write-Host "Go installed but not on PATH yet. Close PowerShell, reopen as Admin, re-run this script." -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "Go already installed." -ForegroundColor Green
}

# --- 2. Build --------------------------------------------------------------
Write-Host "Building scanner.exe into hooks\ ..." -ForegroundColor Cyan
Push-Location $srcDir
& go build -o (Join-Path $hooksDir "scanner.exe") scanner.go
Pop-Location

if (-not (Test-Path (Join-Path $hooksDir "scanner.exe"))) {
    Write-Error "Build failed - scanner.exe not created."
    exit 1
}
Write-Host "scanner.exe built." -ForegroundColor Green

# --- 3. Wire up git --------------------------------------------------------
git config --global core.hooksPath $hooksDirGit
Write-Host "core.hooksPath -> $hooksDirGit" -ForegroundColor Green

# --- 4. Verify -------------------------------------------------------------
Write-Host ""
Write-Host "=== Verification ===" -ForegroundColor Cyan
Write-Host "core.hooksPath = $(git config --global core.hooksPath)"
Write-Host "Hooks present:"
Get-ChildItem $hooksDir -File | ForEach-Object { Write-Host "  $($_.Name)" }
Write-Host ""
Write-Host "Install complete. Run .\Harden.ps1 next to lock it down." -ForegroundColor Green
