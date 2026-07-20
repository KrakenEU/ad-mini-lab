# =============================================================================
# ws01-join-domain.ps1
#
# Provisioning script for WS01:
#   1. Set hostname to WS01
#   2. Discover the join DC (DC2, the child-domain DC) by NetBIOS name and
#      point DNS at it - no hardcoded/reserved IPs in this environment
#   3. Wait for that DC and the child domain to be ready
#   4. Join the CHILD domain (out.minilab.local)
#   5. Reboot
#
# WS01 is the attacker's foothold host: a normal domain workstation in the
# child domain. Interactive logons for the lab use OUT\jdoe (low priv).
#
# Environment variables injected by Vagrant:
#   DOMAIN (child FQDN), DOMAIN_NETBIOS (child NetBIOS), JOIN_DC, ADMIN_PASS
# =============================================================================

$ErrorActionPreference = "Stop"

$Domain    = $env:DOMAIN
$Netbios   = $env:DOMAIN_NETBIOS
$JoinDc    = if ($env:JOIN_DC) { $env:JOIN_DC } else { "DC2" }
$AdminPass = ConvertTo-SecureString $env:ADMIN_PASS -AsPlainText -Force
# Join with the child domain's Administrator (its password carried over from
# DC2's local Administrator when the child domain was created).
$DomainCred = New-Object System.Management.Automation.PSCredential(
    ("$Netbios\Administrator"), $AdminPass
)

Write-Host "[WS01] Starting provisioning (joining $Domain via $JoinDc)..."

# --- Idempotency: already joined? -------------------------------------------
try {
    $sys = Get-CimInstance Win32_ComputerSystem
    if ($sys.PartOfDomain -and $sys.Domain -eq $Domain) {
        Write-Host "[WS01] Already joined to $Domain - skipping."
        exit 0
    }
} catch {}

# --- 1. Hostname -------------------------------------------------------------
if ($env:COMPUTERNAME -ne "WS01") {
    Write-Host "[WS01] Setting hostname to WS01..."
    Rename-Computer -NewName "WS01" -Force -ErrorAction SilentlyContinue
}

# --- 2. Discover the join DC by name, then DNS -> that DC --------------------
Write-Host "[WS01] Resolving $JoinDc by NetBIOS name..."
$maxWait = 600; $interval = 15; $elapsed = 0; $DcIp = $null
while ($elapsed -lt $maxWait) {
    try {
        $addr = [System.Net.Dns]::GetHostAddresses($JoinDc) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if ($addr) { $DcIp = $addr.IPAddressToString; Write-Host "[WS01] Resolved $JoinDc -> $DcIp"; break }
    } catch {}
    Write-Host "[WS01] $JoinDc not resolvable yet, waiting ${interval}s... ($elapsed/${maxWait}s)"
    Start-Sleep -Seconds $interval; $elapsed += $interval
}
if (-not $DcIp) { Write-Error "[WS01] Timed out resolving $JoinDc by name"; exit 1 }

$iface = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -ServerAddresses $DcIp
Write-Host "[WS01] DNS configured -> $DcIp"

# --- 3. Wait for the child domain to be ready -------------------------------
Write-Host "[WS01] Waiting for $JoinDc ($DcIp) and $Domain to be ready..."
$elapsed = 0
while ($elapsed -lt $maxWait) {
    if (Test-Connection -ComputerName $DcIp -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        try {
            $null = Resolve-DnsName $Domain -Server $DcIp -ErrorAction Stop
            Write-Host "[WS01] DNS resolution for $Domain succeeded"
            break
        } catch { Write-Host "[WS01] DNS not ready yet, waiting ${interval}s..." }
    } else {
        Write-Host "[WS01] $JoinDc not reachable yet, waiting ${interval}s... ($elapsed/${maxWait}s)"
    }
    Start-Sleep -Seconds $interval; $elapsed += $interval
}
if ($elapsed -ge $maxWait) { Write-Error "[WS01] Timed out waiting for $Domain"; exit 1 }

Start-Sleep -Seconds 15

# --- 4. Join the child domain -----------------------------------------------
Write-Host "[WS01] Joining domain $Domain..."
Add-Computer -DomainName $Domain -Credential $DomainCred -Force -ErrorAction Stop
Write-Host "[WS01] Domain join successful"

# --- 5. Reboot --------------------------------------------------------------
Write-Host "[WS01] Rebooting to complete domain join..."
Restart-Computer -Force
