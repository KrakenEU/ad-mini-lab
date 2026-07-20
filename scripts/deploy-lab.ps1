#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-shot orchestrator for the AD Mini-Lab: builds both golden images with
    Packer and deploys DC1, DC2 and WS01 with Vagrant, end to end.

.DESCRIPTION
    Runs the full pipeline in order:
      1. Prerequisite check
      2. Make sure VMware Workstation is running as a process (Packer needs it)
      3. Patch static IPs for the vmnet8 subnet
      4. Build the Windows Server golden image (Packer)
      5. Build the Windows client golden image (Packer)
      6. Package both images as Vagrant boxes
      7. Bring up DC1, DC2 and WS01 (re-syncing DHCP reservations and the
         Vagrant VMware Utility service before each one, since VMware
         regenerates its DHCP config on every VM create/destroy)
      8. Register all three VMs in the VMware Workstation Library
      9. Run basic health checks (replication, domain join, name resolution)

    Every step is timestamped, logged to a file, and shown with a progress
    bar comparing elapsed time against an estimate (based on real timings
    observed while building this lab). Must run as Administrator - Packer's
    WinRM setup, the DHCP reservations and the Vagrant VMware Utility service
    restart all need elevation.

.PARAMETER Force
    Don't prompt for confirmation. Reuse existing golden images/boxes/VMs
    where possible instead of asking.

.PARAMETER RebuildImages
    Force a fresh Packer build even if golden images already exist.

.PARAMETER SkipHealthCheck
    Skip the final connectivity/replication checks.

.EXAMPLE
    .\deploy-lab.ps1
    Interactive full run - asks before rebuilding/redeploying anything that
    already exists.

.EXAMPLE
    .\deploy-lab.ps1 -Force -RebuildImages
    Fully unattended run from a clean slate.
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$RebuildImages,
    [switch]$SkipHealthCheck
)

$ErrorActionPreference = "Stop"
$RepoRoot   = Split-Path $PSScriptRoot -Parent
$env:VAGRANT_HOME = if ($env:VAGRANT_HOME) { $env:VAGRANT_HOME } else { "D:\vagrant.d" }

# Passwords. The build/local Administrator stays on $BuildAdminPass the whole way
# through (Packer and Vagrant's WinRM depend on it). Only at the very end, once
# nothing else needs to reconnect, each domain's Administrator is changed to its
# own password.
$BuildAdminPass = "ImThePr3sident"      # local/build Administrator (WS01 too)
$RootAdminPass  = "TheKingOfTheHill23"  # MINILAB\Administrator
$ChildAdminPass = "InsideOut67"         # OUT\Administrator

$script:StartTime = Get-Date
$script:LogFile   = Join-Path $RepoRoot ("deploy-lab-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$script:StepTimes = New-Object System.Collections.Generic.List[object]

# Estimated durations in minutes, based on real timings observed building
# this lab. Actual time varies with hardware - these only drive the
# progress bar's percentage, they never cut a step short.
$Estimates = @{
    "Packer build (server)"  = 20
    "Packer build (client)"  = 24
    "Package Vagrant boxes"  = 12
    "vagrant up dc1"         = 15
    "vagrant up dc2"         = 15
    "vagrant up ws01"        = 25
}

# =============================================================================
# Logging / progress helpers
# =============================================================================

function Write-Log {
    param([string]$Message, [string]$Color = "Gray")
    $ts = (Get-Date).ToString("HH:mm:ss")
    $line = "[$ts] $Message"
    Add-Content -Path $script:LogFile -Value $line
    Write-Host $line -ForegroundColor $Color
}

function Write-StepHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Magenta
    Write-Host "  $Title" -ForegroundColor Magenta
    Write-Host ("=" * 78) -ForegroundColor Magenta
    Add-Content -Path $script:LogFile -Value ""
    Add-Content -Path $script:LogFile -Value ("=" * 78)
    Add-Content -Path $script:LogFile -Value "  $Title"
    Add-Content -Path $script:LogFile -Value ("=" * 78)
}

function Confirm-Step {
    param([string]$Question)
    if ($Force) { return $true }
    $answer = Read-Host "$Question [Y/n]"
    return ($answer -eq "" -or $answer -match "^[Yy]")
}

