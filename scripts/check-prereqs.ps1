#Requires -Version 5.1
<#
.SYNOPSIS
    Validates that the environment has everything needed to build the AD Mini-Lab.

.DESCRIPTION
    Checks VMware Workstation, Vagrant, the vagrant-vmware-desktop plugin,
    the Vagrant VMware Utility service, Packer, 7-Zip, nested virtualization,
    available RAM, disk space, the presence of the required ISOs, and
    WinRM host configuration required for Packer to communicate with VMs.

    This script doesn't install anything for you: it just tells you exactly
    what's missing and how to fix it, before you waste time on a build that
    fails halfway through.

    Must be run as Administrator (required for WinRM checks).

.EXAMPLE
    .\check-prereqs.ps1
#>

[CmdletBinding()]
param(
    [string]$IsoDirectory = (Join-Path $PSScriptRoot "..\packer\isos"),
    [int]$MinRamGB = 16,
    [int]$RecommendedRamGB = 32,
    [int]$MinFreeDiskGB = 60
)

$ErrorActionPreference = "SilentlyContinue"
$script:Issues = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Write-CheckHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
    $script:Issues.Add($Message)
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
    $script:Warnings.Add($Message)
}

function Test-CommandVersion {
    param(
        [string]$Command,
        [string]$VersionArg = "--version"
    )
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $output = & $Command $VersionArg 2>&1
        return ($output | Select-Object -First 1).ToString().Trim()
    } catch {
        return "installed (version could not be determined)"
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
Write-Host "AD Mini-Lab - Prerequisite check" -ForegroundColor Magenta
Write-Host "==================================" -ForegroundColor Magenta

# Admin check - required for WinRM configuration
if (-not (Test-IsAdmin)) {
    Write-Host ""
    Write-Host "  [WARN] Not running as Administrator." -ForegroundColor Yellow
    Write-Host "         WinRM checks and fixes require elevation." -ForegroundColor Yellow
    Write-Host "         Re-run this script as Administrator for full validation." -ForegroundColor Yellow
}

# 1. VMware Workstation -------------------------------------------------
Write-CheckHeader "VMware Workstation Pro"

$vmwarePaths = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmware.exe",
    "C:\Program Files\VMware\VMware Workstation\vmware.exe"
)
$vmwareExe = $vmwarePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($vmwareExe) {
    Write-Pass "VMware Workstation found at: $vmwareExe"

    $vmrunPaths = @(
        "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe",
        "C:\Program Files\VMware\VMware Workstation\vmrun.exe"
    )
    $vmrunExe = $vmrunPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($vmrunExe) {
        Write-Pass "vmrun.exe available (required by Packer/Vagrant)"
    } else {
        Write-Warn "vmrun.exe not found alongside VMware Workstation. Packer needs it."
    }
} else {
    Write-Fail "VMware Workstation not found. Download it from the official Broadcom/VMware site (free for personal use)."
}

# 2. Vagrant --------------------------------------------------------------
Write-CheckHeader "Vagrant"

$vagrantVersion = Test-CommandVersion -Command "vagrant"
if ($vagrantVersion) {
    Write-Pass "Vagrant installed: $vagrantVersion"
} else {
    Write-Fail "Vagrant not found in PATH. Install it from developer.hashicorp.com/vagrant"
}

# 3. vagrant-vmware-desktop plugin ----------------------------------------
Write-CheckHeader "vagrant-vmware-desktop plugin"

if ($vagrantVersion) {
    $pluginList = & vagrant plugin list 2>&1
    if ($pluginList -match "vagrant-vmware-desktop") {
        Write-Pass "vagrant-vmware-desktop plugin installed"
    } else {
        Write-Fail "vagrant-vmware-desktop plugin not installed. Run: vagrant plugin install vagrant-vmware-desktop"
    }

    $utilityService = Get-Service -Name "vagrant-vmware-utility" -ErrorAction SilentlyContinue
    if ($utilityService) {
        if ($utilityService.Status -eq "Running") {
            Write-Pass "vagrant-vmware-utility service is running"
        } else {
            Write-Fail "vagrant-vmware-utility service is installed but stopped. Start it with: Start-Service vagrant-vmware-utility"
        }
    } else {
        Write-Fail "vagrant-vmware-utility service not found. Reinstall the plugin or reboot after installing it."
    }
} else {
    Write-Warn "Skipping plugin check because Vagrant is not installed."
}

