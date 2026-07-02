#Requires -Version 5.1
<#
.SYNOPSIS
    Validates that the environment has everything needed to build the AD Mini-Lab.

.DESCRIPTION
    Checks VMware Workstation, Vagrant, the vagrant-vmware-desktop plugin,
    the Vagrant VMware Utility service, Packer, nested virtualization,
    available RAM, disk space, and the presence of the required ISOs.

    This script doesn't install anything for you: it just tells you exactly
    what's missing and how to fix it, before you waste time on a build that
    fails halfway through.

.EXAMPLE
    .\check-prereqs.ps1
#>

[CmdletBinding()]
param(
    [string]$IsoDirectory = (Join-Path $PSScriptRoot "packer\isos"),
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
    if (-not $cmd) {
        return $null
    }
    try {
        $output = & $Command $VersionArg 2>&1
        return ($output | Select-Object -First 1).ToString().Trim()
    } catch {
        return "installed (version could not be determined)"
    }
}

# ---------------------------------------------------------------------------
Write-Host "AD Mini-Lab - Prerequisite check" -ForegroundColor Magenta
Write-Host "==================================" -ForegroundColor Magenta

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

# 5. Nested virtualization ---------------------------------------------
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

# 6. RAM ----------------------------------------------------------------
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

# 7. Disk space -----------------------------------------------------------
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

# 8. ISOs -----------------------------------------------------------------
Write-CheckHeader "Installation ISOs"

$resolvedIsoDir = $null
try {
    $resolvedIsoDir = (Resolve-Path $IsoDirectory -ErrorAction Stop).Path
} catch {
    $resolvedIsoDir = $IsoDirectory
}

$serverIso = Join-Path $resolvedIsoDir "windows-server.iso"
$clientIso = Join-Path $resolvedIsoDir "windows-client.iso"

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