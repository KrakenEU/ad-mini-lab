@echo off
REM =============================================================================
REM SetupComplete.cmd
REM
REM Runs automatically at the end of Windows OOBE (after sysprep clone).
REM Executed as SYSTEM before any user logs in.
REM
REM This file is placed at C:\Windows\Setup\Scripts\SetupComplete.cmd
REM by Packer during the golden image build.
REM
REM What it does:
REM   0. Forces the NIC back to DHCP (see note below)
REM   1. Sets Administrator password (matches Vagrantfile winrm.password)
REM   2. Enables WinRM with Basic auth so Vagrant can connect
REM   3. Disables firewall for lab simplicity
REM   4. Sets PowerShell execution policy
REM =============================================================================

REM 0. Force the NIC back to DHCP on every clone's first boot.
REM    The Packer build assigns a fixed static IP (10.10.10.10 server /
REM    10.10.10.11 client) via autounattend so WinRM is reachable during the
REM    build. The pre-sysprep reset-to-DHCP races against sysprep /generalize
REM    and does NOT reliably clear that static IP - it survives into the golden
REM    image, so every clone of the SAME image boots claiming the SAME static
REM    IP. With two server clones (dc1 + dc2) that means a duplicate-IP conflict:
REM    whichever boots second gets a "(Duplicate)" address, never receives a
REM    usable IP, and Vagrant hangs forever on "Waiting for the VM to receive an
REM    address". Doing the reset here - after generalize, on the freshly
REM    specialized clone - is deterministic and guarantees DHCP regardless of
REM    what static config the image carried.
netsh interface ip set address Ethernet0 dhcp
netsh interface ip set dns Ethernet0 dhcp

REM 1. Set Administrator password
net user Administrator ImThePr3sident

REM 2. Enable WinRM
powershell -ExecutionPolicy Bypass -Command "Enable-PSRemoting -Force"
powershell -ExecutionPolicy Bypass -Command "Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true"
powershell -ExecutionPolicy Bypass -Command "Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true"
powershell -ExecutionPolicy Bypass -Command "winrm set winrm/config/service @{AllowUnencrypted='true'}"
powershell -ExecutionPolicy Bypass -Command "winrm set winrm/config/service/auth @{Basic='true'}"

REM 3. Open WinRM port and disable firewall
netsh advfirewall firewall add rule name="WinRM HTTP" dir=in action=allow protocol=TCP localport=5985
powershell -ExecutionPolicy Bypass -Command "Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False"

REM 4. Set execution policy
powershell -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy Unrestricted -Scope LocalMachine -Force"

REM 5. Set network profile to Private so WinRM doesn't complain
powershell -ExecutionPolicy Bypass -Command "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private"

exit 0