# Runs an external process (packer.exe, vagrant.exe, ...), streaming its
# output live to both the console and the log file, while showing a
# Write-Progress bar comparing elapsed time to the step's estimate.
#
# Uses System.Diagnostics.Process directly instead of the Start-Process
# cmdlet: Start-Process -PassThru combined with -RedirectStandardOutput has
# a well-known reliability problem where .ExitCode reads back empty/null for
# fast-exiting processes, even after the process has genuinely exited. Owning
# the Process object end to end avoids that.
function Invoke-LoggedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$StepName,
        [int]$EstimatedMinutes = 10
    )

    Write-StepHeader $StepName
    $stepStart = Get-Date

    $resolvedCmd = (Get-Command $FilePath -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $resolvedCmd) {
        throw "Cannot find '$FilePath' on PATH. Open a new shell after installing it, or check your PATH."
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $resolvedCmd
    # .ArgumentList (a Collection<string>) is not reliably auto-initialized
    # under Windows PowerShell 5.1 / older .NET Framework - build a quoted
    # .Arguments string instead, which every version supports.
    $psi.Arguments = ($ArgumentList | ForEach-Object {
        if ($_ -match '\s') { '"{0}"' -f ($_ -replace '"', '\"') } else { $_ }
    }) -join ' '
    $psi.WorkingDirectory       = $WorkingDirectory
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $logFilePath = $script:LogFile
    $outAction = {
        if ($EventArgs.Data) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            Add-Content -Path $Event.MessageData -Value "[$ts]   $($EventArgs.Data)"
            Write-Host "  $($EventArgs.Data)" -ForegroundColor DarkGray
        }
    }
    $errAction = {
        if ($EventArgs.Data) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            Add-Content -Path $Event.MessageData -Value "[$ts]   $($EventArgs.Data)"
            Write-Host "  $($EventArgs.Data)" -ForegroundColor DarkYellow
        }
    }
    $outSub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $outAction -MessageData $logFilePath
    $errSub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $errAction -MessageData $logFilePath

    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 2
        $elapsed = (Get-Date) - $stepStart
        $pct = [Math]::Min(97, [Math]::Round(($elapsed.TotalMinutes / [Math]::Max(1, $EstimatedMinutes)) * 100))
        $status = "Elapsed {0:mm\:ss} / estimated ~{1} min" -f $elapsed, $EstimatedMinutes
        Write-Progress -Activity $StepName -Status $status -PercentComplete $pct
    }
    $proc.WaitForExit()
    Start-Sleep -Milliseconds 300  # let the last async output events flush
    Write-Progress -Activity $StepName -Completed

    Unregister-Event -SourceIdentifier $outSub.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $errSub.Name -ErrorAction SilentlyContinue
    Remove-Job -Job $outSub, $errSub -ErrorAction SilentlyContinue

    $duration = (Get-Date) - $stepStart
    $exitCode = $proc.ExitCode
    $script:StepTimes.Add([PSCustomObject]@{ Step = $StepName; Duration = $duration; ExitCode = $exitCode })

    if ($exitCode -ne 0) {
        Write-Log "[$StepName] FAILED after $($duration.ToString('mm\:ss')) (exit code $exitCode)" "Red"
        throw "$StepName failed with exit code $exitCode. See $script:LogFile for full output."
    }

    Write-Log "[$StepName] done in $($duration.ToString('mm\:ss'))" "Green"
}

# =============================================================================
# Step 1: prerequisites
# =============================================================================

Write-StepHeader "Step 1/9: Checking prerequisites"
& "$PSScriptRoot\check-prereqs.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Log "Prerequisite check failed. Fix the issues above and re-run." "Red"
    exit 1
}
Write-Log "Prerequisites OK" "Green"

# =============================================================================
# Step 2: make sure VMware Workstation is running as a process
# =============================================================================

Write-StepHeader "Step 2/9: Starting VMware Workstation"

$vmwareExe = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmware.exe",
    "C:\Program Files\VMware\VMware Workstation\vmware.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $vmwareExe) {
    throw "VMware Workstation executable not found."
}

$running = Get-Process -Name "vmware" -ErrorAction SilentlyContinue
if ($running) {
    Write-Log "VMware Workstation is already running" "Green"
} else {
    Write-Log "Launching VMware Workstation (Packer needs the process running to build VMs)..."
    Start-Process -FilePath $vmwareExe
    Start-Sleep -Seconds 8
    Write-Log "VMware Workstation launched" "Green"
}

