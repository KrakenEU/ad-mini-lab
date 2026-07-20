# =============================================================================
# dc1-promote-forest.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

$Domain    = $env:DOMAIN
$DsrmPass  = ConvertTo-SecureString $env:DSRM_PASS -AsPlainText -Force

Write-Host "[DC1] Starting provisioning..."

# --- 0. Idempotency ----------------------------------------------------------
# If this machine is already a domain controller of the target domain, there is
# nothing to do. Vagrant re-runs provisioners on `--provision` and when it
# reconnects after a transient WinRM drop; without this guard a second run of
# Install-ADDSForest fails on the "already a DC" state with a MISLEADING error
# ("the specified argument 'DomainNetbiosName' was not recognized" - the arg
# name is a red herring, the real cause is that the forest already exists).
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.DomainRole -ge 4 -and $cs.Domain -eq $Domain) {
        Write-Host "[DC1] Already a domain controller of $Domain - nothing to do."
        exit 0
    }
} catch {}

# --- 1. Hostname -------------------------------------------------------------
if ($env:COMPUTERNAME -ne "DC1") {
    Write-Host "[DC1] Setting hostname to DC1..."
    Rename-Computer -NewName "DC1" -Force -ErrorAction SilentlyContinue
}

# --- 2. DNS -------------------------------------------------------------------
# Whatever IP DHCP actually gave this VM is fine - DC1 doesn't need a fixed
# IP for itself. Other VMs discover DC1 dynamically by NetBIOS name instead
# of a hardcoded/reserved IP (see ws01-join-domain.ps1 / dc2-child-domain.ps1).
# We only need to point DNS at ourselves here - no interface reset, which
# would otherwise drop the WinRM tunnel Vagrant is using.
Write-Host "[DC1] Setting DNS to self..."
$iface = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -ServerAddresses "127.0.0.1"
Write-Host "[DC1] DNS configured"

# --- 3. Install AD DS role --------------------------------------------------
Write-Host "[DC1] Installing AD DS role..."
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
Write-Host "[DC1] AD DS role installed"

# --- 4. Promote as first DC (no auto-reboot) --------------------------------
Write-Host "[DC1] Promoting as first domain controller for $Domain..."
Import-Module ADDSDeployment

Install-ADDSForest `
    -DomainName $Domain `
    -DomainNetbiosName ($Domain.Split(".")[0].ToUpper()) `
    -SafeModeAdministratorPassword $DsrmPass `
    -InstallDns:$true `
    -NoRebootOnCompletion:$true `
    -Force:$true | Out-Null

Write-Host "[DC1] Promotion complete, scheduling reboot in 30 seconds..."

# Reboot via a scheduled task so WinRM returns exit 0 cleanly before the machine
# goes down. The delay is 30s (not 5s) on purpose: after this provisioner exits,
# Vagrant moves to the next one and runs its wait_for_reboot check over WinRM. If
# the machine shuts down WHILE that check is mid-flight, the connection drops with
# HTTPClient::KeepAliveDisconnected, Vagrant treats it as fatal, and can even
# delete the VM. A 30s delay lets Vagrant's check register the pending reboot
# (shutdown returns 1190 "already scheduled") and start waiting BEFORE the machine
# actually goes down, which removes the race.
schtasks /Create /TN "packer-reboot" /TR "cmd /c shutdown /r /t 30 /f" /SC ONCE /ST 23:59 /RU SYSTEM /RL HIGHEST /F | Out-Null
schtasks /Run /TN "packer-reboot" | Out-Null

Write-Host "[DC1] Reboot scheduled, returning control to Vagrant"