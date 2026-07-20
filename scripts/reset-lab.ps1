#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Resets the lab to a fresh state in one command: destroys the running VMs,
    rebuilds them from the EXISTING Vagrant boxes (no Packer, no golden images
    needed), sets the domain-admin passwords, and seeds the misconfigurations.

.DESCRIPTION
    Use this to get back to a clean, fully-seeded lab after you have broken it
    playing. It does NOT rebuild the golden images, so it is far faster than a
    full deploy-lab.ps1 run: it just re-clones the three VMs from the boxes and
    re-provisions the domains, then re-applies everything that lives outside the
    Vagrant provisioners (the custom admin passwords and the attack surface).

    Run as Administrator.

.PARAMETER Force
    Skip the confirmation prompt.

.PARAMETER SkipMisconfigs
    Leave the rebuilt lab clean (do not seed the attack surface).

.EXAMPLE
    .\reset-lab.ps1

.EXAMPLE
    .\reset-lab.ps1 -Force -SkipMisconfigs
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipMisconfigs
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path $PSScriptRoot -Parent
$env:VAGRANT_HOME = if ($env:VAGRANT_HOME) { $env:VAGRANT_HOME } else { "D:\vagrant.d" }

# Keep these in sync with deploy-lab.ps1.
$BuildAdminPass = "ImThePr3sident"      # local/build Administrator (still current right after deploy)
$RootAdminPass  = "TheKingOfTheHill23"  # MINILAB\Administrator
$ChildAdminPass = "InsideOut67"         # OUT\Administrator

if (-not $Force) {
    Write-Host ""
    Write-Host "This DESTROYS the running lab (dc1, dc2, ws01) and rebuilds it from the" -ForegroundColor Yellow
    Write-Host "existing Vagrant boxes. The golden images and boxes are NOT touched." -ForegroundColor Yellow
    $ans = Read-Host "Continue? [y/N]"
    if ($ans -notmatch '^[Yy]') { Write-Host "Aborted."; exit 0 }
}

# --- 1. Destroy + rebuild from the boxes ------------------------------------
Push-Location $RepoRoot
try {
    Write-Host "`n[1/4] Destroying the current VMs..." -ForegroundColor Cyan
    & vagrant destroy -f

    # Clear stale WinRM port-forward mappings once (see deploy-lab.ps1 for why).
    if (Get-Service -Name VagrantVMware -ErrorAction SilentlyContinue) {
        Restart-Service VagrantVMware -Force
        Start-Sleep -Seconds 3
    }

    Write-Host "`n[2/4] Bringing the lab back up from the boxes (no Packer rebuild)..." -ForegroundColor Cyan
    & vagrant up dc1
    & vagrant up dc2
    & vagrant up ws01
}
finally { Pop-Location }

# --- 2. Set the domain-admin passwords (vmrun, same as deploy-lab's last step) --
Write-Host "`n[3/4] Setting the domain-admin passwords..." -ForegroundColor Cyan

$vmrunExe = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe",
    "C:\Program Files\VMware\VMware Workstation\vmrun.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

function Set-DomainAdminPassword {
    param([string]$Machine, [string]$NewPassword, [string]$Label)
    if (-not $vmrunExe) { Write-Host "  vmrun not found, skipping $Label" -ForegroundColor Yellow; return }
    $vmx = Get-ChildItem (Join-Path $RepoRoot "lab-vms\$Machine") -Filter "*.vmx" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $vmx) { Write-Host "  $Label VM not found, skipping" -ForegroundColor Yellow; return }
    $ps  = "Set-ADAccountPassword -Identity Administrator -Reset -NewPassword (ConvertTo-SecureString '$NewPassword' -AsPlainText -Force)"
    $bat = "@echo off`r`npowershell -ExecutionPolicy Bypass -Command `"$ps`"`r`n"
    $localBat = Join-Path $env:TEMP "reset-$Label-pw.bat"
    Set-Content -Path $localBat -Value $bat -Encoding ASCII
    & $vmrunExe -T ws -gu Administrator -gp $BuildAdminPass copyFileFromHostToGuest $vmx.FullName $localBat "C:\Windows\Temp\reset-admin-pw.bat" 2>&1 | Out-Null
    & $vmrunExe -T ws -gu Administrator -gp $BuildAdminPass runProgramInGuest  $vmx.FullName -activeWindow "C:\Windows\Temp\reset-admin-pw.bat" 2>&1 | Out-Null
    Write-Host "  $Label\Administrator -> $NewPassword" -ForegroundColor Green
}

Set-DomainAdminPassword -Machine "dc1" -NewPassword $RootAdminPass  -Label "MINILAB"
Set-DomainAdminPassword -Machine "dc2" -NewPassword $ChildAdminPass -Label "OUT"

# --- 3. Seed the misconfigurations ------------------------------------------
if ($SkipMisconfigs) {
    Write-Host "`n[4/4] Skipping misconfigurations (-SkipMisconfigs). The lab is clean." -ForegroundColor Yellow
} else {
    Write-Host "`n[4/4] Seeding the misconfigurations..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot "deploy-misconfigs.ps1")
}

Write-Host "`nReset complete." -ForegroundColor Green
Write-Host "  MINILAB\Administrator : $RootAdminPass"
Write-Host "  OUT\Administrator     : $ChildAdminPass"
Write-Host "  Foothold: OUT\jdoe / Winter2025!  (log in on WS01)"
