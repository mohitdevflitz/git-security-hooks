<#
  Block-NullReceiver.ps1

  NullReceiver / PolinRider malware ka network raasta band karta hai.

  Do cheezein karta hai:
    1. Known C2 IPs firewall par block
    2. Blockchain RPC endpoints block (hosts file) - malware inhi se C2 ka
       IP nikalta hai, to naya IP aane par bhi kaam nahi karega

  Chalao (Administrator PowerShell):
      powershell -ExecutionPolicy Bypass -File Block-NullReceiver.ps1

  Hataana ho to:
      powershell -ExecutionPolicy Bypass -File Block-NullReceiver.ps1 -Remove
#>

param([switch]$Remove)

$ErrorActionPreference = 'Continue'

# Admin check
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  Administrator PowerShell mein chalao." -ForegroundColor Red
    exit 1
}

$RuleName = "Block NullReceiver C2"
$Marker   = "# NullReceiver-block"
$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"

# Known C2 IPs (OpenSourceMalware / JFrog published IOCs)
$IPs = @('166.88.134.62','198.105.127.210','23.27.202.27','146.70.41.188',
         '166.88.54.158','23.27.120.142','154.91.0.103','136.0.9.8')

# Blockchain RPC endpoints jinse malware C2 ka IP resolve karta hai.
# Yahi asli choke point hai - naya C2 IP aane par bhi ye rok dega.
$Domains = @('eth.blockscout.com','1rpc.io','eth.drpc.org',
             'ethereum-rpc.publicnode.com','eth-mainnet.public.blastapi.io',
             'api.trongrid.io','fullnode.mainnet.aptoslabs.com')

Write-Host ""
Write-Host "=== NullReceiver network block ===" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
if ($Remove) {

    Get-NetFirewallRule -DisplayName "$RuleName*" -EA SilentlyContinue |
        ForEach-Object { Remove-NetFirewallRule -Name $_.Name; Write-Host "  hataya: $($_.DisplayName)" -ForegroundColor Yellow }

    $lines = Get-Content $HostsFile -EA SilentlyContinue
    if ($lines -and ($lines -match [regex]::Escape($Marker))) {
        ($lines | Where-Object { $_ -notmatch [regex]::Escape($Marker) }) |
            Set-Content $HostsFile -Encoding ASCII
        Write-Host "  hosts file se entries hatayi" -ForegroundColor Yellow
    }

    ipconfig /flushdns | Out-Null
    Write-Host ""
    Write-Host "  Block hata diya." -ForegroundColor Green
    Write-Host ""
    return
}

# --- 1. Firewall ------------------------------------------------------------
Get-NetFirewallRule -DisplayName "$RuleName*" -EA SilentlyContinue |
    ForEach-Object { Remove-NetFirewallRule -Name $_.Name }

New-NetFirewallRule -DisplayName $RuleName -Direction Outbound `
    -RemoteAddress $IPs -Action Block -Profile Any `
    -Description "PolinRider / NullReceiver known C2 servers" | Out-Null

Write-Host "  [1] Firewall: $($IPs.Count) C2 IP block kiye" -ForegroundColor Green
foreach ($i in $IPs) { Write-Host "        $i" -ForegroundColor DarkGray }

# --- 2. Hosts file ----------------------------------------------------------
# Malware pehle blockchain se poochta hai "C2 ka IP kya hai". Wo sawaal in
# endpoints se poochta hai. Ye band = naya IP aane par bhi malware andha.
Write-Host ""

$existing = Get-Content $HostsFile -EA SilentlyContinue
if ($existing -and ($existing -match [regex]::Escape($Marker))) {
    ($existing | Where-Object { $_ -notmatch [regex]::Escape($Marker) }) |
        Set-Content $HostsFile -Encoding ASCII
}

$block = @("")
foreach ($d in $Domains) {
    $block += "0.0.0.0 $d $Marker"
    $block += "0.0.0.0 www.$d $Marker"
}

try {
    Add-Content -Path $HostsFile -Value $block -Encoding ASCII -EA Stop
    Write-Host "  [2] Hosts: $($Domains.Count) blockchain RPC endpoint block kiye" -ForegroundColor Green
    foreach ($d in $Domains) { Write-Host "        $d" -ForegroundColor DarkGray }
} catch {
    Write-Host "  [2] Hosts file likhne mein dikkat: $_" -ForegroundColor Red
    Write-Host "      Defender ka 'Controlled folder access' band karke dobara try karo." -ForegroundColor Yellow
}

ipconfig /flushdns | Out-Null

# --- Summary ----------------------------------------------------------------
Write-Host ""
Write-Host "---------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Ho gaya." -ForegroundColor Green
Write-Host ""
Write-Host "  Ab agar malware chala bhi, to:" -ForegroundColor Gray
Write-Host "   - C2 ka IP blockchain se nikal hi nahi payega" -ForegroundColor Gray
Write-Host "   - Known C2 IPs par connection nahi jayega" -ForegroundColor Gray
Write-Host ""
Write-Host "  NOTE: Web3 / blockchain project banana ho to ye endpoints" -ForegroundColor DarkYellow
Write-Host "        chahiye honge. Tab -Remove se hata dena." -ForegroundColor DarkYellow
Write-Host ""
