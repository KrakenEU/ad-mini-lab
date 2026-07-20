#Requires -Version 5.1
<#
.SYNOPSIS
    Packages the Packer-built golden images as Vagrant boxes and registers them.
    Run this once after both Packer builds complete and before vagrant up.
#>

$ErrorActionPreference = "Stop"

$SevenZip  = "C:\Program Files\7-Zip\7z.exe"
$RepoRoot  = Split-Path $PSScriptRoot -Parent
$ServerVmx = Join-Path $RepoRoot "packer\output-windows-server\windows-server-2025-golden.vmx"
$ClientVmx = Join-Path $RepoRoot "packer\output-windows-client\windows-client-golden.vmx"

if (-not (Test-Path $SevenZip)) {
    Write-Error "7-Zip not found at $SevenZip. Install it from https://7-zip.org"
    exit 1
}
if (-not (Test-Path $ServerVmx)) {
    Write-Error "Server golden image not found at: $ServerVmx"
    exit 1
}
if (-not (Test-Path $ClientVmx)) {
    Write-Error "Client golden image not found at: $ClientVmx"
    exit 1
}

Write-Host "Golden images found:" -ForegroundColor Cyan
Write-Host "  Server: $ServerVmx"
Write-Host "  Client: $ClientVmx"
Write-Host ""

function Add-VmwareBox {
    param(
        [string]$BoxName,
        [string]$VmxPath
    )

    Write-Host "[$BoxName] Packaging box..." -ForegroundColor Cyan

    $tempDir = Join-Path $env:TEMP "vagrant-box-$BoxName"
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    # metadata.json and Vagrantfile go into tempDir
    '{"provider":"vmware_desktop"}' | Set-Content "$tempDir\metadata.json" -Encoding ASCII
    @'
Vagrant.configure("2") do |config|
  config.vm.provider "vmware_desktop"
end
'@ | Set-Content "$tempDir\Vagrantfile" -Encoding ASCII

    # Copy VM files into tempDir and rename VMX to box.vmx
    Write-Host "[$BoxName] Copying VM files (may take a few minutes)..."
    $vmxDir = Split-Path $VmxPath -Parent
    Copy-Item "$vmxDir\*" $tempDir -Recurse -Force

    $originalVmx = Get-ChildItem $tempDir -Filter "*.vmx" | Select-Object -First 1
    if ($originalVmx -and $originalVmx.Name -ne "box.vmx") {
        Rename-Item $originalVmx.FullName "box.vmx"
    }

    # Build explicit file list for tar (no wildcards = no subdirectory paths)
    $fileList = Get-ChildItem $tempDir -File | Select-Object -ExpandProperty Name

    $tarFile = Join-Path $env:TEMP "$BoxName.tar"
    $boxFile = Join-Path $env:TEMP "$BoxName.box"
    if (Test-Path $tarFile) { Remove-Item $tarFile -Force }
    if (Test-Path $boxFile) { Remove-Item $boxFile -Force }

    Write-Host "[$BoxName] Creating tar archive..."
    Push-Location $tempDir
    & $SevenZip a -ttar $tarFile @fileList | Out-Null
    Pop-Location

    Write-Host "[$BoxName] Compressing to .box..."
    & $SevenZip a -tgzip $boxFile $tarFile | Out-Null
    Remove-Item $tarFile -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $boxFile)) {
        Write-Error "[$BoxName] Failed to create box archive"
        exit 1
    }

    # Remove old registration if exists
    $existing = & vagrant box list 2>&1 | Select-String "^$BoxName\s"
    if ($existing) {
        Write-Host "[$BoxName] Removing old version..."
        & vagrant box remove $BoxName --provider vmware_desktop --force 2>&1 | Out-Null
    }

    Write-Host "[$BoxName] Registering with Vagrant..."
    & vagrant box add $BoxName $boxFile --provider vmware_desktop --force

    Remove-Item $boxFile -Force -ErrorAction SilentlyContinue
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[$BoxName] Registered successfully" -ForegroundColor Green
    } else {
        Write-Error "[$BoxName] Failed to register box"
        exit 1
    }

    Write-Host ""
}

Add-VmwareBox -BoxName "dc1-box"  -VmxPath $ServerVmx
Add-VmwareBox -BoxName "dc2-box"  -VmxPath $ServerVmx
Add-VmwareBox -BoxName "ws01-box" -VmxPath $ClientVmx

Write-Host "All boxes registered." -ForegroundColor Green
Write-Host ""
Write-Host "Run 'vagrant up' to bring up the full lab, or individually:" -ForegroundColor Cyan
Write-Host "  vagrant up dc1"
Write-Host "  vagrant up dc2"
Write-Host "  vagrant up ws01"