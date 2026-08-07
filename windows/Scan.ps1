<#
  windows/Scan.ps1
  Targeted or full-machine malware scan.

    .\Scan.ps1                          -> interactive prompt
    .\Scan.ps1 -Path D:\                -> one drive
    .\Scan.ps1 -Path "<any\folder>"     -> one folder
    .\Scan.ps1 -All                     -> every drive, no prompt
#>

param(
    [string]$Path,
    [switch]$All
)

$ErrorActionPreference = 'Continue'

$root    = Split-Path -Parent $PSScriptRoot
$scanner = Join-Path $root "hooks\scanner.exe"

if (-not (Test-Path $scanner)) {
    Write-Host "scanner.exe not found. Run windows\Install.ps1 first." -ForegroundColor Red
    exit 1
}

# --- Decide targets --------------------------------------------------------
$targets = @()

if ($Path) {
    if (-not (Test-Path $Path)) { Write-Host "Path not found: $Path" -ForegroundColor Red; exit 1 }
    $targets = @($Path)
}
elseif ($All) {
    $targets = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null } | Sort-Object Name | ForEach-Object { "$($_.Name):\" }
}
else {
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null } | Sort-Object Name
    Write-Host "What do you want to scan?" -ForegroundColor Cyan
    Write-Host "  [A] All drives ($([string]::Join(', ', ($drives | ForEach-Object { $_.Name + ':' }))))"
    Write-Host "  [D] One drive letter"
    Write-Host "  [P] A specific folder"
    $choice = Read-Host "Enter A, D, or P"

    switch ($choice.ToUpper()) {
        "A" { $targets = $drives | ForEach-Object { "$($_.Name):\" } }
        "D" {
            $l = (Read-Host "Drive letter (e.g. F)").TrimEnd(':', '\')
            $targets = @("$l`:\")
        }
        "P" {
            $p = Read-Host "Folder path"
            if (-not (Test-Path $p)) { Write-Host "Path not found." -ForegroundColor Red; exit 1 }
            $targets = @($p)
        }
        default { $targets = $drives | ForEach-Object { "$($_.Name):\" } }
    }
}

# --- Scan ------------------------------------------------------------------
$logDir = Join-Path $root "logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir ("scan-log-" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss") + ".txt")
$out = New-Object System.Collections.Generic.List[string]
$matches = 0

Write-Host ""
Write-Host "=== Scan started: $(Get-Date) ===" -ForegroundColor Cyan
Write-Host "Targets: $($targets -join ', ')" -ForegroundColor Cyan

$out.Add("===== Malware Scan =====")
$out.Add("Started: $(Get-Date)")
$out.Add("Targets: $($targets -join ', ')")
$out.Add("")

foreach ($t in $targets) {
    Write-Host "Scanning $t ..." -ForegroundColor Yellow
    $out.Add("---- $t ----")

    $res = & $scanner "-tree" $t 2>&1
    if ($res) {
        $res | ForEach-Object {
            Write-Host $_ -ForegroundColor Red
            $out.Add($_)
            $matches++
        }
    }
    $out.Add("")
}

$out.Add("===== Complete: $(Get-Date) =====")

if ($matches -eq 0) {
    $out.Insert(3, "VERDICT: CLEAN")
    Write-Host "`nVERDICT: CLEAN - no malware markers found." -ForegroundColor Green
} else {
    $out.Insert(3, "VERDICT: INFECTED - $matches match(es)")
    Write-Host "`nVERDICT: INFECTED - $matches match(es) found." -ForegroundColor Red
}

$out | Out-File -FilePath $logPath -Encoding utf8
Write-Host "Log: $logPath" -ForegroundColor Cyan
