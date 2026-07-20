# =============================================================================
# dc2-child-domain.ps1
#
# Promotes DC2 as the FIRST domain controller of a NEW CHILD DOMAIN
# (out.minilab.local) beneath the forest root (minilab.local).
#
#   1. Set hostname to DC2
#   2. Discover DC1 (the forest root) by NetBIOS name, point DNS at it so the
#      parent domain resolves (no hardcoded/reserved IPs in this environment)
#   3. Wait for DC1 / the root domain to be reachable
#   4. Install AD DS role
#   5. Install-ADDSDomain -DomainType ChildDomain  (this also creates the
#      automatic bidirectional parent<->child trust)
#   6. Reboot via scheduled task (same pattern as dc1-promote-forest.ps1)
#
# The child domain's built-in Administrator inherits DC2's local Administrator
# password (ImThePr3sident), just like the forest root did on DC1.
#
# Environment variables injected by Vagrant:
#   PARENT_DOMAIN, PARENT_NETBIOS, CHILD_LABEL, CHILD_NETBIOS, DSRM_PASS, ADMIN_PASS
# =============================================================================

$ErrorActionPreference = "Stop"

$ParentDomain  = $env:PARENT_DOMAIN
$ParentNetbios = $env:PARENT_NETBIOS
$ChildLabel    = $env:CHILD_LABEL
$ChildNetbios  = $env:CHILD_NETBIOS
$DsrmPass      = ConvertTo-SecureString $env:DSRM_PASS -AsPlainText -Force
$AdminPass     = ConvertTo-SecureString $env:ADMIN_PASS -AsPlainText -Force

# Creating a child domain requires ENTERPRISE ADMIN of the forest, i.e. the
# root domain's Administrator (its password carried over from DC1's local
# Administrator at forest promotion time). The username MUST use the DNS domain
# form (minilab.local\Administrator), NOT the NetBIOS form (MINILAB\...):
# Install-ADDSDomain validates that the credential's domain is DNS-resolvable
# and rejects the NetBIOS form with "You must supply a DNS resolvable domain
# name to which this user account belongs."
$EnterpriseCred = New-Object System.Management.Automation.PSCredential(
    ("$ParentDomain\Administrator"), $AdminPass
)

Write-Host "[DC2] Starting child-domain provisioning..."

# --- Idempotency: already a DC? ---------------------------------------------
try {
    $sys = Get-CimInstance Win32_ComputerSystem
    if ($sys.DomainRole -ge 4) {
        Write-Host "[DC2] This machine is already a domain controller - skipping promotion."
        exit 0
    }
} catch {}

# --- 1. Hostname -------------------------------------------------------------
if ($env:COMPUTERNAME -ne "DC2") {
    Write-Host "[DC2] Setting hostname to DC2..."
    Rename-Computer -NewName "DC2" -Force -ErrorAction SilentlyContinue
}

# --- 2. Discover DC1 by name, point DNS at it --------------------------------
Write-Host "[DC2] Resolving DC1 (forest root) by NetBIOS name..."
$maxWait = 600; $interval = 15; $elapsed = 0; $Dc1Ip = $null
while ($elapsed -lt $maxWait) {
    try {
        $addr = [System.Net.Dns]::GetHostAddresses("DC1") | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if ($addr) { $Dc1Ip = $addr.IPAddressToString; Write-Host "[DC2] Resolved DC1 -> $Dc1Ip"; break }
    } catch {}
    Write-Host "[DC2] DC1 not resolvable yet, waiting ${interval}s... ($elapsed/${maxWait}s)"
    Start-Sleep -Seconds $interval; $elapsed += $interval
}
if (-not $Dc1Ip) { Write-Error "[DC2] Timed out resolving DC1 by name"; exit 1 }

$iface = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -ServerAddresses $Dc1Ip
Write-Host "[DC2] DNS configured -> $Dc1Ip"

# --- 3. Wait for the root domain to answer ----------------------------------
Write-Host "[DC2] Waiting for the root domain ($ParentDomain) to be resolvable..."
$elapsed = 0
while ($elapsed -lt $maxWait) {
    if (Test-Connection -ComputerName $Dc1Ip -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        try {
            $null = Resolve-DnsName $ParentDomain -Server $Dc1Ip -ErrorAction Stop
            Write-Host "[DC2] Root domain $ParentDomain resolves"
            break
        } catch { Write-Host "[DC2] Root DNS not ready yet, waiting ${interval}s..." }
    } else {
        Write-Host "[DC2] DC1 not reachable yet, waiting ${interval}s... ($elapsed/${maxWait}s)"
    }
    Start-Sleep -Seconds $interval; $elapsed += $interval
}
if ($elapsed -ge $maxWait) { Write-Error "[DC2] Timed out waiting for the root domain"; exit 1 }

