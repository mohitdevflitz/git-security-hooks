<#
  windows/Clean-Payload.ps1

  Strips the appended malware payload from source files, in place.

  How the payload is identified:
    The loader is ALWAYS appended to the end of an existing file, after a long
    run of whitespace, starting with `global.i="A10` or `global['!']=`. So the
    fix is to cut from that whitespace run to end-of-file and keep everything
    before it. That is the original file, byte for byte.

  Safety:
    - Dry run by default. Nothing is written unless you pass -Apply.
    - Every modified file is backed up to <file>.infected-backup first.
    - Only touches files where the payload is STRUCTURALLY present (appended
      after 50+ whitespace chars). A file that merely mentions a marker
      (documentation, a log, this project's own source) is left alone.

  Usage:
    .\Clean-Payload.ps1 -Path F:\FI                 # dry run, shows what it would do
    .\Clean-Payload.ps1 -Path F:\FI -Apply          # actually clean
    .\Clean-Payload.ps1 -Path F:\FI\bellass-nextjs -Apply
#>

param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$Apply
)

$ErrorActionPreference = 'Continue'

$exts = @('.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx', '.mts', '.cts', '.json', '.vue', '.svelte')
$skip = @('\node_modules\', '\.git\', '\dist\', '\build\', '\.next\', '\.angular\',
          '\git-security-hooks\', '\quarantine\', '\evidence\')

# The payload always begins after a long whitespace run. Two known variants.
$payload = [regex]::new(
    '(?s)\s{50,}(global\s*\.\s*i\s*=\s*"A10|global\s*\[\s*[''"]![''"]\s*\]\s*=|global\s*\.\s*i\s*=\s*''A10).*$'
)

Write-Host ""
Write-Host "=== Payload cleaner ===" -ForegroundColor Cyan
Write-Host " Scanning : $Path"
Write-Host " Mode     : $(if ($Apply) { 'APPLY - files will be modified' } else { 'DRY RUN - nothing will be written' })" -ForegroundColor $(if ($Apply) { 'Yellow' } else { 'Green' })
Write-Host ""

$found = 0
$fixed = 0

Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $exts -contains $_.Extension.ToLower() -and $_.Length -lt 20MB
    } |
    ForEach-Object {

        $full = $_.FullName.ToLower().Replace('/', '\')
        foreach ($s in $skip) { if ($full.Contains($s)) { return } }

        try   { $text = [System.IO.File]::ReadAllText($_.FullName) }
        catch { return }

        $m = $payload.Match($text)
        if (-not $m.Success) { return }

        $found++
        $cleaned = $text.Substring(0, $m.Index).TrimEnd() + "`n"
        $removed = $text.Length - $cleaned.Length

        Write-Host "  FOUND " -ForegroundColor Red -NoNewline
        Write-Host "$($_.FullName)"
        Write-Host "         payload starts at offset $($m.Index), removing $removed bytes" -ForegroundColor DarkGray

        if ($Apply) {
            $backup = "$($_.FullName).infected-backup"
            if (-not (Test-Path $backup)) {
                Copy-Item -LiteralPath $_.FullName -Destination $backup -Force
            }
            [System.IO.File]::WriteAllText($_.FullName, $cleaned)
            Write-Host "         CLEANED (backup: $(Split-Path $backup -Leaf))" -ForegroundColor Green
            $fixed++
        }
    }

Write-Host ""
Write-Host "---------------------------------------------" -ForegroundColor DarkGray
if ($found -eq 0) {
    Write-Host "  No infected files found." -ForegroundColor Green
} elseif ($Apply) {
    Write-Host "  $fixed file(s) cleaned, $found found." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next: review with 'git diff', then commit and push." -ForegroundColor Yellow
    Write-Host "  Delete the .infected-backup files once you are happy." -ForegroundColor DarkGray
} else {
    Write-Host "  $found infected file(s) found. Nothing changed." -ForegroundColor Yellow
    Write-Host "  Re-run with -Apply to clean them." -ForegroundColor Yellow
}
Write-Host ""
