<#
  windows/Watch.ps1
  Real-time protection. Watches a folder tree and reacts the moment a file
  containing malware markers is written.

  Uses a synchronous WaitForChanged loop rather than Register-ObjectEvent,
  because event actions run in a separate scope where script functions are
  not visible.

    .\Watch.ps1 -Path "F:\FI"                 # watch, alert only
    .\Watch.ps1 -Path "F:\FI" -Quarantine     # watch, alert AND clean
#>

param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$Quarantine
)

$ErrorActionPreference = 'Continue'

$root          = Split-Path -Parent $PSScriptRoot
$scanner       = Join-Path $root "hooks\scanner.exe"
$quarantineDir = Join-Path $root "quarantine"   # NOT $quarantine - that collides
$logDir        = Join-Path $root "logs"
$logFile       = Join-Path $logDir "watch-log.txt"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Host $line
    try { Add-Content -Path $logFile -Value $line -ErrorAction Stop } catch { }
}

if (-not (Test-Path $scanner)) {
    Write-Log "ERROR: scanner.exe not found at $scanner - run Install.ps1 first."
    exit 1
}
if (-not (Test-Path $Path)) {
    Write-Log "ERROR: watch path not found: $Path"
    exit 1
}

New-Item -ItemType Directory -Path $quarantineDir -Force | Out-Null

Write-Log "=== Watch started on $Path (Quarantine: $Quarantine) ==="

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path                  = $Path
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter          = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::FileName

# Remember recently handled files so a single save (which fires several
# events) is not processed over and over.
$recent = @{}

while ($true) {

    $change = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, 2000)

    if ($change.TimedOut) {
        # Periodically forget old entries so the table does not grow forever
        $cutoff = (Get-Date).AddSeconds(-10)
        foreach ($k in @($recent.Keys)) {
            if ($recent[$k] -lt $cutoff) { $recent.Remove($k) }
        }
        continue
    }

    $file = Join-Path $Path $change.Name

    # --- filters ---------------------------------------------------------
    if (-not (Test-Path $file -PathType Leaf)) { continue }
    if ($file.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if ($file -match '\\(node_modules|\.git|dist|build|\.next|\.angular)\\')  { continue }

    if ($recent.ContainsKey($file) -and $recent[$file] -gt (Get-Date).AddSeconds(-3)) { continue }
    $recent[$file] = Get-Date

    Start-Sleep -Milliseconds 200   # let the writing process finish

    # --- scan ------------------------------------------------------------
    $result = & $scanner -files $file 2>&1
    if ($LASTEXITCODE -eq 0) { continue }

    Write-Log "DETECTED: $file"
    Write-Log "   $result"

    if (-not $Quarantine) { continue }

    # --- back up then clean ----------------------------------------------
    try {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $dest  = Join-Path $quarantineDir "$stamp-$(Split-Path -Leaf $file)"
        Copy-Item -LiteralPath $file -Destination $dest -Force
        Write-Log "   Original backed up to: $dest"

        $content = Get-Content -LiteralPath $file -Raw

        # The payload is always appended after a long run of whitespace.
        # Cut from that whitespace onward, keeping the real code above it.
        $cleaned = [regex]::Replace(
            $content,
            '\s{50,}(global\s*\[|global\s*\.\s*i\s*=).*$',
            "`r`n",
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )

        if ($cleaned -ne $content) {
            Set-Content -LiteralPath $file -Value $cleaned -NoNewline -Encoding utf8
            Write-Log "   CLEANED: payload removed."
        } else {
            Write-Log "   Could not auto-clean (unexpected layout). Clean manually: $file"
        }
    }
    catch {
        Write-Log "   Quarantine/clean failed: $_"
    }
}