Start-Sleep -Seconds 15

# --- 4. Install AD DS role --------------------------------------------------
Write-Host "[DC2] Installing AD DS role..."
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
Write-Host "[DC2] AD DS role installed"

# --- 5. Promote as first DC of the child domain -----------------------------
Write-Host "[DC2] Creating child domain $ChildLabel.$ParentDomain (NetBIOS $ChildNetbios)..."
Import-Module ADDSDeployment

# A child-domain promotion REQUIRES a DNS delegation in the parent zone:
# Install-ADDSDomain hard-fails its prerequisite check with
# -CreateDnsDelegation:$false ("A delegation must be created in order to
# continue with promotion"). We hold the Enterprise Admin credential and DC1's
# minilab.local zone is Windows DNS and reachable, so the delegation is created
# cleanly. On top of that, seed-baseline.ps1 / seed-child-baseline.ps1 also
# replicate both zones forest-wide (+ a child->root conditional forwarder), so
# every DC ends up hosting and resolving both domains.
$threw = $false
try {
    Install-ADDSDomain `
        -NewDomainName $ChildLabel `
        -ParentDomainName $ParentDomain `
        -NewDomainNetbiosName $ChildNetbios `
        -DomainType ChildDomain `
        -Credential $EnterpriseCred `
        -SafeModeAdministratorPassword $DsrmPass `
        -InstallDns:$true `
        -CreateDnsDelegation:$true `
        -NoRebootOnCompletion:$true `
        -Force:$true -ErrorAction Stop | Out-Null
    Write-Host "[DC2] Install-ADDSDomain returned without error"
} catch {
    # A SUCCESSFUL child-domain promotion still reports "You must restart this
    # computer to complete the operation" - which surfaces as a TERMINATING
    # error under $ErrorActionPreference='Stop' even though the domain WAS
    # created. (Install-ADDSForest on DC1 does not do this; Install-ADDSDomain
    # does.) Don't trust the throw - verify the real outcome below instead.
    $threw = $true
    Write-Host "[DC2] Install-ADDSDomain reported: $($_.Exception.Message)"
}

# dcpromo.log confirms the DomainRole flip is intentionally deferred to the
# reboot (it writes a DSROLEP_DCLOCATOR_PREREBOOT_HINT key on a clean finish),
# so checking DomainRole right after a run that DIDN'T throw is invalid - it
# will read 3 even on full success. Only use the role check to disambiguate
# the known false-failure case above, when an exception actually happened.
if ($threw) {
    Start-Sleep -Seconds 5
    $role = (Get-CimInstance Win32_ComputerSystem).DomainRole
    if ($role -lt 4) {
        Write-Host "[DC2] DomainRole=$role after an exception - dumping dcpromo.log tail:"
        $dcpromoLog = "C:\Windows\debug\dcpromo.log"
        if (Test-Path $dcpromoLog) {
            Get-Content $dcpromoLog -Tail 60 | ForEach-Object { Write-Host "[dcpromo.log] $_" }
        } else {
            Write-Host "[DC2] $dcpromoLog not found"
        }
        Write-Error "[DC2] Child domain promotion did not complete (DomainRole=$role)"
        exit 1
    }
    Write-Host "[DC2] Confirmed DomainRole=$role despite the exception - promotion actually succeeded"
}

Write-Host "[DC2] Child domain promotion finished, scheduling reboot in 30 seconds..."

# 30s delay, not 5s: Vagrant runs its wait_for_reboot check over WinRM as it moves
# to the next provisioner. If the machine shuts down mid-check the connection drops
# fatally (KeepAliveDisconnected) and the VM can be deleted. The longer delay lets
# Vagrant register the pending reboot and start waiting before the machine goes
# down. See dc1-promote-forest.ps1 for the full explanation.
schtasks /Create /TN "packer-reboot" /TR "cmd /c shutdown /r /t 30 /f" /SC ONCE /ST 23:59 /RU SYSTEM /RL HIGHEST /F | Out-Null
schtasks /Run /TN "packer-reboot" | Out-Null

Write-Host "[DC2] Reboot scheduled, returning control to Vagrant"
