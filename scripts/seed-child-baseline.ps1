# =============================================================================
# seed-child-baseline.ps1
#
# Runs on DC2 after it has been promoted as the child-domain DC and rebooted.
#   1. Point DC2's DNS client at itself (it hosts out.minilab.local)
#   2. Wait for the child domain's ADWS / DNS to be ready
#   3. Make cross-domain resolution deterministic: replicate the child zone
#      forest-wide and add a child -> root conditional forwarder as a fallback
#   4. Seed a clean child-domain baseline: OUs, users, groups, and the low-priv
#      "foothold" account WS01 logs in with (the attacker's starting point)
#
# NO misconfigurations here - those are applied by seed-misconfigs.ps1.
#
# Environment variables injected by Vagrant:
#   CHILD_DOMAIN, CHILD_NETBIOS, PARENT_DOMAIN, ADMIN_PASS
# =============================================================================

$ErrorActionPreference = "Stop"

$ChildDomain  = $env:CHILD_DOMAIN
$ParentDomain = $env:PARENT_DOMAIN

Write-Host "[ChildBaseline] Starting..."

# --- 1. Point our DNS client at ourselves (we host the child zone) -----------
$iface = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -ServerAddresses "127.0.0.1" -ErrorAction SilentlyContinue

# --- 2. Wait for the child domain's ADWS (and thus DNS/AD) to be ready -------
Write-Host "[ChildBaseline] Waiting for Active Directory Web Services (child)..."
Import-Module ActiveDirectory
$maxWait = 300; $interval = 10; $elapsed = 0; $ready = $false
while ($elapsed -lt $maxWait) {
    try {
        $d = Get-ADDomain -ErrorAction Stop
        if ($d.DNSRoot -eq $ChildDomain) { $ready = $true; break }
    } catch {}
    Write-Host "[ChildBaseline] Child ADWS not ready yet, waiting ${interval}s... ($elapsed/${maxWait}s)"
    Start-Sleep -Seconds $interval; $elapsed += $interval
}
if (-not $ready) { Write-Error "[ChildBaseline] Timed out waiting for the child domain's ADWS"; exit 1 }
Write-Host "[ChildBaseline] Child domain ready: $ChildDomain"

# --- 3. Deterministic cross-domain DNS (now that DNS/AD are up) --------------
# Resolve DC1 by NetBIOS (single-label names use NetBIOS/LLMNR, so this works
# even with our DNS pointed at ourselves) for the fallback conditional forwarder.
$dc1Ip = $null; $tries = 0
while (-not $dc1Ip -and $tries -lt 20) {
    try {
        $addr = [System.Net.Dns]::GetHostAddresses("DC1") | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if ($addr) { $dc1Ip = $addr.IPAddressToString }
    } catch {}
    if (-not $dc1Ip) { Start-Sleep -Seconds 10; $tries++ }
}

if ($dc1Ip) {
    try {
        if (-not (Get-DnsServerZone -Name $ParentDomain -ErrorAction SilentlyContinue)) {
            Add-DnsServerConditionalForwarderZone -Name $ParentDomain -MasterServers $dc1Ip -ErrorAction Stop
            Write-Host "[ChildBaseline] Conditional forwarder added: $ParentDomain -> $dc1Ip"
        } else {
            Write-Host "[ChildBaseline] Zone for $ParentDomain already present (forest replication), skipping forwarder"
        }
    } catch {
        Write-Host "[ChildBaseline] WARNING: could not add conditional forwarder: $($_.Exception.Message)"
    }
} else {
    Write-Host "[ChildBaseline] WARNING: could not resolve DC1 for the conditional forwarder"
}

# Replicate the child zone forest-wide so DC1 (and any other forest DC) hosts
# and resolves out.minilab.local natively - the mirror of what seed-baseline.ps1
# does for the root zone. Together these give deterministic two-way resolution.
try {
    Set-DnsServerPrimaryZone -Name $ChildDomain -ReplicationScope "Forest" -ErrorAction Stop
    Write-Host "[ChildBaseline] Child zone $ChildDomain set to forest-wide replication"
} catch {
    Write-Host "[ChildBaseline] WARNING: could not set forest replication on ${ChildDomain}: $($_.Exception.Message)"
}

# --- 4. Clean child baseline ------------------------------------------------
$Domain     = (Get-ADDomain).DistinguishedName
$DomainFqdn = (Get-ADDomain).DNSRoot

$OUs = @("Workstations", "Staff", "ServiceAccounts", "Admin")
foreach ($ou in $OUs) {
    $ouDn = "OU=$ou,$Domain"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDn'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $ou -Path $Domain -ProtectedFromAccidentalDeletion $false
        Write-Host "[ChildBaseline] Created OU: $ou"
    }
}

$Users = @(
    # Name              Sam         OU        Password         (role)
    @("John Doe",       "jdoe",     "Staff",  "Winter2025!"),   # low-priv foothold WS01 uses
    @("Sara Lin",       "slin",     "Staff",  "M4ple!River2"),
    @("Helpdesk Op",    "helpdesk", "Staff",  "Fr0ntD3sk!24"),
    @("Child Admin",    "childadm", "Admin",  "Gr4nite!Peak8")  # child Domain Admin
)
foreach ($u in $Users) {
    $name = $u[0]; $sam = $u[1]; $ou = $u[2]
    $pw   = ConvertTo-SecureString $u[3] -AsPlainText -Force
    $ouDn = "OU=$ou,$Domain"
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $name -SamAccountName $sam -UserPrincipalName "$sam@$DomainFqdn" `
            -Path $ouDn -AccountPassword $pw -Enabled $true -PasswordNeverExpires $true
        Write-Host "[ChildBaseline] Created user: $sam in $ou"
    }
}

# childadm is a real Domain Admin of the child (mid-tier target on the way up)
Add-ADGroupMember -Identity "Domain Admins" -Members "childadm" -ErrorAction SilentlyContinue

# NOTE: sAMAccountName is a single domain-wide namespace shared by users AND
# groups (case-insensitive), so a group cannot reuse a user's sAMAccountName.
# The helpdesk OPERATOR user already owns 'helpdesk', so the helpdesk GROUP is
# named IT-Helpdesk - otherwise New-ADGroup fails with "the specified account
# already exists" and (under ErrorActionPreference=Stop) aborts the whole seed.
$Groups = @("IT-Helpdesk", "Developers")
foreach ($g in $Groups) {
    if (Get-ADGroup -Filter "SamAccountName -eq '$g'" -ErrorAction SilentlyContinue) {
        Write-Host "[ChildBaseline] Group already exists: $g"
    } else {
        try {
            New-ADGroup -Name $g -SamAccountName $g -GroupScope Global -GroupCategory Security -Path "OU=Staff,$Domain" -ErrorAction Stop
            Write-Host "[ChildBaseline] Created group: $g"
        } catch {
            Write-Host "[ChildBaseline] Could not create group ${g}: $($_.Exception.Message)"
        }
    }
}
Add-ADGroupMember -Identity "IT-Helpdesk" -Members "helpdesk","jdoe" -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity "Developers"  -Members "slin"            -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "[ChildBaseline] Child baseline complete. Foothold user: $env:CHILD_NETBIOS\jdoe (pw Winter2025!)." -ForegroundColor Green
Write-Host "[ChildBaseline] Clean directory - misconfigs come from seed-misconfigs.ps1." -ForegroundColor Green
