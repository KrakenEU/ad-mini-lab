# =============================================================================
# dc1-install-adcs.ps1
#
# Installs an Enterprise Root CA (AD Certificate Services) plus the HTTP web
# enrollment endpoint on DC1. Enterprise CAs publish to the forest config
# partition, so the child domain (out.minilab.local) can enrol too.
#
# This is the platform the modern ADCS attack family runs on:
#   ESC1  - enrollee-supplies-subject client-auth templates
#   ESC8  - NTLM relay to the /certsrv web enrollment endpoint (installed here)
#   ESC13 - issuance-policy -> group link (msDS-OIDToGroupLink)
#   ESC15 - EKUwu / application policies in v1 templates (CVE-2024-49019)
#   ESC16 - CA-wide security extension disabled
# The vulnerable templates / CA flags themselves are applied by
# seed-misconfigs.ps1 - this script only stands up a clean, healthy CA.
#
# Running as Administrator on the forest-root DC means we are Enterprise Admin,
# which Enterprise CA installation requires. No reboot needed.
#
# Environment variables injected by Vagrant:
#   DOMAIN
# =============================================================================

$ErrorActionPreference = "Stop"
$Domain = $env:DOMAIN

Write-Host "[ADCS] Waiting for Active Directory to be ready..."
$maxWait = 300; $interval = 10; $elapsed = 0; $ready = $false
while ($elapsed -lt $maxWait) {
    try { Import-Module ActiveDirectory -ErrorAction Stop; $null = Get-ADDomain -ErrorAction Stop; $ready = $true; break }
    catch { Start-Sleep -Seconds $interval; $elapsed += $interval }
}
if (-not $ready) { Write-Error "[ADCS] Timed out waiting for AD"; exit 1 }

# --- Idempotency: bail out early if a CA is already configured ---------------
$already = Get-Service -Name CertSvc -ErrorAction SilentlyContinue
if ($already -and (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration")) {
    $cfg = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration" -ErrorAction SilentlyContinue
    if ($cfg) {
        Write-Host "[ADCS] A certification authority is already configured - skipping."
        exit 0
    }
}

# --- Install the roles -------------------------------------------------------
Write-Host "[ADCS] Installing AD CS role (Certification Authority + Web Enrollment)..."
Install-WindowsFeature ADCS-Cert-Authority, ADCS-Web-Enrollment -IncludeManagementTools | Out-Null
Write-Host "[ADCS] Roles installed"

Import-Module ADCSDeployment

# --- Configure the Enterprise Root CA ----------------------------------------
$caCommonName = "minilab-DC1-CA"
Write-Host "[ADCS] Configuring Enterprise Root CA '$caCommonName'..."
try {
    Install-AdcsCertificationAuthority `
        -CAType EnterpriseRootCA `
        -CACommonName $caCommonName `
        -HashAlgorithmName SHA256 `
        -KeyLength 2048 `
        -ValidityPeriod Years `
        -ValidityPeriodUnits 10 `
        -Force | Out-Null
    Write-Host "[ADCS] Enterprise Root CA configured"
} catch {
    # Exit code 0x80070542 / "already installed" style errors are non-fatal on re-run
    if ($_.Exception.Message -match "already" ) {
        Write-Host "[ADCS] CA already configured, continuing"
    } else {
        throw
    }
}

# --- Web enrollment (/certsrv) - required for the ESC8 relay scenario --------
Write-Host "[ADCS] Configuring web enrollment endpoint (/certsrv)..."
try {
    Install-AdcsWebEnrollment -Force | Out-Null
    Write-Host "[ADCS] Web enrollment configured"
} catch {
    if ($_.Exception.Message -match "already") { Write-Host "[ADCS] Web enrollment already configured" }
    else { Write-Host "[ADCS] WARNING: web enrollment setup returned: $($_.Exception.Message)" }
}

# Make sure the CA service is running
Start-Service CertSvc -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "[ADCS] Enterprise CA is up. Clean install - vulnerable templates are added by seed-misconfigs.ps1." -ForegroundColor Green
