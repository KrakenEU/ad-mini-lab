# =============================================================================
# seed-baseline.ps1
#
# Seeds the FOREST ROOT domain (minilab.local) with a clean, realistic
# structure: OUs, users and groups. NO intentional misconfigurations - the lab
# starts from a healthy directory. All the exploitable misconfigs are applied
# separately by seed-misconfigs.ps1 so they can be toggled/demoed one at a time.
#
# Runs on DC1 after the forest is promoted.
#
# Environment variables injected by Vagrant:
#   DOMAIN
# =============================================================================

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory

# WinRM comes back quickly after the post-promotion reboot, but Active
# Directory Web Services (needed by the AD cmdlets) takes longer to start.
# Poll until it's actually ready instead of racing it.
Write-Host "[Baseline] Waiting for Active Directory Web Services to be ready..."
$maxWait  = 300
$interval = 10
$elapsed  = 0
$ready    = $false
while ($elapsed -lt $maxWait) {
    try {
        $null = Get-ADDomain -ErrorAction Stop
        $ready = $true
        break
    } catch {
        Write-Host "[Baseline] ADWS not ready yet, waiting ${interval}s... ($elapsed/${maxWait}s)"
        Start-Sleep -Seconds $interval
        $elapsed += $interval
    }
}
if (-not $ready) {
    Write-Error "[Baseline] Timed out waiting for Active Directory Web Services"
    exit 1
}
Write-Host "[Baseline] Active Directory Web Services is ready"

$Domain     = (Get-ADDomain).DistinguishedName
$DomainFqdn = (Get-ADDomain).DNSRoot

Write-Host "[Baseline] Seeding forest root domain: $DomainFqdn ($Domain)"

# =============================================================================
# OUs
# =============================================================================
$OUs = @("IT", "Finance", "HR", "Servers", "Tier0")
foreach ($ou in $OUs) {
    $ouDn = "OU=$ou,$Domain"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDn'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $ou -Path $Domain -ProtectedFromAccidentalDeletion $false
        Write-Host "[Baseline] Created OU: $ou"
    } else {
        Write-Host "[Baseline] OU already exists: $ou"
    }
}

# =============================================================================
# Users
# =============================================================================
# Each user gets its own password. Some are weak/seasonal on purpose (good for
# password-spray practice), others are stronger.
$Users = @(
    # Name             Sam          OU         Password
    @("Alice Cooper",  "alice",     "IT",      "Autumn2024!"),
    @("Bob Marley",    "bob",       "IT",      "Summer2025!"),
    @("Carol Smith",   "carol",     "Finance", "F1nanceGrp!7"),
    @("Dave Johnson",  "dave",      "Finance", "Pl4tinum!Key"),
    @("Eve Adams",     "eve",       "HR",      "Spring2024!"),
    @("Frank Castle",  "frank",     "HR",      "Bl4ckHawk#7"),
    # A forest-root tier-0 admin, the ultimate cross-domain escalation target.
    @("Root Admin",    "rootadmin", "Tier0",   "Str0ng!Vault#9")
)

foreach ($u in $Users) {
    $name = $u[0]; $sam = $u[1]; $ou = $u[2]
    $pw   = ConvertTo-SecureString $u[3] -AsPlainText -Force
    $ouDn = "OU=$ou,$Domain"
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $name -SamAccountName $sam -UserPrincipalName "$sam@$DomainFqdn" `
            -Path $ouDn -AccountPassword $pw -Enabled $true -PasswordNeverExpires $true
        Write-Host "[Baseline] Created user: $sam in $ou"
    } else {
        Write-Host "[Baseline] User already exists: $sam"
    }
}

# rootadmin is a real forest admin (Domain Admins of the root = high value)
Add-ADGroupMember -Identity "Domain Admins" -Members "rootadmin" -ErrorAction SilentlyContinue

# =============================================================================
# Groups
# =============================================================================
$Groups = @(
    @("IT-Admins",     "IT"),
    @("IT-HelpDesk",   "IT"),
    @("Finance-Users", "Finance"),
    @("HR-Users",      "HR")
)

foreach ($g in $Groups) {
    $groupName = $g[0]; $ou = $g[1]
    $ouDn = "OU=$ou,$Domain"
    if (-not (Get-ADGroup -Filter "Name -eq '$groupName'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $groupName -SamAccountName $groupName -GroupScope Global `
            -GroupCategory Security -Path $ouDn
        Write-Host "[Baseline] Created group: $groupName"
    } else {
        Write-Host "[Baseline] Group already exists: $groupName"
    }
}

Add-ADGroupMember -Identity "IT-Admins"     -Members "alice"          -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity "IT-HelpDesk"   -Members "bob"            -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity "Finance-Users" -Members "carol","dave"   -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity "HR-Users"      -Members "eve","frank"    -ErrorAction SilentlyContinue
Write-Host "[Baseline] Group memberships configured"

# =============================================================================
# Forest-wide DNS for the root zone
# =============================================================================
# Replicate minilab.local to the ForestDnsZones partition so that once the
# child DC (DC2) joins the forest it hosts and can resolve the root zone
# natively - deterministic cross-domain name resolution without relying on the
# flaky dcpromo DNS-delegation step.
#
# Right after promotion, ADWS answers before the ForestDnsZones/DomainDnsZones
# application partitions have finished settling, so the first attempt here
# routinely fails with "Failed to reset the directory partition for zone...".
# Retry instead of accepting the first failure - if this silently stays on a
# warning, DC2's child-domain promotion later has to fall back to dcpromo's
# own DNS-delegation creation, which is the flaky path this was meant to avoid.
$dnsMaxWait  = 120
$dnsInterval = 10
$dnsElapsed  = 0
$dnsReady    = $false
while ($dnsElapsed -lt $dnsMaxWait) {
    try {
        Set-DnsServerPrimaryZone -Name $DomainFqdn -ReplicationScope "Forest" -ErrorAction Stop
        Write-Host "[Baseline] Root zone $DomainFqdn set to forest-wide replication"
        $dnsReady = $true
        break
    } catch {
        Write-Host "[Baseline] Forest replication not ready yet ($($_.Exception.Message)), retrying in ${dnsInterval}s... ($dnsElapsed/${dnsMaxWait}s)"
        Start-Sleep -Seconds $dnsInterval
        $dnsElapsed += $dnsInterval
    }
}
if (-not $dnsReady) {
    Write-Host "[Baseline] WARNING: could not set forest replication on $DomainFqdn after ${dnsMaxWait}s - DC2 will have to rely on dcpromo's own DNS delegation step"
}

Write-Host ""
Write-Host "[Baseline] Forest root baseline complete (clean, no misconfigs)." -ForegroundColor Green