# =============================================================================
# Step 3: patch static IPs for vmnet8
# =============================================================================

Write-StepHeader "Step 3/9: Detecting vmnet8 and patching build configs"
& "$PSScriptRoot\detect-vmnet8.ps1"
if ($LASTEXITCODE -ne 0) {
    throw "detect-vmnet8.ps1 failed."
}

# =============================================================================
# Step 4 & 5: Packer builds
# =============================================================================

$serverVmx = Join-Path $RepoRoot "packer\output-windows-server\windows-server-2025-golden.vmx"
$clientVmx = Join-Path $RepoRoot "packer\output-windows-client\windows-client-golden.vmx"

$buildServer = $true
if ((Test-Path $serverVmx) -and -not $RebuildImages) {
    $buildServer = -not (Confirm-Step "Server golden image already exists. Reuse it and skip the build?")
    if (-not $buildServer) { Write-Log "Reusing existing server golden image" "Yellow" }
}

if ($buildServer) {
    Write-StepHeader "Step 4/9: Building Windows Server golden image"
    Remove-Item (Join-Path $RepoRoot "packer\output-windows-server") -Recurse -Force -ErrorAction SilentlyContinue
    $buildServerDir = Join-Path $RepoRoot "packer\build-server"
    Invoke-LoggedProcess -FilePath "packer" -ArgumentList @("init", ".") -WorkingDirectory $buildServerDir `
        -StepName "packer init (server)" -EstimatedMinutes 1
    Invoke-LoggedProcess -FilePath "packer" -ArgumentList @("build", "windows-server.pkr.hcl") -WorkingDirectory $buildServerDir `
        -StepName "Packer build (server)" -EstimatedMinutes $Estimates["Packer build (server)"]
} else {
    Write-StepHeader "Step 4/9: Windows Server golden image (skipped, reusing existing)"
}

$buildClient = $true
if ((Test-Path $clientVmx) -and -not $RebuildImages) {
    $buildClient = -not (Confirm-Step "Client golden image already exists. Reuse it and skip the build?")
    if (-not $buildClient) { Write-Log "Reusing existing client golden image" "Yellow" }
}

if ($buildClient) {
    Write-StepHeader "Step 5/9: Building Windows client golden image"
    Remove-Item (Join-Path $RepoRoot "packer\output-windows-client") -Recurse -Force -ErrorAction SilentlyContinue
    $buildClientDir = Join-Path $RepoRoot "packer\build-client"
    Invoke-LoggedProcess -FilePath "packer" -ArgumentList @("init", ".") -WorkingDirectory $buildClientDir `
        -StepName "packer init (client)" -EstimatedMinutes 1
    Invoke-LoggedProcess -FilePath "packer" -ArgumentList @("build", "windows-client.pkr.hcl") -WorkingDirectory $buildClientDir `
        -StepName "Packer build (client)" -EstimatedMinutes $Estimates["Packer build (client)"]
} else {
    Write-StepHeader "Step 5/9: Windows client golden image (skipped, reusing existing)"
}

# =============================================================================
# Step 6: package Vagrant boxes
# =============================================================================

Write-StepHeader "Step 6/9: Packaging Vagrant boxes"
$boxStart = Get-Date

# Skip re-packaging when the three boxes are already registered AND we reused the
# existing golden images this run. Re-packaging from unchanged images just burns
# ~45 minutes. If images were rebuilt this run, the boxes are stale and must be
# repacked. Force a repack with -RebuildImages (which rebuilds the images too).
$boxList = & vagrant box list 2>&1
$boxesReady = ($boxList -match "dc1-box") -and ($boxList -match "dc2-box") -and ($boxList -match "ws01-box")

if ($boxesReady -and -not $buildServer -and -not $buildClient) {
    Write-Log "All boxes already registered and golden images were reused - skipping packaging." "Yellow"
} else {
    & "$PSScriptRoot\setup-vagrant-boxes.ps1" 2>&1 | ForEach-Object {
        Write-Host "  $_" -ForegroundColor DarkGray
        Add-Content -Path $script:LogFile -Value "[$(Get-Date -Format 'HH:mm:ss')]   $_"
    }
    if ($LASTEXITCODE -ne 0) {
        throw "setup-vagrant-boxes.ps1 failed."
    }
}
$script:StepTimes.Add([PSCustomObject]@{ Step = "Package Vagrant boxes"; Duration = (Get-Date) - $boxStart; ExitCode = 0 })
Write-Log "Vagrant boxes packaged" "Green"