# 4. Packer -----------------------------------------------------------------
Write-CheckHeader "Packer"

$packerVersion = Test-CommandVersion -Command "packer"
if ($packerVersion) {
    Write-Pass "Packer installed: $packerVersion"
} else {
    Write-Fail "Packer not found in PATH. Install it from developer.hashicorp.com/packer"
}

# 5. 7-Zip (used by setup-vagrant-boxes.ps1 to pack the boxes) ------------
Write-CheckHeader "7-Zip (box packaging)"

$sevenZip = @(
    "C:\Program Files\7-Zip\7z.exe",
    "C:\Program Files (x86)\7-Zip\7z.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($sevenZip) {
    Write-Pass "7-Zip found at: $sevenZip"
} else {
    Write-Fail "7-Zip not found. setup-vagrant-boxes.ps1 uses it to pack the Vagrant boxes. Install it from https://7-zip.org"
}

# 6. Nested virtualization -----------------------------------------------
Write-CheckHeader "Virtualization (VT-x / AMD-V)"

$cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cpu) {
    if ($cpu.VirtualizationFirmwareEnabled -eq $true) {
        Write-Pass "Virtualization enabled in firmware (VT-x/AMD-V)"
    } elseif ($null -eq $cpu.VirtualizationFirmwareEnabled) {
        Write-Warn "Could not determine virtualization status via WMI. Verify manually in BIOS/UEFI."
    } else {
        Write-Fail "Virtualization disabled in firmware. Enable VT-x/AMD-V in BIOS/UEFI."
    }
} else {
    Write-Warn "Could not query CPU information."
}

# 7. RAM ----------------------------------------------------------------
Write-CheckHeader "RAM"

$totalRamBytes = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory
if ($totalRamBytes) {
    $totalRamGB = [math]::Round($totalRamBytes / 1GB, 1)
    if ($totalRamGB -ge $RecommendedRamGB) {
        Write-Pass "Total RAM: ${totalRamGB}GB (above the recommended ${RecommendedRamGB}GB)"
    } elseif ($totalRamGB -ge $MinRamGB) {
        Write-Warn "Total RAM: ${totalRamGB}GB. Enough to get started, but ${RecommendedRamGB}GB is recommended to comfortably run all 3 VMs."
    } else {
        Write-Fail "Total RAM: ${totalRamGB}GB. Minimum recommended: ${MinRamGB}GB for 3 VMs at 4GB each."
    }
} else {
    Write-Warn "Could not determine total system RAM."
}

# 8. Disk space -----------------------------------------------------------
Write-CheckHeader "Disk space"

$systemDrive = (Get-Item $env:SystemDrive).PSDrive.Name
$drive = Get-PSDrive -Name $systemDrive -ErrorAction SilentlyContinue
if ($drive) {
    $freeGB = [math]::Round($drive.Free / 1GB, 1)
    if ($freeGB -ge $MinFreeDiskGB) {
        Write-Pass "Free space on ${systemDrive}: ${freeGB}GB"
    } else {
        Write-Fail "Free space on ${systemDrive}: ${freeGB}GB. At least ${MinFreeDiskGB}GB recommended for ISOs and virtual disks."
    }
} else {
    Write-Warn "Could not determine free disk space."
}

# 9. ISOs -----------------------------------------------------------------
Write-CheckHeader "Installation ISOs"

$resolvedIsoDir = $null
try {
    $resolvedIsoDir = (Resolve-Path $IsoDirectory -ErrorAction Stop).Path
} catch {
    $resolvedIsoDir = $IsoDirectory
}

$serverIso = Join-Path $resolvedIsoDir "windows-server.iso"
$clientIso  = Join-Path $resolvedIsoDir "windows-client.iso"

if (Test-Path $serverIso) {
    Write-Pass "Windows Server ISO found: $serverIso"
} else {
    Write-Fail "Windows Server ISO not found at: $serverIso (download it from the Microsoft Evaluation Center)"
}

if (Test-Path $clientIso) {
    Write-Pass "Windows client ISO found: $clientIso"
} else {
    Write-Fail "Windows client ISO not found at: $clientIso (download it from the Microsoft Evaluation Center)"
}

# 10. WinRM host configuration -------------------------------------------
# Packer communicates with VMs over WinRM (HTTP, Basic auth, unencrypted).
# The host WinRM client must be configured to allow this or Packer will
# hang waiting for a connection that it cannot establish.
Write-CheckHeader "WinRM host configuration (required for Packer)"

