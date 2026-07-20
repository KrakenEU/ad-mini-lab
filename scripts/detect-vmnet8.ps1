#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Detects vmnet8 subnet, reserves static IPs for the Packer golden images
    (server and client), and patches all HCL and autounattend.xml files.
    Run this once before your first packer build.
#>

$ErrorActionPreference = "Stop"

# Server golden image - MAC and last IP octet
$ServerMac      = "00:50:56:3A:1B:2C"
$ServerIpOctet  = "10"

# Client golden image - different MAC and last IP octet to avoid collision
$ClientMac      = "00:50:56:3A:1B:2D"
$ClientIpOctet  = "11"

$dhcpConf = "C:\ProgramData\VMware\vmnetdhcp.conf"

# --- Detect vmnet8 subnet ------------------------------------------------
$subnet  = $null
$gateway = $null

$lines = Get-Content $dhcpConf

# Find "host VMnet8" line index and scan backwards for "option routers"
$vmnet8HostIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "^host VMnet8") { $vmnet8HostIdx = $i; break }
}

if ($vmnet8HostIdx -gt 0) {
    $searchLines = $lines[0..($vmnet8HostIdx - 1)] | Select-Object -Last 20
    foreach ($line in $searchLines) {
        if ($line -match "option routers\s+([\d.]+)") {
            $gateway = $Matches[1]
            $parts   = $gateway -split "\."
            $parts[3] = "0"
            $subnet  = $parts -join "."
            break
        }
    }
}

if (-not $subnet) {
    $adapter = Get-NetIPAddress -AddressFamily IPv4 |
               Where-Object { $_.InterfaceAlias -match "vmnet8" } |
               Select-Object -First 1
    if ($adapter) {
        $parts   = $adapter.IPAddress -split "\."
        $parts[3] = "0"
        $subnet  = $parts -join "."
        $gateway = ($parts[0..2] -join ".") + ".2"
    }
}

if (-not $subnet) {
    Write-Error "Could not detect vmnet8 subnet. Make sure VMware Workstation is installed."
    exit 1
}

$parts     = $subnet -split "\."
$serverIp  = ($parts[0..2] -join ".") + ".$ServerIpOctet"
$clientIp  = ($parts[0..2] -join ".") + ".$ClientIpOctet"
if (-not $gateway) { $gateway = ($parts[0..2] -join ".") + ".2" }

Write-Host "vmnet8 subnet : $subnet"
Write-Host "Gateway       : $gateway"
Write-Host "Server IP     : $serverIp  (MAC: $ServerMac)"
Write-Host "Client IP     : $clientIp  (MAC: $ClientMac)"

# --- Add/update DHCP reservations (line-by-line, no regex) ---------------
$lines = Get-Content $dhcpConf

# Remove existing packer-golden and packer-client blocks if present
$cleanLines = New-Object System.Collections.Generic.List[string]
$insideBlock = $false
foreach ($line in $lines) {
    if ($line -match "^host packer-golden" -or $line -match "^host packer-client") {
        $insideBlock = $true; continue
    }
    if ($insideBlock -and $line -match "^\}") { $insideBlock = $false; continue }
    if ($insideBlock) { continue }
    $cleanLines.Add($line)
}

# Find the last "# End" line index
$lastEndIdx = -1
for ($i = $cleanLines.Count - 1; $i -ge 0; $i--) {
    if ($cleanLines[$i] -match "^# End") { $lastEndIdx = $i; break }
}

if ($lastEndIdx -eq -1) {
    Write-Error "Could not find '# End' marker in dhcp.conf"
    exit 1
}

$reservations = @(
    "host packer-golden {",
    "    hardware ethernet $ServerMac;",
    "    fixed-address $serverIp;",
    "}",
    "host packer-client {",
    "    hardware ethernet $ClientMac;",
    "    fixed-address $clientIp;",
    "}"
)