# =============================================================================
# Step 7: vagrant up (dc1, dc2, ws01)
# =============================================================================

Write-StepHeader "Step 7/9: Deploying the lab with Vagrant"

Push-Location $RepoRoot
try {
    $existingStatus = & vagrant status 2>&1
    if ($existingStatus -match "running") {
        $redeploy = Confirm-Step "Some VMs are already running. Destroy them and redeploy from scratch?"
        if ($redeploy) {
            Write-Log "Destroying existing VMs..."
            & vagrant destroy -f 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        } else {
            Write-Log "Leaving existing VMs as-is. Skipping vagrant up." "Yellow"
        }
    }

    # Clears stale WinRM port-forward mappings left behind by earlier runs.
    # Runs ONCE, before the first vagrant up.
    #
    # This used to run before EVERY vagrant up, bundled with a set of DHCP
    # reservations. Both were workarounds for clones booting with the golden
    # image's baked-in static IP and having it change mid-run, which broke
    # Vagrant's port-forward. That root cause is fixed in the Packer build now:
    # sysprep actually generalizes, so clones boot on plain DHCP and nothing
    # rewrites their address. The reservations are therefore gone: VMs take
    # whatever DHCP hands out and find each other by NetBIOS name, exactly as
    # dc2-child-domain.ps1 and ws01-join-domain.ps1 already expect.
    #
    # Restarting the utility BETWEEN VMs was actively harmful: it tore down the
    # port-forwards of VMs already running, leaving the host TCP port open but
    # unmapped. `vagrant up dc2` then hung waiting for WinRM on a guest that had
    # been booted and ready for 20+ minutes, and died with KeepAliveDisconnected.
    function Reset-VagrantUtility {
        $utilSvc = Get-Service -Name VagrantVMware -ErrorAction SilentlyContinue
        if (-not $utilSvc) {
            Write-Log "vagrant-vmware-utility service not found - skipping (is the vagrant-vmware-desktop plugin installed?)" "Yellow"
            return
        }
        Write-Log "Restarting the Vagrant VMware Utility service (clears stale port-forwards)..."
        Restart-Service VagrantVMware -Force
        Start-Sleep -Seconds 3
        if ((Get-Service VagrantVMware).Status -eq "Running") {
            Write-Log "vagrant-vmware-utility service running" "Green"
        } else {
            throw "vagrant-vmware-utility service failed to restart - check it manually."
        }
    }

    function Invoke-VagrantUp {
        param([string]$Machine, [int]$EstimatedMinutes)
        Invoke-LoggedProcess -FilePath "vagrant" -ArgumentList @("up", $Machine) -WorkingDirectory $RepoRoot `
            -StepName "vagrant up $Machine" -EstimatedMinutes $EstimatedMinutes
    }

    Reset-VagrantUtility

    Invoke-VagrantUp -Machine "dc1"  -EstimatedMinutes $Estimates["vagrant up dc1"]
    Invoke-VagrantUp -Machine "dc2"  -EstimatedMinutes $Estimates["vagrant up dc2"]
    Invoke-VagrantUp -Machine "ws01" -EstimatedMinutes $Estimates["vagrant up ws01"]
}
finally {
    Pop-Location
}

# =============================================================================
# Step 8: register VMs in the VMware Workstation Library
# =============================================================================

Write-StepHeader "Step 8/9: Registering VMs in the VMware Workstation Library"

function Add-VMwareLibraryEntry {
    param([string]$VmxPath, [string]$DisplayName)

    $inventoryFile = Join-Path $env:APPDATA "VMware\inventory.vmls"
    if (-not (Test-Path $inventoryFile)) {
        Write-Log "inventory.vmls not found at $inventoryFile - skipping Library registration for $DisplayName" "Yellow"
        return
    }

    $content = Get-Content $inventoryFile -Raw
    if ($content -match [regex]::Escape($VmxPath)) {
        Write-Log "$DisplayName already in the Library" "Yellow"
        return
    }

    $existingIds = [regex]::Matches($content, 'vmlist(\d+)\.ItemID') | ForEach-Object { [int]$_.Groups[1].Value }
    $existingSeq = [regex]::Matches($content, 'vmlist\d+\.SeqID = "(\d+)"') | ForEach-Object { [int]$_.Groups[1].Value }
    $nextId  = if ($existingIds) { ($existingIds | Measure-Object -Maximum).Maximum + 1 } else { 1 }
    $nextSeq = if ($existingSeq) { ($existingSeq | Measure-Object -Maximum).Maximum + 1 } else { 0 }

    $block = @"
vmlist$nextId.config = "$VmxPath"
vmlist$nextId.DisplayName = "$DisplayName"
vmlist$nextId.ParentID = "0"
vmlist$nextId.ItemID = "$nextId"
vmlist$nextId.SeqID = "$nextSeq"
vmlist$nextId.IsFavorite = "FALSE"
vmlist$nextId.IsClone = "FALSE"
vmlist$nextId.CfgVersion = "8"
vmlist$nextId.State = "normal"
vmlist$nextId.IsCfgPathNormalized = "TRUE"
"@
    Add-Content -Path $inventoryFile -Value $block
    Write-Log "Added $DisplayName to the Library ($VmxPath)" "Green"
}

$labVmx = @{
    "ad-mini-lab: dc1"  = Get-ChildItem (Join-Path $RepoRoot "lab-vms\dc1")  -Filter "*.vmx" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    "ad-mini-lab: dc2"  = Get-ChildItem (Join-Path $RepoRoot "lab-vms\dc2")  -Filter "*.vmx" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    "ad-mini-lab: ws01" = Get-ChildItem (Join-Path $RepoRoot "lab-vms\ws01") -Filter "*.vmx" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}

foreach ($name in $labVmx.Keys) {
    if ($labVmx[$name]) {
        Add-VMwareLibraryEntry -VmxPath $labVmx[$name] -DisplayName $name
    }
}

# Restart the Workstation UI so it re-reads inventory.vmls. This does not
# touch the running VM processes (vmware-vmx.exe), only the management window.
Write-Log "Restarting the VMware Workstation window so the Library refreshes..."
Get-Process -Name "vmware" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-Process -FilePath $vmwareExe
Start-Sleep -Seconds 5
Write-Log "VMware Workstation Library updated" "Green"

# =============================================================================
# Step 9: health checks
# =============================================================================

if (-not $SkipHealthCheck) {
    Write-StepHeader "Step 9/9: Verifying the lab"

    function Get-GuestIp {
        param([string]$VmxPath)
        $vmrun = "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe"
        $ip = & $vmrun -T ws getGuestIPAddress $VmxPath 2>&1
        if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { return $ip }
        return $null
    }

    function Test-WinrmAuth {
        param([string]$IpAddress, [string]$Username = "Administrator", [string]$Password = "ImThePr3sident")
        $securePass = ConvertTo-SecureString $Password -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($Username, $securePass)
        try {
            Invoke-Command -ComputerName $IpAddress -Port 5985 -Credential $cred -Authentication Basic -UseSSL:$false -ScriptBlock {
                [PSCustomObject]@{
                    Hostname     = $env:COMPUTERNAME
                    Domain       = (Get-CimInstance Win32_ComputerSystem).Domain
                    PartOfDomain = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
                }
            } -ErrorAction Stop
        } catch {
            Write-Log "  WinRM check failed for $IpAddress : $($_.Exception.Message)" "Red"
            return $null
        }
    }

    $dc1Ip  = Get-GuestIp -VmxPath $labVmx["ad-mini-lab: dc1"]
    $dc2Ip  = Get-GuestIp -VmxPath $labVmx["ad-mini-lab: dc2"]
    $ws01Ip = Get-GuestIp -VmxPath $labVmx["ad-mini-lab: ws01"]

    Write-Log "DC1  IP: $dc1Ip"
    Write-Log "DC2  IP: $dc2Ip"
    Write-Log "WS01 IP: $ws01Ip"

    if ($dc1Ip)  { $r = Test-WinrmAuth -IpAddress $dc1Ip;  if ($r)  { Write-Log "DC1  reachable - hostname $($r.Hostname), domain $($r.Domain)" "Green" } }
    if ($dc2Ip)  { $r = Test-WinrmAuth -IpAddress $dc2Ip;  if ($r)  { Write-Log "DC2  reachable - hostname $($r.Hostname), domain $($r.Domain)" "Green" } }
    if ($ws01Ip) { $r = Test-WinrmAuth -IpAddress $ws01Ip; if ($r)  { Write-Log "WS01 reachable - hostname $($r.Hostname), joined: $($r.PartOfDomain)" "Green" } }

    if ($dc1Ip) {
        $securePass = ConvertTo-SecureString "ImThePr3sident" -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential("Administrator", $securePass)
        try {
            $repl = Invoke-Command -ComputerName $dc1Ip -Port 5985 -Credential $cred -Authentication Basic -UseSSL:$false -ScriptBlock {
                repadmin /replsummary
            } -ErrorAction Stop
            Write-Log "Replication summary:`n$($repl -join "`n")"
        } catch {
            Write-Log "Could not retrieve replication summary: $($_.Exception.Message)" "Yellow"
        }
    }
}

