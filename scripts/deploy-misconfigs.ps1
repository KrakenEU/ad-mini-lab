#Requires -Version 5.1
<#
.SYNOPSIS
    Pushes seed-misconfigs.ps1 onto DC1 and runs it there, so you never have to
    copy it into the VM by hand. Run this on your HOST, after the lab is up.

.DESCRIPTION
    The seeding has to run on DC1 (forest root / Enterprise Admin) and it also
    reaches into the child domain on DC2. This helper uses VMware's guest tools
    (vmrun) rather than WinRM, so the script runs with a full interactive token
    on DC1 and can make that second hop to DC2 without hitting the WinRM
    double-hop problem. -Only / -List are passed straight through.

.PARAMETER Only
    Seed only these tags (comma-separated). Passed to seed-misconfigs.ps1.

.PARAMETER List
    Just list the available misconfiguration tags on DC1 and exit.

.EXAMPLE
    .\deploy-misconfigs.ps1
    Seed the whole attack surface.

.EXAMPLE
    .\deploy-misconfigs.ps1 -Only badsuccessor,esc13
#>
[CmdletBinding()]
param(
    [string[]]$Only,
    [switch]$List
)

$ErrorActionPreference = "Stop"
$RepoRoot    = Split-Path $PSScriptRoot -Parent
$LocalScript = Join-Path $PSScriptRoot "seed-misconfigs.ps1"
$GuestUser   = "Administrator"
# DC1 is a domain controller, so "Administrator" is the domain admin. The final
# step of deploy-lab.ps1 changes it to the root-domain password below.
$GuestPass   = "TheKingOfTheHill23"

if (-not (Test-Path $LocalScript)) {
    throw "seed-misconfigs.ps1 was not found next to this helper."
}

# --- Locate vmrun and the DC1 VM --------------------------------------------
$vmrun = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe",
    "C:\Program Files\VMware\VMware Workstation\vmrun.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vmrun) { throw "vmrun.exe not found. Is VMware Workstation installed?" }

$vmx = Get-ChildItem (Join-Path $RepoRoot "lab-vms\dc1") -Filter "*.vmx" -Recurse -ErrorAction SilentlyContinue |
       Select-Object -First 1
if (-not $vmx) { throw "DC1 VM not found under lab-vms\dc1. Build the lab first with deploy-lab.ps1." }
$vmxPath = $vmx.FullName

# --- Make sure DC1 is actually up -------------------------------------------
$ip = & $vmrun -T ws getGuestIPAddress $vmxPath 2>&1
if ("$ip" -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw "DC1 has no IP yet (got: $ip). Make sure it is running, then try again."
}
Write-Host "DC1 is up at $ip" -ForegroundColor Green

$guestScript = "C:\Windows\Temp\seed-misconfigs.ps1"
$guestOut    = "C:\Windows\Temp\seed-misconfigs.out.txt"

# Build the argument line for the remote run
$argLine = ""
if ($List)     { $argLine = "-List" }
elseif ($Only) { $argLine = "-Only " + ($Only -join ",") }

# --- Copy the script over ---------------------------------------------------
Write-Host "Copying seed-misconfigs.ps1 to DC1..."
& $vmrun -T ws -gu $GuestUser -gp $GuestPass copyFileFromHostToGuest $vmxPath $LocalScript $guestScript
if ($LASTEXITCODE -ne 0) { throw "Failed to copy the script onto DC1." }

# --- Run it via a tiny .bat wrapper -----------------------------------------
# Invoking a .ps1 through vmrun is far more reliable when a batch file calls
# powershell than when powershell.exe is launched directly, so we generate a
# one-line wrapper, drop it on the guest, and run that.
if (-not $List) {
    Write-Host "Running it on DC1. This makes real changes to the directory." -ForegroundColor Cyan
} else {
    Write-Host "Listing tags on DC1..."
}
$inner    = "& '$guestScript' $argLine *> '$guestOut'"
$batText  = "@echo off`r`npowershell -ExecutionPolicy Bypass -Command `"$inner`"`r`n"
$localBat = Join-Path $env:TEMP "run-seed-misconfigs.bat"
Set-Content -Path $localBat -Value $batText -Encoding ASCII
& $vmrun -T ws -gu $GuestUser -gp $GuestPass copyFileFromHostToGuest $vmxPath $localBat "C:\Windows\Temp\run-seed-misconfigs.bat"
& $vmrun -T ws -gu $GuestUser -gp $GuestPass runProgramInGuest $vmxPath -activeWindow "C:\Windows\Temp\run-seed-misconfigs.bat" | Out-Null
# seed-misconfigs handles its own per-item failures and still exits cleanly, so
# a non-zero here just means one chain errored - the log below has the detail.

# --- Pull the output back and show it ---------------------------------------
$localOut = Join-Path $env:TEMP "seed-misconfigs.out.txt"
& $vmrun -T ws -gu $GuestUser -gp $GuestPass copyFileFromGuestToHost $vmxPath $guestOut $localOut 2>&1 | Out-Null
Write-Host ""
if (Test-Path $localOut) {
    Get-Content $localOut
} else {
    Write-Warning "The run was launched but its output could not be retrieved from DC1."
}