# Insert both reservations before the last # End
$finalLines = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $cleanLines.Count; $i++) {
    if ($i -eq $lastEndIdx) {
        foreach ($r in $reservations) { $finalLines.Add($r) }
    }
    $finalLines.Add($cleanLines[$i])
}

[System.IO.File]::WriteAllText($dhcpConf, ($finalLines -join "`r`n") + "`r`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "DHCP reservations set"

# Show tail for verification
Write-Host "--- dhcp.conf tail ---"
$finalLines | Select-Object -Last 12 | ForEach-Object { Write-Host "  $_" }
Write-Host "----------------------"

# Restart VMware DHCP service
& sc.exe stop VMnetDHCP 2>&1 | Out-Null
Start-Sleep -Seconds 2
& sc.exe start VMnetDHCP 2>&1 | Out-Null
Start-Sleep -Seconds 3
$svc = Get-Service VMnetDHCP
if ($svc.Status -eq "Running") {
    Write-Host "VMware DHCP service running" -ForegroundColor Green
} else {
    Write-Error "VMware DHCP service failed to start - check dhcp.conf manually"
    exit 1
}

# --- Patch server autounattend.xml ---------------------------------------
$serverXmlPath = Join-Path $PSScriptRoot "..\packer\answer-files\server\autounattend.xml"
$xml = [System.IO.File]::ReadAllText($serverXmlPath)
$xml = $xml -replace "%%PACKER_IP%%", $serverIp
$xml = $xml -replace "%%PACKER_GW%%", $gateway
[System.IO.File]::WriteAllText($serverXmlPath, $xml, [System.Text.UTF8Encoding]::new($false))
Write-Host "Server autounattend.xml patched: IP=$serverIp GW=$gateway"

# --- Patch client autounattend.xml ---------------------------------------
$clientXmlPath = Join-Path $PSScriptRoot "..\packer\answer-files\client\autounattend.xml"
$xml = [System.IO.File]::ReadAllText($clientXmlPath)
$xml = $xml -replace "%%CLIENT_PACKER_IP%%", $clientIp
$xml = $xml -replace "%%CLIENT_PACKER_GW%%", $gateway
[System.IO.File]::WriteAllText($clientXmlPath, $xml, [System.Text.UTF8Encoding]::new($false))
Write-Host "Client autounattend.xml patched: IP=$clientIp GW=$gateway"

# --- Patch server HCL ----------------------------------------------------
$serverHclPath = Join-Path $PSScriptRoot "..\packer\build-server\windows-server.pkr.hcl"
$hcl = [System.IO.File]::ReadAllText($serverHclPath)
$hcl = $hcl -replace 'winrm_host\s*=\s*"[^"]+"', "winrm_host     = `"$serverIp`""
[System.IO.File]::WriteAllText($serverHclPath, $hcl, [System.Text.UTF8Encoding]::new($false))
Write-Host "Server HCL patched: winrm_host=$serverIp"

# --- Patch client HCL ----------------------------------------------------
$clientHclPath = Join-Path $PSScriptRoot "..\packer\build-client\windows-client.pkr.hcl"
$hcl = [System.IO.File]::ReadAllText($clientHclPath)
$hcl = $hcl -replace 'winrm_host\s*=\s*"[^"]+"', "winrm_host     = `"$clientIp`""
[System.IO.File]::WriteAllText($clientHclPath, $hcl, [System.Text.UTF8Encoding]::new($false))
Write-Host "Client HCL patched: winrm_host=$clientIp"

Write-Host ""
Write-Host "All done. Open VMware Workstation, then run:" -ForegroundColor Green
Write-Host "  Server build:" -ForegroundColor White
Write-Host "    cd packer\build-server && packer build windows-server.pkr.hcl" -ForegroundColor White
Write-Host "  Client build:" -ForegroundColor White
Write-Host "    cd packer\build-client && packer build windows-client.pkr.hcl" -ForegroundColor White