if (-not (Test-IsAdmin)) {
    Write-Warn "Skipping WinRM checks - not running as Administrator. Re-run elevated for full validation."
} else {
    # 9a. WinRM service running
    $winrmService = Get-Service -Name "WinRM" -ErrorAction SilentlyContinue
    if ($winrmService -and $winrmService.Status -eq "Running") {
        Write-Pass "WinRM service is running"
    } else {
        Write-Fail "WinRM service is not running. Fix with: Start-Service WinRM; Set-Service WinRM -StartupType Automatic; winrm quickconfig -quiet"
    }

    # 9b. AllowUnencrypted
    $allowUnencrypted = (Get-Item WSMan:\localhost\Client\AllowUnencrypted -ErrorAction SilentlyContinue).Value
    if ($allowUnencrypted -eq "true") {
        Write-Pass "WinRM client AllowUnencrypted = true"
    } else {
        Write-Fail "WinRM client does not allow unencrypted traffic. Fix with: winrm set winrm/config/client '@{AllowUnencrypted=`"true`"}'"
    }

    # 9c. Basic auth on client
    $basicAuth = (Get-Item WSMan:\localhost\Client\Auth\Basic -ErrorAction SilentlyContinue).Value
    if ($basicAuth -eq "true") {
        Write-Pass "WinRM client Basic authentication = true"
    } else {
        Write-Fail "WinRM client Basic auth is disabled. Fix with: winrm set winrm/config/client/auth '@{Basic=`"true`"}'"
    }

    # 9d. TrustedHosts
    $trustedHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
    if ($trustedHosts -eq "*" -or $trustedHosts -match "\*") {
        Write-Pass "WinRM TrustedHosts = * (accepts any host)"
    } elseif ($trustedHosts -and $trustedHosts.Length -gt 0) {
        Write-Warn "WinRM TrustedHosts is set to '$trustedHosts' (not wildcard). Packer may fail if the VM IP is not in this list. Fix with: winrm set winrm/config/client '@{TrustedHosts=`"*`"}'"
    } else {
        Write-Fail "WinRM TrustedHosts is empty. Packer cannot connect to VMs. Fix with: winrm set winrm/config/client '@{TrustedHosts=`"*`"}'"
    }
}

# ---------------------------------------------------------------------------
# One-shot fix command block (printed only if WinRM issues found)
# ---------------------------------------------------------------------------
$winrmIssues = $script:Issues | Where-Object { $_ -match "WinRM" }
if ($winrmIssues.Count -gt 0) {
    Write-Host ""
    Write-Host "  To fix all WinRM issues at once, run the following as Administrator:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    Start-Service WinRM" -ForegroundColor White
    Write-Host "    Set-Service WinRM -StartupType Automatic" -ForegroundColor White
    Write-Host "    winrm quickconfig -quiet" -ForegroundColor White
    Write-Host "    winrm set winrm/config/client '@{AllowUnencrypted=`"true`"}'" -ForegroundColor White
    Write-Host "    winrm set winrm/config/client/auth '@{Basic=`"true`"}'" -ForegroundColor White
    Write-Host "    winrm set winrm/config/client '@{TrustedHosts=`"*`"}'" -ForegroundColor White
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==================================" -ForegroundColor Magenta
Write-Host "Summary" -ForegroundColor Magenta
Write-Host "==================================" -ForegroundColor Magenta

if ($script:Issues.Count -eq 0) {
    Write-Host ""
    Write-Host "Everything looks good. You can proceed with 'packer build' and 'vagrant up'." -ForegroundColor Green
    if ($script:Warnings.Count -gt 0) {
        Write-Host "($($script:Warnings.Count) non-blocking warning(s) above, worth a look if something fails later)" -ForegroundColor Yellow
    }
    exit 0
} else {
    Write-Host ""
    Write-Host "Found $($script:Issues.Count) issue(s) you need to resolve before continuing:" -ForegroundColor Red
    foreach ($issue in $script:Issues) {
        Write-Host "  - $issue" -ForegroundColor Red
    }
    if ($script:Warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "Also, $($script:Warnings.Count) non-blocking warning(s):" -ForegroundColor Yellow
        foreach ($warning in $script:Warnings) {
            Write-Host "  - $warning" -ForegroundColor Yellow
        }
    }
    exit 1
}