# =============================================================================
# Set the custom domain-admin passwords (last thing, once nothing reconnects)
# =============================================================================
# Done over vmrun (guest tools) using the still-current build password, so it
# never depends on WinRM. If this step fails the lab is still fully deployed;
# only the passwords stay at the build default.
Write-StepHeader "Setting custom domain-admin passwords"

$vmrunExe = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe",
    "C:\Program Files\VMware\VMware Workstation\vmrun.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

function Set-DomainAdminPassword {
    param([string]$VmxPath, [string]$NewPassword, [string]$Label)
    if (-not $VmxPath) { Write-Log "  $Label VM not found, skipping password change" "Yellow"; return }
    $ps  = "Set-ADAccountPassword -Identity Administrator -Reset -NewPassword (ConvertTo-SecureString '$NewPassword' -AsPlainText -Force)"
    $bat = "@echo off`r`npowershell -ExecutionPolicy Bypass -Command `"$ps`"`r`n"
    $localBat = Join-Path $env:TEMP "set-$Label-pw.bat"
    Set-Content -Path $localBat -Value $bat -Encoding ASCII
    & $vmrunExe -T ws -gu Administrator -gp $BuildAdminPass copyFileFromHostToGuest $VmxPath $localBat "C:\Windows\Temp\set-admin-pw.bat" 2>&1 | Out-Null
    & $vmrunExe -T ws -gu Administrator -gp $BuildAdminPass runProgramInGuest  $VmxPath -activeWindow "C:\Windows\Temp\set-admin-pw.bat" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  $Label\Administrator password set" "Green"
    } else {
        Write-Log "  $Label password change returned a non-zero code; verify manually" "Yellow"
    }
}

if ($vmrunExe) {
    Set-DomainAdminPassword -VmxPath $labVmx["ad-mini-lab: dc1"] -NewPassword $RootAdminPass  -Label "MINILAB"
    Set-DomainAdminPassword -VmxPath $labVmx["ad-mini-lab: dc2"] -NewPassword $ChildAdminPass -Label "OUT"
} else {
    Write-Log "vmrun not found; leaving domain-admin passwords at the build default." "Yellow"
}

# =============================================================================
# Final summary
# =============================================================================

Write-StepHeader "Done"
$totalDuration = (Get-Date) - $script:StartTime

Write-Host ""
Write-Host "Step timing breakdown:" -ForegroundColor Cyan
foreach ($s in $script:StepTimes) {
    Write-Host ("  {0,-28} {1:hh\:mm\:ss}" -f $s.Step, $s.Duration)
}
Write-Host ""
Write-Host "Total time: $($totalDuration.ToString('hh\:mm\:ss'))" -ForegroundColor Cyan
Write-Host "Full log: $script:LogFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "Lab credentials:" -ForegroundColor Cyan
Write-Host "  MINILAB\Administrator : $RootAdminPass"
Write-Host "  OUT\Administrator     : $ChildAdminPass"
Write-Host "  Local Administrator (WS01 / build) : $BuildAdminPass"
Write-Host "  Seeded users: each has its own password (see seed-baseline.ps1 / seed-child-baseline.ps1)"
Write-Host "  Foothold: OUT\jdoe / Winter2025!  (log in on WS01)"
Write-Host ""
Write-Host "All done. DC1, DC2 and WS01 should now be visible in VMware Workstation's Library." -ForegroundColor Green
